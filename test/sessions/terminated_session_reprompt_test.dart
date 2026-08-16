// 复现:被手动/自然终止的会话,用户继续发消息,客户端不更新。
// 回放 2026-08-15 活体探针(隔离 dsh host 3099)录制的帧序列:
// 终止态会话(running=false)→ session.prompt(queue) → host/session-status
// running=true → session/event 流。断言摘要与日志都应前进。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/session_store.dart';

import '../helpers/fake_dsh_host.dart';

Map<String, dynamic> eventOf(int seq, String type, {Map<String, dynamic>? data}) =>
    <String, dynamic>{
      'type': type,
      'seq': seq,
      'time': 1786723605000 + seq,
      'data': data ?? <String, dynamic>{'n': seq},
    };

/// FakeDshHost 缺 host 帧推送(仅 mux);测试内直连 hostSockets 补一帧。
void sendHostFrame(FakeDshHost host, Map<String, dynamic> payload) {
  final raw = jsonEncode(<String, dynamic>{
    'type': 'server-request',
    'rpcId': 'fake-host-frame-' + DateTime.now().microsecondsSinceEpoch.toString(),
    'method': payload['type'] as String,
    'payload': payload,
  });
  for (final ws in host.hostSockets) {
    ws.add(raw);
  }
}

void main() {
  late FakeDshHost host;
  late ConnectionController controller;
  late ApiClient api;
  late SessionStore store;

  setUp(() async {
    host = await FakeDshHost.start();
    host.summaries.add(<String, dynamic>{
      'sessionId': 'session-s1',
      'updatedAt': 1786723600000,
      'running': false, // 已终止的会话
      'blank': false,
      'cwd': '/tmp/s1',
    });
    host.sessions['session-s1'] = <Map<String, dynamic>>[
      eventOf(1, 'user/message'),
      eventOf(2, 'assistant/message'),
    ];
    controller = ConnectionController(
      baseUri: host.baseUri,
      initialBackoff: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 150),
      probeTimeout: const Duration(milliseconds: 400),
    );
    api = ApiClient(baseUri: host.baseUri);
    store = SessionStore(api: api, connection: controller);
  });

  tearDown(() async {
    await store.dispose();
    await controller.dispose();
    api.dispose();
    await host.stop();
  });

  test('终止会话重新发消息:status 翻转 + 事件流都应落地', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));
    await store.loadHistory('session-s1');
    final log = store.logFor('session-s1');
    expect(log.events, hasLength(2));
    expect(store.currentSummaries.first.running, isFalse);

    // ── 用户在终止会话上继续发消息(mode:queue) ──
    final promptAck = store.promptText('session-s1', '继续干活');

    // 服务端(活体实测 Phase 2/4):prompt 受理后立刻推 status running=true。
    sendHostFrame(host, <String, dynamic>{
      'type': 'host/session-status',
      'sessionId': 'session-s1',
      'running': true,
    });
    await promptAck;

    // 断言 1:摘要 running 翻转为 true(composer 据此切「插话/停止」态)。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      store.currentSummaries.first.running,
      isTrue,
      reason: '终止会话重新发消息后 running 应回 true',
    );

    // ── 服务端:新 turn 的事件流(user/message → assistant) ──
    host.pushSessionEvent('session-s1', eventOf(3, 'user/message'));
    await log.eventStream.first.timeout(const Duration(seconds: 3));
    host.pushSessionEvent('session-s1', eventOf(4, 'assistant/message'));
    await log.eventStream.first.timeout(const Duration(seconds: 3));
    expect(log.events, hasLength(4));
    expect(log.events.map((e) => e.seq).toList(), [1, 2, 3, 4]);

    // turn 结束:running=false 回落。
    sendHostFrame(host, <String, dynamic>{
      'type': 'host/session-status',
      'sessionId': 'session-s1',
      'running': false,
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(store.currentSummaries.first.running, isFalse);
  });
}
