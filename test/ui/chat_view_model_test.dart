// ChatViewModel + ChatScreen 测试:假 SessionStoreView 手动喂流,
// 不碰 socket(绕开 flutter_test 的 HttpClient 假货坑)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/event_nodes.dart';
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

  /// >0 时接下来 N 次装载抛错(测错误呈现与手动重试)。
  int historyFailures = 0;
  @override
  Future<void> loadHistory(String sessionId) async {
    historyLoads += 1;
    if (historyFailures > 0) {
      historyFailures -= 1;
      throw 'ApiTimeout(session.history after 30000ms)';
    }
  }

  @override
  Future<void> loadOlder(String sessionId) async {}

  @override
  Future<String> fork(String sessionId, {int? atSeq}) async => 'forked';


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
    view.logFor('s1');
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

  test('历史加载失败落 lastError;retryHistory 清错重载,成功后横幅可退场', () async {
    final view = _FakeView();
    view.current = [_summary('s1')];
    view.logFor('s1');
    final vm = ChatViewModel(store: view, connection: null);
    view.emit();
    await Future<void>.delayed(Duration.zero);

    view.historyFailures = 1;
    vm.select('s2');
    await Future<void>.delayed(Duration.zero);
    expect(vm.lastError, isNotNull);
    expect(vm.lastError, contains('历史消息加载失败'));
    expect(view.historyLoads, 2);

    // 手动重试:错误先清,装载成功后 lastError 保持为 null(横幅退场)。
    await vm.retryHistory();
    expect(view.historyLoads, 3);
    expect(vm.lastError, isNull);

    // 切换会话也清旧错。
    view.historyFailures = 1;
    vm.select('s1');
    await Future<void>.delayed(Duration.zero);
    expect(vm.lastError, isNotNull);
    vm.select('s2');
    await Future<void>.delayed(Duration.zero);
    expect(vm.lastError, isNull);
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

  SessionEvent _chunkEvent(int seq, String text) => SessionEvent(
        type: 'assistant/chunk',
        seq: seq,
        time: (1786723600000 + seq).toDouble(),
        data: <String, dynamic>{
          'turn': 1,
          'step': 1,
          'chunk': <String, dynamic>{
            'type': 'text-delta',
            'index': 0,
            'text': text,
          },
        },
      );

  test('流式重算节流分档:纯 chunk 慢档(250ms)合并;结构事件立即落地', () async {
    final view = _FakeView();
    view.current = [_summary('s1')];
    final log = view.logFor('s1');
    final vm = ChatViewModel(store: view, connection: null);
    view.emit();
    await Future<void>.delayed(Duration.zero);

    var notifications = 0;
    vm.addListener(() => notifications++);

    // 突发 20 个纯 chunk delta(同一轮):microtask 合并 + leading 立即。
    for (var i = 0; i < 20; i++) {
      log.append(_chunkEvent(100 + i, 'd$i '));
    }
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 1);
    expect(vm.nodes.whereType<ChatNodeAssistant>().single.text, contains('d19'));

    // 慢档窗口(250ms)内的后续 chunk:不重算,合并到尾沿。
    for (var i = 20; i < 40; i++) {
      log.append(_chunkEvent(100 + i, 'd$i '));
    }
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(notifications, 1); // 尾沿(250ms)未到,仍是旧状态
    // 过窗后尾沿落地:最终帧可见(纯流式下 UI 每窗至多一次全量重算)。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(notifications, 2);
    expect(vm.nodes.whereType<ChatNodeAssistant>().single.text, contains('d39'));

    // 结构事件(非 chunk,如 user/message)不受慢档拖延:立即落地。
    log.append(_msgEvent(500, 'user', '结构变化'));
    await Future<void>.delayed(Duration.zero);
    expect(notifications, 3);
    expect(vm.bubbles.last.text, '结构变化');
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
    // ready 态徽标改显「已连接」(「gen N」对用户表意不明,已重构;
    // 代际诊断信息收进徽标 tooltip)。
    expect(find.text('已连接'), findsOneWidget);
    vm.dispose();
  });
}
