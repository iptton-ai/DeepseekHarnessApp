// SessionStore 域测试(假主机):列表装载、历史+增量去重、prompt 信封、
// 代际翻转全量重取且状态不丢(PLAN M2 验收的域层一半;UI 一半在桌面 app)。
import 'dart:async';
import 'dart:convert';

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

  test('session/projection 帧:整值落 overlay 更新摘要流,高 seq 覆盖低 seq',
      () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));

    // title 投影 = 纯字符串整值(rc.6 wire:SessionProjectionMap: string|null)。
    // host 侧 fallback(首条用户消息前 N 词)→ LLM 摘要的演进即两帧。
    var seen = store.summaries.first
        .timeout(const Duration(seconds: 3))
        .then((l) => l.first.projections?.values['title']);
    host.pushProjectionFrame(
      sessionId: 'session-s1',
      key: 'title',
      value: '帮我看看侧栏逻辑',
      seq: 5,
    );
    expect(await seen, '帮我看看侧栏逻辑');
    expect(
      store.currentSummaries.first.projections?.values['title'],
      '帮我看看侧栏逻辑',
    );

    // 低 seq 重放帧:零副作用(值不变,不重发)。
    host.pushProjectionFrame(
      sessionId: 'session-s1',
      key: 'title',
      value: 'stale',
      seq: 3,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      store.currentSummaries.first.projections?.values['title'],
      '帮我看看侧栏逻辑',
    );

    // 更高 seq(LLM 摘要到位):覆盖 fallback。
    seen = store.summaries.first
        .timeout(const Duration(seconds: 3))
        .then((l) => l.first.projections?.values['title']);
    host.pushProjectionFrame(
      sessionId: 'session-s1',
      key: 'title',
      value: '侧栏逻辑调研',
      seq: 8,
    );
    expect(await seen, '侧栏逻辑调研');
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

  test('loadHistory 瞬时载波故障自动退避重试,耗尽前恢复', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));
    // 前两次 500(载波错误,可重试),第三次成功。
    host.failSessionHistoryTimes = 2;
    await store.loadHistory('session-s1');
    expect(store.logFor('session-s1').events, hasLength(2));
    expect(host.historyCalls, 3);

    // 重试耗尽:3 次都失败 → 抛最后错误,不再多打。
    final callsBefore = host.historyCalls;
    host.failSessionHistoryTimes = 3;
    try {
      await store.loadHistory('session-s1');
      fail('should throw');
    } on Object catch (e) {
      expect(e.toString(), contains('CarrierError'));
    }
    expect(host.historyCalls, callsBefore + 3);
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

  // 活体实测(rc.6 3080):list 行的块是「部分基线」—— 可带 6+ 键但
  // 唯独缺 title(冷缓存 version-matching 过滤),且 asOfSeq 很高。
  // 旧实现在 _mergeOne 用块级 asOfSeq 做门槛,把 overlay 里低 seq 的
  // title 丢掉 → 侧栏回落 cwd 目录名(用户实报「标题变回目录名」)。
  test('list 行块缺 title 且 asOf 高:overlay title 不被清,标题不回落目录名', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));

    // 推送帧先落 title(seq 5)。
    host.pushProjectionFrame(
      sessionId: 'session-s1',
      key: 'title',
      value: '移动端侧栏重构',
      seq: 5,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      store.currentSummaries.first.projections?.values['title'],
      '移动端侧栏重构',
    );

    // 重连触发 refresh;新 list 行块带其他键但缺 title,且 asOfSeq(22619)
    // 远高于 title seq —— 部分(块)基线不得清除已收到的 title。
    host.summaries[0] = <String, dynamic>{
      ...host.summaries[0],
      'projections': <String, dynamic>{
        'asOfSeq': 22619,
        'values': <String, dynamic>{
          'goal': null,
          'plan': null,
        },
      },
    };
    await store.refresh();
    expect(
      store.currentSummaries.first.projections?.values['title'],
      '移动端侧栏重构',
      reason: '部分基线(list 行)缺席的键不能凭块级水位清除',
    );
  });

  // 竞态复现:refresh 拉取在飞时,会话完成(host/session-status
  // running=false 先经 WS 到达),随后慢的 list 响应(快照仍是
  // running=true)落地 —— 不重放变更帧会把 false 盖回 true,
  // 侧栏 loading 永久卡死(用户实报「点进去是已完成会话」)。
  test('拉取在飞时到达的 status 帧在基线落地后重放,running 不被陈旧快照盖回', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));

    // 让 list 行快照里是 running=true(host 在会话运行中取的快照)。
    host.summaries[0] = <String, dynamic>{...host.summaries[0], 'running': true};

    // 挂住下一次 list 响应;期间模拟会话完成(WS 帧先行到达)。
    host.listGate = Completer<void>();
    final refreshing = store.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(host.listCalls, greaterThanOrEqualTo(2));
    sendHostFrame(host, <String, dynamic>{
      'type': 'host/session-status',
      'sessionId': 'session-s1',
      'running': false,
    });
    // 帧先折叠:false 已生效。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(store.currentSummaries.first.running, isFalse);

    // 放行响应:快照里的 running=true 不得盖回已折叠的 false。
    host.listGate!.complete();
    await refreshing.timeout(const Duration(seconds: 3));
    expect(
      store.currentSummaries.first.running,
      isFalse,
      reason: '基线落地后必须重放拉取期间到达的变更帧',
    );
  });

  test('并发 refresh 合并为一次在飞往返(listInflight 同构)', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));

    host.listGate = Completer<void>();
    final a = store.refresh();
    final b = store.refresh();
    final before = host.listCalls;
    host.listGate!.complete();
    await Future.wait([a, b]).timeout(const Duration(seconds: 3));
    expect(host.listCalls, before + 1,
        reason: '并发调用共享同一次 session.list,不得各打一发');
  });

  test('尾页块是全量基线:缺席且低于切面的 overlay 键清除,更新帧保留', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));

    // 两个键:title@5(低于尾页切面)、goal@9(高于切面)。
    host.pushProjectionFrame(sessionId: 'session-s1', key: 'title', value: '旧标题', seq: 5);
    host.pushProjectionFrame(sessionId: 'session-s1', key: 'goal', value: '进行中', seq: 9);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // 尾页切面在 seq 7(事件 1、2 + 5 个后续事件…… fixture 事件到 seq 2,
    // 直接登记覆写:块只带 imageLimits,asOfSeq = 7 介于 5 与 9 之间)。
    host.sessions['session-s1'] = [
      eventOf(1, 'user/message'),
      eventOf(7, 'assistant/message'),
    ];
    await store.loadHistory('session-s1');

    final values = store.currentSummaries.first.projections?.values;
    expect(values?.containsKey('title'), isFalse,
        reason: '全量基线中缺席且 seq <= 切面 → 能力缺席,清除防幻影键');
    expect(values?['goal'], '进行中',
        reason: '更新的推送帧(seq > 切面)在清除中幸存');
  });

  test('createSession 在共享在飞拉取期间创建:upsert 重放保证新行可见', () async {
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));

    // 挂住在飞的 refresh(快照早于即将发生的 create)。
    host.listGate = Completer<void>();
    final refreshing = store.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // create 响应立即返回(fake 不推 host 帧);其 refresh 与在飞合并。
    final created = await store.createSession();
    host.listGate!.complete();
    await refreshing.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      store.currentSummaries.any((s) => s.sessionId == created.sessionId),
      isTrue,
      reason: '共享拉取快照早于创建时,靠 create 后的 upsert 重放补行',
    );
  });
}
