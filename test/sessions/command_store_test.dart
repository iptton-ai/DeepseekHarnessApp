// CommandStore 域测试(W2-D):双层信封解析、agent-busy 降级、缓存与失效
// (commands/change + agent-preset/selected 事件 + 代际翻转)、execute 预校验、
// 合并目录(listAll)、fuzzy/命令名解析。
// 模式:自建最小假主机(describe + commands/list|execute + skill.list + 双 WS 下行),
// 不 import 共享 helper。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/sessions/goal_store.dart';

/// commands/list 的响应模式。
enum _ListMode { ok, innerAgentBusy, outerAgentBusy, http500, timeout }

/// commands/execute 的响应模式。
enum _ExecMode { ok, innerError, outerError }

/// 最小假主机:describe + 远程端点 + skill.list + 双 WS;可编程响应。
class _FakeHost {
  _FakeHost._(this._server);
  final HttpServer _server;
  final List<WebSocket> _mux = <WebSocket>[];
  final List<WebSocket> _host = <WebSocket>[];
  int _frameNo = 0;

  _ListMode listMode = _ListMode.ok;
  List<Map<String, dynamic>> listCommands = <Map<String, dynamic>>[];
  _ExecMode execMode = _ExecMode.ok;
  Map<String, dynamic>? lastExecutePayload;
  int executeRequests = 0;
  bool skillListFails = false;
  List<Map<String, dynamic>> skills = <Map<String, dynamic>>[];

  Uri get baseUri => Uri.parse('http://127.0.0.1:' + _server.port.toString());

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost._(server);
    server.listen((req) => host._handle(req));
    return host;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/api/host.describe') {
      final envelope = await _readJson(req);
      await _respond(req, {
        'type': 'server-response',
        'rpcId': envelope['rpcId'],
        'result': {
          'ok': true,
          'value': {
            'version': '0.0.1-fake',
            'cwd': '/tmp/fake',
            'provider': 'fake',
            'model': 'fake-model',
            'attachedSessions': 0,
            'canOpenPath': false,
          },
        },
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/commands/list') {
      final envelope = await _readJson(req);
      if (listMode == _ListMode.http500) {
        req.response.statusCode = 500;
        await req.response.close();
        return;
      }
      if (listMode == _ListMode.timeout) {
        return; // 挂起请求,触发客户端超时。
      }
      final Map<String, dynamic> value;
      switch (listMode) {
        case _ListMode.ok:
          value = <String, dynamic>{'ok': true, 'value': listCommands};
        case _ListMode.innerAgentBusy:
          value = <String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{
              'code': 'agent-busy',
              'message': 'use subagent delivery',
            },
          };
        case _ListMode.outerAgentBusy:
          value = <String, dynamic>{};
        case _ListMode.http500:
        case _ListMode.timeout:
          value = <String, dynamic>{};
      }
      if (listMode == _ListMode.outerAgentBusy) {
        // 外层 RpcResult 直接 ok:false(防御路径)。
        await _respond(req, {
          'type': 'server-response',
          'rpcId': envelope['rpcId'],
          'result': {
            'ok': false,
            'error': <String, dynamic>{
              'code': 'agent-busy',
              'message': 'use subagent delivery',
              'details': <String, dynamic>{},
            },
          },
        });
        return;
      }
      await _respond(req, {
        'type': 'server-response',
        'rpcId': envelope['rpcId'],
        'result': <String, dynamic>{'ok': true, 'value': value},
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/commands/execute') {
      final envelope = await _readJson(req);
      executeRequests += 1;
      lastExecutePayload = envelope['payload'] as Map<String, dynamic>;
      switch (execMode) {
        case _ExecMode.ok:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': <String, dynamic>{'ok': true},
          });
        case _ExecMode.innerError:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': <String, dynamic>{
              'ok': true,
              'value': <String, dynamic>{
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'command-error',
                  'message': 'boom',
                },
              },
            },
          });
        case _ExecMode.outerError:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': <String, dynamic>{
              'ok': false,
              'error': <String, dynamic>{
                'code': 'command-error',
                'message': 'boom',
                'details': <String, dynamic>{},
              },
            },
          });
      }
      return;
    }
    if (req.method == 'POST' && path == '/api/skill.list') {
      final envelope = await _readJson(req);
      if (skillListFails) {
        req.response.statusCode = 500;
        await req.response.close();
        return;
      }
      await _respond(req, {
        'type': 'server-response',
        'rpcId': envelope['rpcId'],
        'result': <String, dynamic>{
          'ok': true,
          'value': <String, dynamic>{'skills': skills},
        },
      });
      return;
    }
    if (path == '/api/events.mux' || path == '/api/events.host') {
      final ws = await WebSocketTransformer.upgrade(req);
      (path.endsWith('mux') ? _mux : _host).add(ws);
      ws.listen((_) {}, onDone: () {});
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<void> _respond(HttpRequest req, Map<String, dynamic> body) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  /// 推一条 host/remote-event 帧(host 流;commands/change 等失效事件)。
  void pushRemoteEvent(String event, [List<dynamic> args = const []]) {
    _frameNo += 1;
    final payload = <String, dynamic>{
      'type': 'host/remote-event',
      'event': event,
      'args': args,
    };
    for (final ws in _host) {
      try {
        ws.add(jsonEncode({
          'type': 'server-request',
          'rpcId': 'fake-host-$_frameNo',
          'method': 'host/remote-event',
          'payload': payload,
        }));
      } catch (_) {
        // 已关闭的旧 socket 忽略。
      }
    }
  }

  Future<void> stop() async {
    for (final ws in [..._mux, ..._host]) {
      try {
        await ws.close();
      } catch (_) {}
    }
    await _server.close(force: true);
  }
}

