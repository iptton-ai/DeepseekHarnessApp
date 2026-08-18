// SubagentStore 域测试(内建最小假主机,不 import 共享 helper):
// list 缓存与失效(代际翻转/父会话状态翻转)、history 翻页装载 + seq 去重、
// prompt/interrupt 信封、错误码传播(subagent-parent-unavailable /
// subagent-not-found / subagent-not-resumable)与文案映射。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/subagent_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 最小假主机:host.describe + 双 WS 下行 + subagent 四方法,可编程业务错误。
class FakeSubagentHost {
  FakeSubagentHost._(this._server);
  final HttpServer _server;
  final muxSockets = <WebSocket>[];
  final hostSockets = <WebSocket>[];

  int subagentListCalls = 0;
  final listRequests = <Map<String, dynamic>>[];
  final historyRequests = <Map<String, dynamic>>[];
  final promptRequests = <Map<String, dynamic>>[];
  final interruptRequests = <Map<String, dynamic>>[];

  List<Map<String, dynamic>> listEntries = <Map<String, dynamic>>[];
  bool parentAvailable = true;
  final childEvents = <String, List<Map<String, dynamic>>>{};
  int nextPromptNo = 1;

  // 一次性错误注入:置码后下一个同方法请求返回该业务错误并复位。
  String? nextListError;
  String? nextHistoryError;
  String? nextPromptError;
  String? nextInterruptError;

  static Future<FakeSubagentHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = FakeSubagentHost._(server);
    server.listen((req) => host._handle(req));
    return host;
  }

  int get port => _server.port;
  Uri get baseUri => Uri.parse('http://127.0.0.1:$port');

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/api/host.describe') {
      final envelope = await _readEnvelope(req);
      await _ok(req, envelope['rpcId'] as String, {
        'version': '0.0.1-fake',
        'cwd': '/tmp/fake',
        'provider': 'fake',
        'model': 'fake-model',
        'attachedSessions': 0,
        'canOpenPath': false,
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/subagent.list') {
      subagentListCalls += 1;
      final envelope = await _readEnvelope(req);
      listRequests.add(envelope['payload'] as Map<String, dynamic>);
      final err = nextListError;
      if (err != null) {
        nextListError = null;
        await _bizError(req, envelope['rpcId'] as String, err);
        return;
      }
      await _ok(req, envelope['rpcId'] as String, {
        'entries': listEntries,
        'parentAvailable': parentAvailable,
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/subagent.history') {
      final envelope = await _readEnvelope(req);
      final payload = envelope['payload'] as Map<String, dynamic>;
      historyRequests.add(payload);
      final err = nextHistoryError;
      if (err != null) {
        nextHistoryError = null;
        await _bizError(req, envelope['rpcId'] as String, err);
        return;
      }
      final childId = payload['childSessionId'] as String;
      final events = childEvents[childId] ?? <Map<String, dynamic>>[];
      final before = payload['beforeSeq'] as int?;
      final max = (payload['maxMessages'] as num?)?.toInt() ?? 50;
      var pool = events;
      if (before != null) {
        pool = events
            .where((e) => (e['seq'] as num).toInt() < before)
            .toList();
      }
      final start = pool.length > max ? pool.length - max : 0;
      final page = pool.sublist(start);
      await _ok(req, envelope['rpcId'] as String, {
        'events': [for (final e in page) <String, dynamic>{'event': e}],
        'hasMore': start > 0,
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/subagent.prompt') {
      final envelope = await _readEnvelope(req);
      promptRequests.add(envelope['payload'] as Map<String, dynamic>);
      final err = nextPromptError;
      if (err != null) {
        nextPromptError = null;
        await _bizError(req, envelope['rpcId'] as String, err);
        return;
      }
      await _ok(req, envelope['rpcId'] as String,
          {'messageId': 'msg-${nextPromptNo++}'});
      return;
    }
    if (req.method == 'POST' && path == '/api/subagent.interrupt') {
      final envelope = await _readEnvelope(req);
      interruptRequests.add(envelope['payload'] as Map<String, dynamic>);
      final err = nextInterruptError;
      if (err != null) {
        nextInterruptError = null;
        await _bizError(req, envelope['rpcId'] as String, err);
        return;
      }
      await _ok(req, envelope['rpcId'] as String, {'accepted': true});
      return;
    }
    if (path == '/api/events.mux' || path == '/api/events.host') {
      final ws = await WebSocketTransformer.upgrade(req);
      (path.endsWith('mux') ? muxSockets : hostSockets).add(ws);
      ws.listen((_) {});
      return;
    }
    req.response.statusCode = 404;
    req.response.write('not found');
    await req.response.close();
  }

  Future<Map<String, dynamic>> _readEnvelope(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<void> _ok(HttpRequest req, String rpcId, Map<String, dynamic> value) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'type': 'server-response',
      'rpcId': rpcId,
      'result': {'ok': true, 'value': value},
    }));
    await req.response.close();
  }

  Future<void> _bizError(HttpRequest req, String rpcId, String code) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'type': 'server-response',
      'rpcId': rpcId,
      'result': {
        'ok': false,
        'error': {'code': code, 'message': code, 'details': <String, dynamic>{}},
      },
    }));
    await req.response.close();
  }

  /// 往 mux 流推一帧(server-request 信封)。
  void sendMuxFrame(Map<String, dynamic> payload) {
    for (final ws in muxSockets) {
      ws.add(jsonEncode({
        'type': 'server-request',
        'rpcId': 'fake-frame',
        'method': payload['type'] as String,
        'payload': payload,
      }));
    }
  }

  /// 往 host 流推一帧。
  void sendHostFrame(Map<String, dynamic> payload) {
    for (final ws in hostSockets) {
      ws.add(jsonEncode({
        'type': 'server-request',
        'rpcId': 'fake-frame',
        'method': payload['type'] as String,
        'payload': payload,
      }));
    }
  }

  /// 追加子会话事件并推 mux session/event 帧。
  void pushSessionEvent(String sessionId, Map<String, dynamic> event) {
    childEvents.putIfAbsent(sessionId, () => <Map<String, dynamic>>[]).add(event);
    sendMuxFrame({
      'type': 'session/event',
      'sessionId': sessionId,
      'event': event,
    });
  }

  /// 拔线:只关 mux socket(留 host 存活),触发整代重建。
  void unplugMux() {
    for (final ws in muxSockets.toList()) {
      ws.close(1001, 'unplugged');
    }
    muxSockets.clear();
  }

  Future<void> stop() async {
    for (final ws in [...muxSockets, ...hostSockets]) {
      try {
        await ws.close();
      } catch (_) {}
    }
    muxSockets.clear();
    hostSockets.clear();
    await _server.close(force: true);
  }
}

