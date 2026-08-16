// 临时复现 #2:VM 层完整时序 —— 流式中排队发送、真帧晚到、慢档节流。
// 用 testWidgets + pump 控制 250ms 节流窗口。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/sessions/session_store.dart';
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
  @override
  Future<void> loadHistory(String sessionId) async {}
  @override
  Future<void> loadOlder(String sessionId) async {}
  @override
  Future<String> fork(String sessionId, {int? atSeq}) async => 'f';

  void emit() {
    current = List.of(current);
    summariesController.add(current);
  }
}

SessionSummary _summary(String id) => SessionSummary(
    sessionId: id, updatedAt: 1, running: true, blank: false);

SessionEvent _ev(int seq, String type, dynamic data) => SessionEvent(
    type: type, seq: seq, time: (1786723600000 + seq).toDouble(), data: data);

dynamic _userMsg(int seq, String text) => _ev(seq, 'user/message', {
      'content': [
        {'type': 'text', 'text': text},
      ],
      'source': {'kind': 'user', 'rpcId': 'r-$seq'},
      'role': 'user',
      'id': 'm-$seq',
    });

dynamic _chunk(int seq, int turn, int step, String t) => _ev(
      seq,
      'assistant/chunk',
      {
        'turn': turn,
        'step': step,
        'chunk': {'type': t, if (t == 'block-start') 'blockType': 'text', 'index': 0},
      },
    );

String _render(List<ChatNode> nodes) => nodes
    .map((n) => switch (n) {
          ChatNodeUser() => 'U(${n.seq}${n.seq < 0 ? ':eph' : ''})',
          ChatNodeAssistant() => 'A(${n.seq}${n.streaming ? '~' : ''})',
          _ => '?(${n.seq})',
        })
    .join(' ');

void main() {
  testWidgets('流式中排队发送 → 真帧到达 → 顺序与占位撤销', (tester) async {
    final view = _FakeView();
    view.current = [_summary('s1')];
    final log = view.logFor('s1');
    final vm = ChatViewModel(store: view, connection: null);
    view.emit();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 历史:turn1 已完成(旧 user + 旧 assistant)。
    log.appendAll([
      _ev(4, 'turn/start', {'turn': 1}),
      _userMsg(7, '第一轮提问'),
      _ev(11, 'assistant/message', {
        'turn': 1,
        'step': 1,
        'message': {
          'content': [
            {'type': 'text', 'text': '第一轮回答'},
          ],
        },
      }),
      _ev(12, 'turn/end', {'turn': 1, 'reason': {'kind': 'completed'}}),
    ]);
    await tester.pump();
    print('历史装载后: ' + _render(vm.nodes));

    // turn2 开流(chunk 逐帧到,走慢档)。
    log.append(_ev(13, 'turn/start', {'turn': 2}));
    log.append(_ev(14, 'step/start', {'turn': 2, 'step': 1}));
    log.append(_chunk(15, 2, 1, 'block-start'));
    log.append(_ev(16, 'assistant/chunk', {
      'turn': 2,
      'step': 1,
      'chunk': {'type': 'text-delta', 'text': '流式回答', 'index': 0},
    }));
    await tester.pump(); // microtask 落地
    print('流式中(快照): ' + _render(vm.nodes));

    // 用户此刻排队发送新消息 → 乐观占位。
    var sendDone = false;
    unawaited(vm.send('排队消息', (id, text) async {
      sendDone = true;
    }));
    await tester.pump();
    print('发送后(占位): ' + _render(vm.nodes) + '  sendDone=' + sendDone.toString());

    // 更多 chunk 流入(仍慢档)。
    log.append(_ev(17, 'assistant/chunk', {
      'turn': 2,
      'step': 1,
      'chunk': {'type': 'text-delta', 'text': '继续', 'index': 0},
    }));
    await tester.pump(const Duration(milliseconds: 100));
    print('chunk 续流: ' + _render(vm.nodes));

    // turn2 结束 → 排队消息落地 turn3(user/message)。
    log.append(_ev(18, 'assistant/message', {
      'turn': 2,
      'step': 1,
      'message': {
        'content': [
          {'type': 'text', 'text': '第二轮回答定稿'},
        ],
      },
    }));
    log.append(_ev(19, 'step/end', {'turn': 2, 'step': 1}));
    log.append(_ev(20, 'turn/end', {'turn': 2, 'reason': {'kind': 'completed'}}));
    log.append(_ev(21, 'turn/start', {'turn': 3}));
    log.append(_ev(22, 'step/start', {'turn': 3, 'step': 1}));
    log.append(_userMsg(23, '排队消息'));
    await tester.pump();
    print('真帧到达即刻: ' + _render(vm.nodes));
    await tester.pump(const Duration(seconds: 1));
    print('节流窗口排空后: ' + _render(vm.nodes));

    // turn3 回答开流。
    log.append(_ev(24, 'step/start', {'turn': 3, 'step': 1}));
    log.append(_chunk(25, 3, 1, 'block-start'));
    log.append(_ev(26, 'assistant/chunk', {
      'turn': 3,
      'step': 1,
      'chunk': {'type': 'text-delta', 'text': '第三轮回答', 'index': 0},
    }));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    print('turn3 流式: ' + _render(vm.nodes));

    vm.dispose();
    await tester.pump();
  });
}
