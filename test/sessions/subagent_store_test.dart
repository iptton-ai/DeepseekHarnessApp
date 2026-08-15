// SubagentStore 域测试(内建最小假主机,不 import 共享 helper):
// list 缓存与失效(代际翻转/父会话状态翻转)、history 翻页装载 + seq 去重、
// prompt/interrupt 信封、错误码传播(subagent-parent-unavailable /
// subagent-not-found / subagent-not-resumable)与文案映射。
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

  test('父会话运行状态翻转 → 其目录缓存失效', () async {
    host.listEntries = [childEntry('child-1', 'continuable', 'inactive', label: '子代理一')];
    await ready();
    await store.listChildren('parent-1');
    expect(store.catalogFor('parent-1'), isNotNull);

    host.sendHostFrame({
      'type': 'host/session-status',
      'sessionId': 'parent-1',
      'running': true,
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(store.catalogFor('parent-1'), isNull);
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

  test('readTranscript 翻页装载 + seq 去重幂等', () async {
    host.childEvents['child-1'] = [
      eventOf(1, 'user/message'),
      eventOf(2, 'assistant/message'),
      eventOf(3, 'user/message'),
    ];
    await ready();
    final events = await store.readTranscript('parent-1', 'child-1',
        mode: 'continuable', maxMessages: 2);
    expect(events.map((e) => e.seq).toList(), [1, 2, 3]);
    expect(host.historyRequests, hasLength(2)); // 翻页:尾页 + 前页
    expect(host.historyRequests[0]['mode'], 'continuable');
    expect(host.historyRequests[0]['beforeSeq'], isNull);

    // 幂等:重复装载不产生重复事件(靠 seq 去重)。
    final again = await store.readTranscript('parent-1', 'child-1',
        mode: 'continuable');
    expect(again.map((e) => e.seq).toList(), [1, 2, 3]);
    expect(store.transcriptFor('child-1').events, hasLength(3));
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

  test('list 错误码传播:subagent-parent-unavailable + 文案映射', () async {
    host.nextListError = 'subagent-parent-unavailable';
    await ready();
    await expectLater(
      store.listChildren('parent-1'),
      throwsA(isA<RpcBusinessError>().having((e) => e.error, 'error',
          isA<RpcErrorSubagentParentUnavailable>())),
    );
    // UI 文案映射(纯 Dart 助手)。
    const err = RpcErrorSubagentParentUnavailable(
        message: 'parent gone', details: <String, dynamic>{});
    expect(subagentErrorMessage(const RpcBusinessError(err)), contains('父会话不可用'));
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
