// AgentPresetStore 域测试:agentPreset.list|select 包格式、目录缓存、
// 代际翻转与 remote-event(agent-preset/selected)失效。
// 模式:自建最小假主机(describe + agent-presets/* + 双 WS 下行),
// 同 command_store_test,不 import 共享 helper。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/agent_preset_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 最小假主机:describe + agentPreset.list|select(点命名路由,同真主机)+ 双 WS。
class _FakeHost {
  _FakeHost._(this._server);
  final HttpServer _server;
  final List<WebSocket> _mux = <WebSocket>[];
  final List<WebSocket> _host = <WebSocket>[];

  List<Map<String, dynamic>> presets = <Map<String, dynamic>>[
    _preset('standard', name: '标准模式', isDefault: true),
    _preset('minimal', name: '极简模式'),
  ];
  Map<String, dynamic>? lastSelectPayload;
  int listRequests = 0;
  int _frameNo = 0;

  Uri get baseUri => Uri.parse('http://127.0.0.1:' + _server.port.toString());

  /// 推一条 host/remote-event 帧(host 流;server-request 信封)。
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

  static Map<String, dynamic> _preset(String id,
      {String? name, bool isDefault = false}) {
    return <String, dynamic>{
      'id': id,
      'trust': <String, dynamic>{},
      'isDefault': isDefault,
      if (name != null) 'name': name,
    };
  }

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
    if (req.method == 'POST' && path == '/api/agentPreset.list') {
      listRequests += 1;
      final envelope = await _readJson(req);
      await _respond(req, {
        'type': 'server-response',
        'rpcId': envelope['rpcId'],
        'result': {
          'ok': true,
          'value': <String, dynamic>{
            'presets': presets,
            'authorable': false,
            'hasDocument': false,
          },
        },
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/agentPreset.select') {
      final envelope = await _readJson(req);
      lastSelectPayload =
          (envelope['payload'] as Map<String, dynamic>).cast<String, dynamic>();
      await _respond(req, {
        'type': 'server-response',
        'rpcId': envelope['rpcId'],
        'result': {
          'ok': true,
          'value': <String, dynamic>{'agentPreset': 'minimal'},
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

  Future<void> stop() async {
    for (final ws in [..._mux, ..._host]) {
      await ws.close();
    }
    await _server.close(force: true);
  }
}

void main() {
  group('AgentPresetStore 域', () {
    late _FakeHost host;
    late ConnectionController controller;
    late ApiClient api;
    late AgentPresetStore store;

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
      store = AgentPresetStore(api: api, connection: controller);
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

    test('list:解析 presets/authorable/hasDocument', () async {
      final value = await store.list();
      expect(value.presets, hasLength(2));
      expect(value.presets[0].id, 'standard');
      expect(value.presets[0].name, '标准模式');
      expect(value.presets[0].isDefault, isTrue);
      expect(value.presets[1].isDefault, isFalse);
      expect(value.authorable, isFalse);
      expect(store.listCalls, 1);
    });

    test('缓存:同代际第二次 list 不再发 HTTP;force 绕过', () async {
      await store.list();
      await store.list();
      expect(host.listRequests, 1);
      await store.list(force: true);
      expect(host.listRequests, 2);
    });

    test('select:载荷 {sessionId, agentPreset},值回流', () async {
      final value = await store.select('session-s1', 'minimal');
      expect(value.agentPreset, 'minimal');
      expect(host.lastSelectPayload, <String, dynamic>{
        'sessionId': 'session-s1',
        'agentPreset': 'minimal',
      });
    });

    // 防回归:wire 方法名是 RpcMethodMap 的点命名(agentPreset.*)。
    // 斜杠名真主机 404 —— 曾因此「预设目录加载失败」而假主机镜像了同一
    // 错误路径照样全绿(2026-08-17 用户实报),此处钉死真实路由形状。
    test('wire 方法名点命名;斜杠路由必载波 404', () async {
      expect(RpcMethods.agentPresetList, 'agentPreset.list');
      expect(RpcMethods.agentPresetSelect, 'agentPreset.select');
      await expectLater(
        api.call('agent-presets/list', <String, dynamic>{},
            parse: AgentPresetListValue.fromJson),
        throwsA(isA<CarrierError>()),
      );
    });

    test('remote-event agent-preset/selected → 目录缓存失效', () async {
      await store.list();
      expect(host.listRequests, 1);
      host.pushRemoteEvent(
          'agent-preset/selected', <dynamic>['session-s1', 'minimal']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await store.list();
      expect(host.listRequests, 2);
    });
  });
}
