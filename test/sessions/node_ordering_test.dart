// 临时复现:用户报告「用户主动发的消息永远显示在最低(视觉上最后一条)」。
// 用真实日志形状(b01f449c 普查)构造多轮 + 流式 + 排队消息,增量喂给
// extractNodes,打印每步节点序,定位排序回归。
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

SessionEvent _ev(int seq, String type, dynamic data) => SessionEvent(
      type: type,
      seq: seq,
      time: 1786723605000 + seq.toDouble(),
      data: data,
    );

EventNodeInput _in(SessionEvent e) => EventNodeInput(e);

dynamic _chunk(int seq, int turn, int step, String t, [String? text]) => _ev(
      seq,
      'assistant/chunk',
      {
        'turn': turn,
        'step': step,
        'chunk': {
          'type': t,
          if (t == 'block-start') 'blockType': 'text',
          if (t == 'block-start') 'index': 0,
          if (text != null) 'text': text,
          if (t == 'text-delta') 'index': 0,
        },
      },
    );

void _dump(String tag, List<ChatNode> nodes) {
  print('--- ' + tag);
  for (final n in nodes) {
    final label = switch (n) {
      ChatNodeUser() => 'USER',
      ChatNodeAssistant() => 'ASSIST',
      ChatNodeThink() => 'THINK',
      ChatNodeTool() => 'TOOL',
      ChatNodeError() => 'ERROR',
      ChatNodeNotice() => 'NOTICE',
      _ => 'OTHER',
    };
    final extra = n is ChatNodeAssistant
        ? '(streaming=${n.streaming})'
        : n is ChatNodeThink
        ? '(streaming=${n.streaming})'
        : '';
    print('seq=${n.seq} ${label} ${extra}');
  }
}

void main() {
  test('repro: queue 流程节点排序', () {
    final events = <SessionEvent>[
      // turn 1: 用户首条消息 + 流式回答(step1)
      _ev(4, 'turn/start', {'turn': 1}),
      _ev(6, 'step/start', {'turn': 1, 'step': 1}),
      _ev(7, 'user/message', {
        'content': [
          {'type': 'text', 'text': '第一轮提问'},
        ],
        'source': {'kind': 'user'},
      }),
      _chunk(8, 1, 1, 'block-start'),
      _chunk(9, 1, 1, 'text-delta', '正在思考'),
      _chunk(10, 1, 1, 'block-end'),
      _ev(11, 'assistant/message', {
        'turn': 1,
        'step': 1,
        'message': {
          'content': [
            {'type': 'text', 'text': '第一轮回答'},
          ],
        },
      }),
      _ev(12, 'step/end', {'turn': 1, 'step': 1}),
      // 用户排队发第二条(在 turn1 step2 流式中发出;user/message 事件在
      // turn1 结束、turn2 开启时才落地 —— 真实 queue 形状)
      _ev(13, 'step/start', {'turn': 1, 'step': 2}),
      _chunk(14, 1, 2, 'block-start'),
      _chunk(15, 1, 2, 'text-delta', '第二轮流式内容'),
      _ev(16, 'step/end', {'turn': 1, 'step': 2}),
      _ev(17, 'turn/end', {'turn': 1, 'reason': {'kind': 'completed'}}),
      _ev(18, 'agent/inbox/spliced', {'target': 'next-turn'}),
      _ev(19, 'turn/start', {'turn': 2}),
      _ev(20, 'step/start', {'turn': 2, 'step': 1}),
      _ev(21, 'user/message', {
        'content': [
          {'type': 'text', 'text': '排队消息'},
        ],
        'source': {'kind': 'user'},
      }),
      _chunk(22, 2, 1, 'block-start'),
      _chunk(23, 2, 1, 'text-delta', '第二轮回答'),
    ];

    // 增量喂:模拟事件逐帧到达,每步全量重算(与 _rebuildFromLog 相同)。
    for (var i = 0; i < events.length; i++) {
      final nodes = extractNodes([for (final e in events.sublist(0, i + 1)) _in(e)]);
      if (i == 5 || i == 11 || i == 15 || i == 20 || i == 22) {
        _dump('after seq ${events[i].seq} (${events[i].type})', nodes);
      }
    }
  });
}
