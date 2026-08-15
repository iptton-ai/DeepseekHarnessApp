// ChatViewModel + ChatScreen 测试:假 SessionStoreView 手动喂流,
// 不碰 socket(绕开 flutter_test 的 HttpClient 假货坑)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/event_text.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class _FakeView implements SessionStoreView {
  final summariesController = StreamController<List<SessionSummary>>.broadcast();
  final logs = <String, SessionLog>{};
  List<SessionSummary> current = <SessionSummary>[];

  @override
  Stream<List<SessionSummary>> get summaries => summariesController.stream;

  @override
  List<SessionSummary> get currentSummaries => current;

  @override
  SessionLog logFor(String sessionId) =>
      logs.putIfAbsent(sessionId, () => SessionLog(sessionId));

  int historyLoads = 0;
  @override
  Future<void> loadHistory(String sessionId) async {
    historyLoads += 1;
  }

  @override
  Future<void> loadOlder(String sessionId) async {}

  void emit() {
    current = List.of(current);
    summariesController.add(current);
  }
}

SessionSummary _summary(String id, {bool running = false}) => SessionSummary(
      sessionId: id,
      updatedAt: 1786723600000,
      running: running,
      blank: false,
    );

SessionEvent _msgEvent(int seq, String role, String text) => SessionEvent(
      type: role + '/message',
      seq: seq,
      time: (1786723600000 + seq).toDouble(),
      data: <String, dynamic>{
        'id': 'm-' + seq.toString(),
        'role': role,
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': text},
        ],
        'source': <String, dynamic>{'kind': role == 'user' ? 'user' : 'model'},
      },
    );

void main() {
  test('select() triggers loadHistory and renders after events arrive', () async {
    final view = _FakeView();
    view.current = [_summary('s1')];
    final log = view.logFor('s1');
    final vm = ChatViewModel(store: view, connection: null);
    view.emit();
    await Future<void>.delayed(Duration.zero);
    expect(view.historyLoads, 1); // 自动选中首会话即触发
    vm.select('s2');
    expect(view.historyLoads, 2); // 手动切换再触发
    // 历史返回(模拟 loadHistory 后事件入 s2 的日志;选中项是 s2)→ 气泡出现。
    final log2 = view.logFor('s2');
    log2.append(_msgEvent(1, 'user', '历史消息'));
    await Future<void>.delayed(Duration.zero);
    expect(vm.bubbles.map((b) => b.text), contains('历史消息'));
    vm.dispose();
  });

  test('乐观占位气泡同步进入节点流(即发即见);真帧回流后被撤', () async {
    final view = _FakeView();
    view.current = [_summary('s1')];
    view.logFor('s1');
    final vm = ChatViewModel(store: view, connection: null);
    view.emit();
    await Future<void>.delayed(Duration.zero);

    // 发送中:ephemeral 以负数 seq 的 ChatNodeUser 追加在节点流尾部。
    var sent = <String>[];
    await vm.send('hello', (id, text) async {
      sent.add(text);
      // 真帧在发送 future 完成前尚未回流;此刻节点流应含乐观占位。
      expect(
        vm.nodes.whereType<ChatNodeUser>().map((n) => n.text),
        contains('hello'),
      );
    });
    await Future<void>.delayed(Duration.zero);
    final log = view.logFor('s1');
    log.append(_msgEvent(1, 'user', 'hello'));
    await Future<void>.delayed(Duration.zero);
    // 真帧到达 → 占位被撤,只剩真实节点(seq=1)。
    final users = vm.nodes.whereType<ChatNodeUser>().toList();
    expect(users, hasLength(1));
    expect(users.single.seq, 1);
    vm.dispose();
  });

  test('extractText pulls text blocks, skips images', () {
    expect(
      extractText(<String, dynamic>{
        'content': [
          {'type': 'text', 'text': 'a'},
          {'type': 'image', 'mediaType': 'image/png', 'data': 'x'},
          {'type': 'text', 'text': 'b'},
        ],
      }),
      'a\nb',
    );
    expect(extractText(<String, dynamic>{}), '');
    expect(extractText(null), '');
  });

  test('VM folds log events into user/assistant bubbles, skips injected context', () async {
    final view = _FakeView();
    view.current = [_summary('s1')];
    view.logFor('s1');
    final vm = ChatViewModel(store: view, connection: null);
    view.emit();
    await Future<void>.delayed(Duration.zero);
    expect(vm.sessions, hasLength(1));
    expect(vm.selectedId, 's1');

    final log = view.logFor('s1');
    log.append(_msgEvent(1, 'user', 'hello'));
    log.append(_msgEvent(2, 'assistant', 'hi there'));
    // 合成上下文(source.kind != user)不冒泡。
    log.append(SessionEvent(
      type: 'user/message',
      seq: 3,
      time: 1.0,
      data: <String, dynamic>{
        'content': [
          {'type': 'text', 'text': 'injected'},
        ],
        'source': <String, dynamic>{'kind': 'plugin'},
      },
    ));
    await Future<void>.delayed(Duration.zero);
    expect(vm.bubbles, hasLength(2));
    expect(vm.bubbles[0].role, 'user');
    expect(vm.bubbles[0].text, 'hello');
    expect(vm.bubbles[1].text, 'hi there');
    vm.dispose();
  });

  testWidgets('ChatScreen renders bubbles and phase badge', (tester) async {
    // testWidgets 的 body 跑在 fake-async zone:Future.delayed 在第一次 pump
    // 前永不落地 —— 一律用 tester.pump() 当微任务冲刷原语。
    final view = _FakeView();
    view.current = [_summary('s1')];
    final log = view.logFor('s1');
    final vm = ChatViewModel(store: view, connection: null);
    view.emit();
    await tester.pump();
    log.append(_msgEvent(1, 'user', 'hello'));
    log.append(_msgEvent(2, 'assistant', 'hi'));
    await tester.pump();
    vm.phase = ConnectionPhase.ready;
    vm.generation = 3;

    await tester.pumpWidget(MaterialApp(
      home: ChatSenderBinding(
        sender: (id, text) async {},
        child: ChatScreen(vm: vm),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('hi'), findsOneWidget);
    expect(find.text('gen 3'), findsOneWidget);
    vm.dispose();
  });
}
