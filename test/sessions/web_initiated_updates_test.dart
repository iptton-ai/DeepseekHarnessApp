// 复现(用户澄清版):终止会话的重启/新会话发生在 WEB 端,
// 手机端作为另一客户端应通过下行流被动更新。
// 活体探针(双客户端,隔离 host 3099)证明服务端对两路客户端全量广播:
// - web 新建会话 → 手机收 host/session-added + session/subscribed + 事件流
// - web 重发终止会话 → 手机收 host/session-status(true) + user/message 事件
// 本文件断言 Flutter 客户端正确消费这些帧(对齐 web 端 recordMutation 语义)。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/session_store.dart';

import '../helpers/fake_dsh_host.dart';

Map<String, dynamic> userMessageOf(int seq, int time) => <String, dynamic>{
      'type': 'user/message',
      'seq': seq,
      'time': time,
      'data': <String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'web 侧消息'},
        ],
        'source': <String, dynamic>{'kind': 'user'},
      },
    };

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
      'updatedAt': 1000,
      'running': false, // 已终止
      'blank': false,
      'cwd': '/tmp/s1',
    });
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

  test('web 新建会话:host/session-added 应并入手机摘要列表', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));
    expect(store.currentSummaries, hasLength(1));

    // web 端 session.create → 手机收 host/session-added(活体实测形状)。
    final next = store.summaries.first
        .timeout(const Duration(seconds: 3))
        .then((l) => l.length);
    sendHostFrame(host, <String, dynamic>{
      'type': 'host/session-added',
      'sessionId': 'session-web-new',
      'blank': true,
      'cwd': '/tmp/web',
    });
    expect(await next, 2, reason: 'web 新建会话应即时出现在手机列表');
    final added = store.currentSummaries
        .firstWhere((s) => s.sessionId == 'session-web-new');
    expect(added.blank, isTrue);
    expect(added.running, isFalse);

    // 随后 running=true(首条消息):status 帧对新并入行同样生效,且清 blank。
    sendHostFrame(host, <String, dynamic>{
      'type': 'host/session-status',
      'sessionId': 'session-web-new',
      'running': true,
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final running = store.currentSummaries
        .firstWhere((s) => s.sessionId == 'session-web-new');
    expect(running.running, isTrue);
    expect(running.blank, isFalse, reason: '首 turn 开跑即非 blank(对齐 web status mutation)');
  });

  test('web 重发终止会话:user/message 事件应推进摘要 updatedAt(侧栏时间/排序)', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));
    expect(store.currentSummaries.first.updatedAt, 1000);

    // web 端 prompt 终止会话 → 手机收 user/message 事件(活体实测 seq=21 形状)。
    final next = store.summaries.first
        .timeout(const Duration(seconds: 3))
        .then((l) => l.first.updatedAt);
    host.pushSessionEvent('session-s1', userMessageOf(21, 5000));
    expect(await next, 5000, reason: 'web 侧消息应推进手机摘要的活动时间');

    // 低时间重放(重连重放帧)不回退。
    host.pushSessionEvent('session-s1', userMessageOf(21, 4000));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(store.currentSummaries.first.updatedAt, 5000);
  });

  test('web 删除会话:host/session-removed 应移出手机摘要列表', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));

    final next = store.summaries.first
        .timeout(const Duration(seconds: 3))
        .then((l) => l.length);
    sendHostFrame(host, <String, dynamic>{
      'type': 'host/session-removed',
      'sessionId': 'session-s1',
    });
    expect(await next, 0, reason: '会话被移除应即时消失');
  });
}