Map<String, dynamic> childEntry(String id, String mode, String activity,
        {String? label}) =>
    <String, dynamic>{
      'kind': 'child',
      'id': id,
      'mode': mode,
      'activity': activity,
      'hasChildren': false,
      if (label != null) 'label': label,
    };

Map<String, dynamic> eventOf(int seq, String type) => <String, dynamic>{
      'type': type,
      'seq': seq,
      'time': 1786723605000 + seq,
      'data': <String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': '文本$seq'},
        ],
      },
    };

void main() {
  late FakeSubagentHost host;
  late ConnectionController controller;
  late ApiClient api;
  late SubagentStore store;

  setUp(() async {
    host = await FakeSubagentHost.start();
    controller = ConnectionController(
      baseUri: host.baseUri,
      initialBackoff: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 150),
      probeTimeout: const Duration(milliseconds: 400),
    );
    api = ApiClient(baseUri: host.baseUri);
    store = SubagentStore(api: api, connection: controller);
  });

  tearDown(() async {
    await store.dispose();
    await controller.dispose();
    api.dispose();
    await host.stop();
  });

  /// 启动连接并等到代际 ready(store 的代际失效已处理)。
  Future<void> ready() async {
    controller.start();
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 3));
    await Future<void>.delayed(Duration.zero);
  }

  test('listChildren 拉取并缓存(二次调用不再发 RPC)', () async {
    host.listEntries = [childEntry('child-1', 'continuable', 'inactive', label: '子代理一')];
    await ready();
    final v1 = await store.listChildren('parent-1');
    expect(v1.entries, hasLength(1));
    expect(host.subagentListCalls, 1);
    final v2 = await store.listChildren('parent-1');
    expect(identical(v1, v2), isTrue);
    expect(host.subagentListCalls, 1);
  });

  test('目录缓存按 parent 隔离', () async {
    host.listEntries = [childEntry('child-a', 'one-shot', 'inactive')];
    await ready();
    await store.listChildren('parent-a');
    await store.listChildren('parent-b');
    expect(host.subagentListCalls, 2);
    // 再次访问各自缓存,不再发 RPC。
    await store.listChildren('parent-a');
    await store.listChildren('parent-b');
    expect(host.subagentListCalls, 2);
    expect(store.catalogFor('parent-a'), isNotNull);
    expect(store.catalogFor('parent-b'), isNotNull);
  });

  test('目录缓存随代际翻转失效(重连后重取)', () async {
    host.listEntries = [childEntry('child-1', 'continuable', 'inactive', label: '子代理一')];
    await ready();
    await store.listChildren('parent-1');
    expect(host.subagentListCalls, 1);

    host.unplugMux();
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready && s.generation >= 2)
        .timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(store.catalogFor('parent-1'), isNull); // 代际翻转即失效

    await store.listChildren('parent-1');
    expect(host.subagentListCalls, 2); // 重连=全量重取
  });

  test('host/session-status → child 行 activity 行内翻转(零 RPC,目录不失效)', () async {
    host.listEntries = [childEntry('child-1', 'continuable', 'inactive', label: '子代理一')];
    await ready();
    await store.listChildren('parent-1');
    final before = host.subagentListCalls;

    host.sendHostFrame({
      'type': 'host/session-status',
      'sessionId': 'child-1',
      'running': true,
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final catalog = store.catalogFor('parent-1');
    expect(catalog, isNotNull); // 不失效
    expect(catalog!.phase, SubagentCatalogPhase.ready);
    final row = catalog.entries.single as SubagentListEntryChild;
    expect(row.activity, 'running'); // 行内翻转
    expect(host.subagentListCalls, before); // 零 RPC

    // 翻回 inactive 同样行内。
    host.sendHostFrame({
      'type': 'host/session-status',
      'sessionId': 'child-1',
      'running': false,
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      (store.catalogFor('parent-1')!.entries.single as SubagentListEntryChild)
          .activity,
      'inactive',
    );
  });

  test('list 保留 diagnostic 行:可读但标记不可用;无 label 回退 id', () async {
    host.listEntries = [
      childEntry('child-1', 'one-shot', 'inactive', label: '子代理一'),
      <String, dynamic>{'kind': 'diagnostic', 'id': 'child-broken', 'reason': 'corrupt'},
    ];
    await ready();
    final v = await store.listChildren('parent-1');
    expect(v.entries, hasLength(2));
    final child = v.entries[0];
    final diag = v.entries[1];
    expect(child, isA<SubagentListEntryChild>());
    expect(diag, isA<SubagentListEntryDiagnostic>());
    expect(subagentEntryUsable(child), isTrue);
    expect(subagentEntryUsable(diag), isFalse); // 标记不可用
    expect(subagentEntryTitle(child), '子代理一');
    expect(subagentEntryTitle(diag), contains('corrupt')); // 保留可读

    // 无 label 的 child 回退 sessionId。
    host.listEntries = [childEntry('child-nolabel', 'one-shot', 'inactive')];
    final v2 = await store.listChildren('parent-2');
    expect(subagentEntryTitle(v2.entries.single), 'child-nolabel');
  });

  test('readTranscript 默认单页尾页;loadOlder 逐页向前;去重幂等', () async {
    host.childEvents['child-1'] = [
      eventOf(1, 'user/message'),
      eventOf(2, 'assistant/message'),
      eventOf(3, 'user/message'),
    ];
    await ready();
    // 性能契约:默认只拉尾页(maxMessages 限制单页)。
    final events = await store.readTranscript('parent-1', 'child-1',
        mode: 'continuable', maxMessages: 2);
    expect(events.map((e) => e.seq).toList(), [2, 3]); // 尾页
    expect(host.historyRequests, hasLength(1)); // 不再自动翻页
    expect(store.transcriptFor('child-1').hasOlder, isTrue);

    // loadOlder 向前补一页(beforeSeq=尾页最早 seq)。
    await store.loadOlderTranscript('parent-1', 'child-1', mode: 'continuable');
    expect(store.transcriptFor('child-1').events.map((e) => e.seq).toList(),
        [1, 2, 3]);
    expect(host.historyRequests.last['beforeSeq'], 2);
    expect(store.transcriptFor('child-1').hasOlder, isFalse);

    // 幂等:重复装载只重取尾页(事件靠 seq 去重);无更早 loadOlder no-op。
    final before = host.historyRequests.length;
    final again = await store.readTranscript('parent-1', 'child-1',
        mode: 'continuable');
    expect(again.map((e) => e.seq).toList(), [1, 2, 3]);
    expect(host.historyRequests.length, before + 1); // 尾页刷新一次
    await store.loadOlderTranscript('parent-1', 'child-1', mode: 'continuable');
    expect(host.historyRequests.length, before + 1); // no-op 零请求
  });

  test('mux session/event 帧增量追加到已缓存 transcript', () async {
    host.childEvents['child-1'] = [eventOf(1, 'user/message')];
    await ready();
    await store.readTranscript('parent-1', 'child-1', mode: 'continuable');
    expect(store.transcriptFor('child-1').events, hasLength(1));

    final next = store
        .transcriptFor('child-1')
        .eventStream
        .first
        .timeout(const Duration(seconds: 3));
    host.pushSessionEvent('child-1', eventOf(2, 'assistant/message'));
    await next;
    expect(store.transcriptFor('child-1').events, hasLength(2));
  });

  test('promptChild 发送续聊信封并返回 messageId', () async {
    await ready();
    final value =
        await store.promptChild('parent-1', 'child-1', '继续', clientTimeZone: 'UTC');
    expect(value.messageId, startsWith('msg-'));
    expect(host.promptRequests, hasLength(1));
    final payload = host.promptRequests.single;
    expect(payload['parentSessionId'], 'parent-1');
    expect(payload['childSessionId'], 'child-1');
    expect(payload['mode'], 'continuable');
    expect(payload['content'],
        <Map<String, dynamic>>[<String, dynamic>{'type': 'text', 'text': '继续'}]);
    expect(payload['clientTimeZone'], 'UTC');
  });

  test('interruptChild 发送中断信封并返回 accepted', () async {
    await ready();
    final value = await store.interruptChild('parent-1', 'child-1');
    expect(value.accepted, isTrue);
    expect(host.interruptRequests, hasLength(1));
    final payload = host.interruptRequests.single;
    expect(payload['parentSessionId'], 'parent-1');
    expect(payload['childSessionId'], 'child-1');
    expect(payload['mode'], 'continuable');
  });

  test('list 错误折叠进 error 态(不抛);重试恢复 ready', () async {
    host.nextListError = 'subagent-parent-unavailable';
    await ready();
    final state = await store.listChildren('parent-1');
    expect(state.phase, SubagentCatalogPhase.error);
    // 错误对象保留在 state 上(UI 呈现可读文案)。
    expect(subagentErrorMessage(state.error!), contains('父会话不可用'));

    // 重试:错误态下缓存不再命中,恢复 ready。
    final ok = await store.listChildren('parent-1');
    expect(ok.phase, SubagentCatalogPhase.ready);
  });

  test('错误保留旧 entries(刷新失败旧数据仍可用)', () async {
    host.listEntries = [childEntry('child-1', 'one-shot', 'inactive', label: '旧数据')];
    await ready();
    await store.listChildren('parent-1');
    host.nextListError = 'internal';
    final state = await store.listChildren('parent-1', force: true);
    expect(state.phase, SubagentCatalogPhase.error);
    expect(state.entries, hasLength(1)); // 旧 entries 保留
    expect((state.entries.single as SubagentListEntryChild).label, '旧数据');
  });

  test('单飞:并发两次未缓存刷新共享一次往返', () async {
    host.listEntries = [childEntry('child-1', 'one-shot', 'inactive')];
    await ready();
    final results = await Future.wait([
      store.listChildren('parent-1'),
      store.listChildren('parent-1'),
    ]);
    expect(host.subagentListCalls, 1);
    expect(identical(results[0], results[1]), isTrue);
  });

  test('host/session-added(origin=subagent)→ hasChildren 正提示 + 防抖重拉子目录', () async {
    host.listEntries = [childEntry('child-1', 'continuable', 'inactive', label: '子代理一')];
    await ready();
    await store.listChildren('parent-1');
    // 子目录(child-1)拉过一次(模拟展开)。
    host.listEntries = [childEntry('grand-1', 'one-shot', 'inactive')];
    await store.listChildren('child-1');
    final before = host.subagentListCalls;

    host.sendHostFrame({
      'type': 'host/session-added',
      'sessionId': 'grand-2',
      'blank': false,
      'parentSessionId': 'child-1',
      'origin': 'subagent',
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // ① parent-1 目录里 child-1 行获得展开提示。
    final row =
        store.catalogFor('parent-1')!.entries.single as SubagentListEntryChild;
    expect(row.hasChildren, isTrue);
    // ② 防抖重拉 child-1 的目录(新孙行可见)。
    expect(host.subagentListCalls, greaterThan(before));
    expect(host.listRequests.last['parentSessionId'], 'child-1');
  });

  test('host/session-removed → 行内折 activity + owner 目录 parentAvailable=false', () async {
    host.listEntries = [childEntry('child-1', 'continuable', 'running', label: '子代理一')];
    await ready();
    await store.listChildren('parent-1');
    // child-1 自己也是目录 owner(展开过),parentAvailable=true。
    host.listEntries = [];
    await store.listChildren('child-1');
    expect(store.catalogFor('child-1')!.parentAvailable, isTrue);

    host.sendHostFrame({'type': 'host/session-removed', 'sessionId': 'child-1'});
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // ① parent-1 目录里行折叠为 inactive(行保留,不删)。
    final row =
        store.catalogFor('parent-1')!.entries.single as SubagentListEntryChild;
    expect(row.activity, 'inactive');
    // ② child-1 作为 owner 的目录 parentAvailable 即时置 false(不重拉)。
    final owned = store.catalogFor('child-1');
    expect(owned, isNotNull);
    expect(owned!.parentAvailable, isFalse);
  });

  test('后代聚合:不间断血统链向上累计,fork 断链,等值不重发', () async {
    final summaries = StreamController<List<SessionSummary>>.broadcast();
    final aggStore = SubagentStore(
        api: api, connection: controller, summaries: summaries.stream);
    addTearDown(() async {
      await summaries.close();
      await aggStore.dispose();
    });
    await ready();

    var emissions = 0;
    final sub = aggStore.descendants.listen((_) => emissions += 1);
    addTearDown(() => sub.cancel());

    SessionSummary summary(String id, String? parent, String? origin,
            {bool running = false}) =>
        SessionSummary(
          sessionId: id,
          updatedAt: 1,
          running: running,
          blank: false,
          parentSessionId: parent,
          origin: origin,
        );

    // root ← child(subagent, running) ← grand(subagent);fork1 是 root 的普通 fork。
    summaries.add([
      summary('root', null, null),
      summary('child', 'root', 'subagent', running: true),
      summary('grand', 'child', 'subagent'),
      summary('fork1', 'root', null),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(aggStore.currentDescendants['root']!.count, 2); // child+grand
    expect(aggStore.currentDescendants['root']!.runningCount, 1);
    expect(aggStore.currentDescendants['child']!.count, 1); // grand
    expect(aggStore.currentDescendants['fork1'], isNull); // fork 无 subagent 子代

    // 等值重发不重复广播。
    summaries.add([
      summary('root', null, null),
      summary('child', 'root', 'subagent', running: true),
      summary('grand', 'child', 'subagent'),
      summary('fork1', 'root', null),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(emissions, 1);

    // running 翻转 → 计数更新 + 重发。
    summaries.add([
      summary('root', null, null),
      summary('child', 'root', 'subagent', running: false),
      summary('grand', 'child', 'subagent'),
      summary('fork1', 'root', null),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(aggStore.currentDescendants['root']!.runningCount, 0);
    expect(emissions, 2);
  });

  test('history 错误码传播:subagent-not-found', () async {
    host.nextHistoryError = 'subagent-not-found';
    await ready();
    await expectLater(
      store.readTranscript('parent-1', 'child-x', mode: 'continuable'),
      throwsA(isA<RpcBusinessError>().having((e) => e.error, 'error',
          isA<RpcErrorSubagentNotFound>())),
    );
  });

  test('prompt 错误码传播:subagent-not-resumable', () async {
    host.nextPromptError = 'subagent-not-resumable';
    await ready();
    await expectLater(
      store.promptChild('parent-1', 'child-1', 'hi'),
      throwsA(isA<RpcBusinessError>().having((e) => e.error, 'error',
          isA<RpcErrorSubagentNotResumable>())),
    );
  });
}