Map<String, dynamic> _command(String name, String description, {String? hint}) =>
    <String, dynamic>{
      'name': name,
      'description': description,
      if (hint != null) 'input': <String, dynamic>{'hint': hint},
    };

Map<String, dynamic> _skill(String name, String description,
        {bool modelInvocable = true}) =>
    <String, dynamic>{
      'name': name,
      'description': description,
      'modelInvocable': modelInvocable,
    };

void main() {
  group('CommandStore 域', () {
    late _FakeHost host;
    late ConnectionController controller;
    late ApiClient api;
    late SkillCatalog skills;
    late CommandStore store;

    setUp(() async {
      host = await _FakeHost.start();
      controller = ConnectionController(
        baseUri: host.baseUri,
        initialBackoff: const Duration(milliseconds: 30),
        maxBackoff: const Duration(milliseconds: 150),
        probeTimeout: const Duration(milliseconds: 400),
      );
      api = ApiClient(
        baseUri: host.baseUri,
        defaultTimeout: const Duration(milliseconds: 300),
      );
      skills = SkillCatalog(api: api);
      store = CommandStore(api: api, connection: controller, skills: skills);
      controller.start();
      await controller.snapshots
          .firstWhere((s) => s.phase == ConnectionPhase.ready)
          .timeout(const Duration(seconds: 3));
    });

    tearDown(() async {
      await store.dispose();
      await controller.dispose();
      api.dispose();
      await host.stop();
    });

    test('双层信封解析成功:裸数组 + input.hint', () async {
      host.listCommands = [
        _command('compact', '紧凑显示', hint: 'on/off'),
        _command('export', '导出会话'),
      ];
      final result = await store.listCommands('session-s1');
      expect(result.isDegraded, isFalse);
      expect(result.commands, hasLength(2));
      expect(result.commands[0].name, 'compact');
      expect(result.commands[0].description, '紧凑显示');
      expect(result.commands[0].hint, 'on/off');
      expect(result.commands[1].hint, isNull);
      expect(store.listCalls, 1);
    });

    test('内层信封 ok:false(agent-busy)→ 空目录 + 错误位,不缓存', () async {
      host.listMode = _ListMode.innerAgentBusy;
      final result = await store.listCommands('session-s1');
      expect(result.isDegraded, isTrue);
      expect(result.isAgentBusy, isTrue);
      expect(result.error?.message, 'use subagent delivery');
      expect(result.commands, isEmpty);

      // 失败不缓存:再次调用仍走 HTTP(重试=重拉)。
      final again = await store.listCommands('session-s1');
      expect(again.isAgentBusy, isTrue);
      expect(store.listCalls, 2);
    });

    test('外层 RpcResult ok:false(agent-busy)防御降级', () async {
      host.listMode = _ListMode.outerAgentBusy;
      final result = await store.listCommands('session-s1');
      expect(result.isDegraded, isTrue);
      expect(result.isAgentBusy, isTrue);
      expect(result.commands, isEmpty);
    });

    test('传输失败(http 500)→ 降级 transport,不缓存', () async {
      host.listMode = _ListMode.http500;
      final result = await store.listCommands('session-s1');
      expect(result.isDegraded, isTrue);
      expect(result.error?.code, 'transport');
      await store.listCommands('session-s1');
      expect(store.listCalls, 2);
    });

    test('超时 → 降级 timeout,不抛异常', () async {
      host.listMode = _ListMode.timeout;
      final result = await store.listCommands('session-s1');
      expect(result.isDegraded, isTrue);
      expect(result.error?.code, 'timeout');
    });

    test('缓存 per-session:同会话二次命中,异会话独立', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      await store.listCommands('session-s1');
      expect(store.listCalls, 1);
      await store.listCommands('session-s2');
      expect(store.listCalls, 2);
    });

    test('缓存失效:commands/change 事件丢弃缓存', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      host.listCommands = [_command('compact', '紧凑显示'), _command('goal', '目标')];
      host.pushRemoteEvent('commands/change');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final result = await store.listCommands('session-s1');
      expect(store.listCalls, 2);
      expect(result.commands, hasLength(2));
    });

    test('缓存失效:agent-preset/selected 事件丢弃缓存', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      host.pushRemoteEvent('agent-preset/selected', <dynamic>['session-s1']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await store.listCommands('session-s1');
      expect(store.listCalls, 2);
    });

    test('无关 remote-event 不失效缓存', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      host.pushRemoteEvent('settings/document-updated');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await store.listCommands('session-s1');
      expect(store.listCalls, 1);
    });

    test('代际翻转(重连)清空全部缓存', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      expect(store.listCalls, 1);

      final gen = controller.current!.generation;
      controller.debugDropDownlinks();
      await controller.snapshots
          .firstWhere((s) =>
              s.phase == ConnectionPhase.ready && s.generation > gen)
          .timeout(const Duration(seconds: 3));

      host.listCommands = [_command('goal', '目标')];
      final result = await store.listCommands('session-s1');
      expect(store.listCalls, 2);
      expect(result.commands.single.name, 'goal');
    });

    test('execute:目录内命令放行,信封 {args:{agentId,line}}', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      await store.execute('session-s1', '/compact off');
      expect(host.executeRequests, 1);
      expect(store.executeCalls, 1);
      expect(host.lastExecutePayload, <String, dynamic>{
        'args': <String, dynamic>{
          'agentId': 'session-s1',
          'line': '/compact off',
        },
      });
    });

    test('execute:预校验拒绝未知命令,不碰服务端', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      await expectLater(
        store.execute('session-s1', '/bogus x'),
        throwsA(isA<UnknownCommandException>()),
      );
      expect(host.executeRequests, 0);
      expect(store.executeCalls, 0);
    });

    test('execute:目录未就绪(未拉取)本地拒绝', () async {
      await expectLater(
        store.execute('session-s1', '/compact'),
        throwsA(isA<UnknownCommandException>()),
      );
      expect(host.executeRequests, 0);
    });

    test('execute:非斜杠行本地拒绝', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      await expectLater(
        store.execute('session-s1', 'compact'),
        throwsA(isA<UnknownCommandException>()),
      );
      expect(host.executeRequests, 0);
    });

    test('execute:内层信封错误折叠为 CommandExecuteException', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      host.execMode = _ExecMode.innerError;
      await expectLater(
        store.execute('session-s1', '/compact'),
        throwsA(isA<CommandExecuteException>()),
      );
      expect(host.executeRequests, 1);
    });

    test('execute:外层业务错误折叠为 CommandExecuteException', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      await store.listCommands('session-s1');
      host.execMode = _ExecMode.outerError;
      await expectLater(
        store.execute('session-s1', '/compact'),
        throwsA(isA<CommandExecuteException>()),
      );
    });

    test('listAll:合并 commands + skills 为分组菜单', () async {
      host.listCommands = [
        _command('compact', '紧凑显示'),
        _command('export', '导出会话'),
      ];
      host.skills = [
        _skill('android', 'Android 开发'),
        _skill('game-design', '游戏设计', modelInvocable: false),
      ];
      final menu = await store.listAll('session-s1');
      expect(menu.degraded, isFalse);
      expect(menu.commands, hasLength(2));
      expect(menu.commands[0].slash, '/compact');
      expect(menu.commands[0].kind, CommandMenuItemKind.command);
      expect(menu.skills, hasLength(2));
      expect(menu.skills[0].slash, '/android');
      expect(menu.skills[0].kind, CommandMenuItemKind.skill);
      expect(menu.skills[1].skillModelInvocable, isFalse);
    });

    test('listAll:命令 agent-busy 降级为 skill-only,技能仍可用', () async {
      host.listMode = _ListMode.innerAgentBusy;
      host.skills = [_skill('android', 'Android 开发')];
      final menu = await store.listAll('session-s1');
      expect(menu.degraded, isTrue);
      expect(menu.errorCode, 'agent-busy');
      expect(menu.commands, isEmpty);
      expect(menu.skills, hasLength(1));
    });

    test('listAll:skill.list 失败 → 技能组静默丢弃,不抛异常', () async {
      host.listCommands = [_command('compact', '紧凑显示')];
      host.skillListFails = true;
      final menu = await store.listAll('session-s1');
      expect(menu.degraded, isFalse);
      expect(menu.commands, hasLength(1));
      expect(menu.skills, isEmpty);
    });
  });

  group('filterMenu / commandNameOf(纯函数)', () {
    CommandMenuItem cmd(String name) => CommandMenuItem.command(
        CommandEntry(name: name, description: 'd'));

    test('空查询返回原序', () {
      final items = [cmd('compact'), cmd('export')];
      expect(filterMenu(items, '').map((e) => e.name), ['compact', 'export']);
      expect(filterMenu(items, '   ').map((e) => e.name),
          ['compact', 'export']);
    });

    test('前缀优先:前缀命中排最前,其余子序列保持原序', () {
      final items = [
        cmd('goal'),
        cmd('compact'),
        cmd('compact-all'),
        cmd('export'),
        cmd('global'),
      ];
      // 查询 'go':前缀命中 goal/global? 'go' 前缀 → goal、global(前缀),
      // compact/compact-all/export 无 'go' 子序列? compact: c-o-m... 有 'o'
      // 无 'g';export 无;'goal'/'global' 前缀。
      final names = filterMenu(items, 'go').map((e) => e.name).toList();
      expect(names, ['goal', 'global']);
    });

    test('子序列不区分大小写匹配', () {
      final items = [
        cmd('compact'),
        cmd('export'),
        cmd('goal'),
      ];
      // 'cpa' → compact(c..p..a 子序列);'EXP' → export(大小写不敏感)。
      expect(filterMenu(items, 'cpa').map((e) => e.name), ['compact']);
      expect(filterMenu(items, 'EXP').map((e) => e.name), ['export']);
      // 'xyz' 不在任何名称的子序列里 → 空。
      expect(filterMenu(items, 'xyz'), isEmpty);
    });

    test('前缀命中同时满足子序列时只进前缀组(不重复)', () {
      final items = [cmd('compact'), cmd('compact-all'), cmd('goal')];
      // 'co' 前缀 compact/compact-all;goal 无 → 只有前缀组。
      expect(filterMenu(items, 'co').map((e) => e.name),
          ['compact', 'compact-all']);
    });

    test('commandNameOf:解析首 token,非斜杠/空名返回 null', () {
      expect(commandNameOf('/goal set x'), 'goal');
      expect(commandNameOf('/compact'), 'compact');
      expect(commandNameOf('  /export  now  '), 'export');
      expect(commandNameOf('plain text'), isNull);
      expect(commandNameOf('/'), isNull);
      expect(commandNameOf('/ '), isNull);
    });
  });
}
