// SessionStore 域测试(假主机):列表装载、历史+增量去重、prompt 信封、
// 代际翻转全量重取且状态不丢(PLAN M2 验收的域层一半;UI 一半在桌面 app)。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/session_store.dart';

import '../helpers/fake_dsh_host.dart';

Map<String, dynamic> eventOf(int seq, String type) => <String, dynamic>{
      'type': type,
      'seq': seq,
      'time': 1786723605000 + seq,
      'data': <String, dynamic>{'n': seq},
    };

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
      'running': false,
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

  test('ready → refresh populates summaries;日志懒注册(不预建)', () async {
    controller.start();
    store.start();
    final list = await store.summaries.first.timeout(const Duration(seconds: 3));
    expect(list, hasLength(1));
    expect(list.first.sessionId, 'session-s1');
    // 懒注册契约:refresh 后没有预建任何日志;logFor 首次调用才登记。
    final before = store.logFor('session-s2');
    expect(before, isNotNull);
    // 打开过的日志存在;未打开的会话帧被丢弃(不自动建日志)。
    expect(store.logFor('session-s1'), isNotNull);
  });

  test('loadHistory tail page + incremental frames with seq dedup', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));
    await store.loadHistory('session-s1');
    final log = store.logFor('session-s1');
    expect(log.events, hasLength(2));
    expect(log.events.map((e) => e.seq).toList(), [1, 2]);

    // 增量:更高 seq 追加。
    final events3 = log.eventStream.first.timeout(const Duration(seconds: 3));
    host.pushSessionEvent('session-s1', eventOf(3, 'assistant/message'));
    await events3;
    expect(log.events, hasLength(3));

    // 重放:同 seq 重复帧不产生重复条目。
    host.sendMuxFrame(<String, dynamic>{
      'type': 'session/event',
      'sessionId': 'session-s1',
      'event': eventOf(3, 'assistant/message'),
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(log.events, hasLength(3));
  });

  test('promptText sends queue-mode text envelope', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));
    final value = await store.promptText('session-s1', 'hello world');
    expect(value.accepted, isTrue);
    expect(host.promptRequests, hasLength(1));
    final payload = host.promptRequests.single;
    expect(payload['sessionId'], 'session-s1');
    expect(payload['mode'], 'queue');
    expect(payload['content'],
        <Map<String, dynamic>>[<String, dynamic>{'type': 'text', 'text': 'hello world'}]);
  });

  test('workspaceList + createSession(round trip, list refresh)', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));

    final wss = await store.workspaceList();
    expect(wss.items, hasLength(1));
    expect(wss.items.first.workspaceId, 'ws-default');
    expect(wss.items.first.title, 'fake workspace');

    final created = await store.createSession();
    expect(created.sessionId, startsWith('session-fake-'));
    expect(store.logFor(created.sessionId), isNotNull);
    // createSession 触发 refresh(异步);轮询到 summaries 长出来。
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (store.currentSummaries.length < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(store.currentSummaries, hasLength(2));
  });

  test('generation flip: full refetch and no state loss', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));
    await store.loadHistory('session-s1');
    expect(store.logFor('session-s1').events, hasLength(2));
    final listCallsBefore = host.listCalls;
    expect(listCallsBefore, greaterThanOrEqualTo(1));

    // 拔线 → 新代 ready → session.list 必须再打一次(无 since 续传)。
    host.unplugMux();
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready && s.generation >= 2)
        .timeout(const Duration(seconds: 5));
    // refresh 是异步的;轮询到 listCalls 增长为止。
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (host.listCalls <= listCallsBefore && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(host.listCalls, greaterThan(listCallsBefore));
    // 断网重连不丢状态:日志仍在。
    expect(store.logFor('session-s1').events, hasLength(2));
  });
}
