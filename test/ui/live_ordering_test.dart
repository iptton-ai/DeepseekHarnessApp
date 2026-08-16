// 活体复现(flutter test 版):真宿主 3080 + 真 ChatViewModel。
// 复现用户报告:「用户主动发的消息永远显示在最低(视觉上最后一条)」。
// 场景 A:静止会话直接发送。场景 B:运行中排队发送(web 对齐后恒 queue)。
// 宿主不可达时 skip(活体靶机不在就别红)。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/ui/chat_view_model.dart';

const base = 'http://127.0.0.1:3080';

String _render(List<ChatNode> nodes) => nodes
    .map((n) => switch (n) {
          ChatNodeUser() => 'U${n.seq<0?'(eph)':'(${n.seq})'}',
          ChatNodeAssistant() => 'A(${n.seq}${n.streaming?'~':''})',
          ChatNodeThink() => 'T(${n.seq})',
          ChatNodeTool() => 'D(${n.seq})',
          _ => '?(${n.seq})',
        })
    .join(' ');

void main() {
  test('live: 发送→回复→运行中再发→两轮完成,节点序', () async {
    final uri = Uri.parse(base);
    final api = ApiClient(baseUri: uri);
    final connection = ConnectionController(
      baseUri: uri,
      initialBackoff: const Duration(milliseconds: 300),
      maxBackoff: const Duration(seconds: 3),
    );
    final store = SessionStore(api: api, connection: connection);
    connection.start();
    store.start();
    addTearDown(() async {
      await store.dispose();
      await connection.dispose();
      api.dispose();
    });

    try {
      await connection.snapshots
          .firstWhere((s) => s.phase == ConnectionPhase.ready)
          .timeout(const Duration(seconds: 5));
    } on TimeoutException {
      markTestSkipped('活体靶机 3080 不可达');
      return;
    }
    final created = await store.createSession();
    final sid = created.sessionId;
    print('SESSION ' + sid);

    final vm = ChatViewModel(store: store, connection: null);
    addTearDown(vm.dispose);
    vm.select(sid);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // 场景 A:静止会话直接发送。
    final sent1 = await store.promptText(sid, '请只回复四个字:第一轮完成', clientTimeZone: 'UTC');
    expect(sent1.accepted, isTrue);
    // 等 user/message + assistant/message 都到。
    var t0 = DateTime.now();
    while (DateTime.now().difference(t0) < const Duration(seconds: 90)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final running = store.currentSummaries
          .where((s) => s.sessionId == sid)
          .isNotEmpty;
      final done = !running ||
          store.currentSummaries
              .firstWhere((s) => s.sessionId == sid)
              .running == false;
      if (done && vm.nodes.whereType<ChatNodeAssistant>().isNotEmpty) break;
    }
    print('A 轮终态: ' + _render(vm.nodes));

    // 场景 B:新开一轮,运行中排队发第二条(恒 queue,对齐 web)。
    await store.promptText(sid, '请从 1 慢数到 15,每个数单独一行,不要做别的', clientTimeZone: 'UTC');
    await Future<void>.delayed(const Duration(seconds: 4)); // 等它跑起来
    final runningNow = store.currentSummaries
        .firstWhere((s) => s.sessionId == sid)
        .running;
    print('B 轮运行中 running=' + runningNow.toString());
    unawaited(vm.send('数完后请回复四个字:第二轮完成', (id, text) {
      return store.promptText(id, text, clientTimeZone: 'UTC');
    }));
    // 观察:发送后 2s(占位期)、turn 结束后。
    await Future<void>.delayed(const Duration(seconds: 2));
    print('B 轮发送后 2s: ' + _render(vm.nodes));
    t0 = DateTime.now();
    while (DateTime.now().difference(t0) < const Duration(seconds: 150)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final s = store.currentSummaries.where((s) => s.sessionId == sid).toList();
      if (s.isNotEmpty && !s.first.running) break;
    }
    // 再等尾沿节流落地。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    print('B 轮终态: ' + _render(vm.nodes));

    // 断言核心不变式:终态不存在 ephemeral 占位;每个 user 节点 seq 都
    // 小于其后紧邻的 assistant 定稿节点 seq(消息在它的回答上方)。
    final eph = vm.nodes.where((n) => n.seq < 0).toList();
    expect(eph, isEmpty, reason: '终态不应残留乐观占位;残留在视觉上永远是最后一条');
    final users = vm.nodes.whereType<ChatNodeUser>().toList();
    for (final u in users) {
      final later = vm.nodes.where((n) => n.seq > u.seq).toList();
      print('user seq=${u.seq} 之后还有 ${later.length} 个节点');
    }
    expect(users.length, greaterThanOrEqualTo(3));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
