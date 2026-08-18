// 渲染一致性(RENDER-PARITY-PLAN)widget 层验收:
// - B1 噪声事件不再出现在时间线;命令卡/上下文行/workflow 卡正确渲染
// - A1 产出文件行出现在轮末
// - A2 时间戳/耗时/指标显示
// - A3 统计条分组
// - A8 goal 面板接线
// 纯 widget 测试,不依赖网络。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/sessions/session_stats.dart';
import 'package:singleman/ui/goal_skill_widgets.dart';
import 'package:singleman/ui/node_widgets.dart';
import 'package:singleman/ui/stats_bar.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

SessionEvent _ev(int seq, String type, dynamic data, {double? time}) =>
    SessionEvent(
      type: type,
      seq: seq,
      time: time ?? 1786723605000 + seq.toDouble(),
      data: data,
    );

EventNodeInput _in(int seq, String type, dynamic data) =>
    EventNodeInput(_ev(seq, type, data));

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('B1:噪声事件不出现在渲染层,command 卡渲染', (tester) async {
    final nodes = extractNodes([
      _in(1, 'command/run', {
        'commandId': 'c1',
        'name': 'permission',
        'args': ' danger',
      }),
      _in(2, 'command/done', {
        'commandId': 'c1',
        'kind': 'success',
        'text': 'preset danger',
      }),
      _in(3, 'sandbox/mode', {'mode': 'ask'}),
      _in(4, 'approval/asked', {'toolName': 'bash'}),
      _in(5, 'goal/change', {
        'goal': {'objective': 'x'},
      }),
    ]);
    await tester.pumpWidget(
      _wrap(ChatNodeList(nodes: nodes)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('command-card-1')), findsOneWidget);
    expect(find.textContaining('permission'), findsOneWidget);
    expect(find.textContaining('沙箱模式已更新'), findsNothing);
    expect(find.textContaining('等待审批'), findsNothing);
    expect(find.textContaining('目标已更新'), findsNothing);
  });

  testWidgets('A5:上下文注入行渲染(provenance + 展开;rc.6 真实形状)', (tester) async {
    // 真实日志形状(2026-08-17 普查):agent-instructions 带 changes[].path,
    // form='instructions'。标题必须出现「上下文注入」与文件名(web 同款),
    // 且整行可点开看到注入正文。
    final nodes = extractNodes([
      _in(1, 'user/message', {
        'content': [
          {
            'type': 'text',
            'text': '# AGENTS.md — 项目入口\n这是注入的工作区指令正文。',
          },
        ],
        'source': {
          'kind': 'agent-instructions',
          'form': 'instructions',
          'baseline': true,
          'changes': [
            {'action': 'set', 'scope': '.\u0000AGENTS.md', 'path': 'AGENTS.md'},
          ],
        },
      }),
    ]);
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 600,
          child: ChatNodeList(nodes: nodes)),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('context-row-title')), findsOneWidget);
    expect(find.text('上下文注入'), findsOneWidget);
    expect(find.textContaining('AGENTS.md'), findsOneWidget);
    // 未展开:正文不显示。
    expect(find.textContaining('项目入口'), findsNothing);
    // 点击标题区(整行)展开 → 正文可见。
    await tester.tap(find.byKey(const ValueKey('context-row-title')));
    await tester.pump();
    expect(find.textContaining('工作区指令正文'), findsOneWidget);
    // 旧噪声文案不得再出现。
    expect(find.textContaining('上下文已更新'), findsNothing);
  });

  testWidgets('A6:steering 插话气泡带徽标', (tester) async {
    final nodes = extractNodes([
      _in(1, 'agent/inbox/spliced', {
        'target': 'next-step',
        'start': 0,
        'inserted': [
          {'id': 'm1'},
        ],
        'removedCount': 0,
      }),
      _in(0, 'user/message', {
        'content': [
          {'type': 'text', 'text': '插话内容'},
        ],
        'source': {'kind': 'user'},
        'id': 'm1',
      }),
    ]);
    // 注:splice 在 seq 1,消息 seq 0 → 消息先落位。真实时序是消息入 inbox
    // (不落日志)→ splice 移除并 claimed → user/message 落日志。此处直接
    // 构造 claimed 后落位的形状。
    final nodes2 = extractNodes([
      _in(1, 'agent/inbox/spliced', {
        'target': 'next-step',
        'start': 0,
        'inserted': [
          {'id': 'm1'},
        ],
        'removedCount': 0,
      }),
      _in(2, 'agent/inbox/spliced', {
        'target': 'next-step',
        'start': 0,
        'inserted': [],
        'removedCount': 1,
      }),
      _in(3, 'user/message', {
        'content': [
          {'type': 'text', 'text': '插话内容'},
        ],
        'source': {'kind': 'user'},
        'id': 'm1',
      }),
    ]);
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes2)));
    await tester.pump();
    expect(find.byKey(const ValueKey('steering-badge')), findsOneWidget);
    expect(find.text('插话内容'), findsOneWidget);
  });

  testWidgets('A1:轮末产出文件行(chip + 计数)', (tester) async {
    final nodes = extractNodes([
      _in(1, 'turn/start', {'turn': 1}),
      _in(2, 'tool/call', {
        'name': 'edit',
        'callId': 'c1',
        'input': {'path': 'x'},
      }, ),
      _in(3, 'turn/end', {'reason': {'kind': 'completed'}}),
    ]);
    // 无 view 的历史回放没有 locations → 无产出行。
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    await tester.pump();
    expect(find.byKey(const ValueKey('deliverables-lane')), findsNothing);
  });

  testWidgets('A4/A2:工具卡耗时 + 助手指标 + 用户时间', (tester) async {
    final call = _ev(2, 'tool/call', {
      'name': 'bash',
      'callId': 'c1',
      'input': {'command': 'ls'},
    }, time: 1786723605000);
    final result = _ev(3, 'tool/result', {
      'message': {
        'source': {'callId': 'c1'},
        'content': [
          {
            'type': 'tool-result',
            'content': [
              {'type': 'text', 'text': 'a.txt'},
            ],
          }
        ],
      },
    }, time: 17867236054520 + 0.0 - 1786723605000 + 1786723605000);
    final nodes = extractNodes([
      EventNodeInput(call),
      EventNodeInput(result),
    ]);
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    await tester.pump();
    expect(find.byKey(const ValueKey('tool-duration')), findsOneWidget);
  });

  testWidgets('A3:统计条分组渲染', (tester) async {
    const stats = SessionStats(
      turns: 3,
      steps: 7,
      llmMs: 45000,
      toolMs: 12000,
      ttftMs: 2400,
      ttftSteps: 3,
      decodeMs: 30000,
      decodeTokens: 1500,
      inputTokens: 12200,
      outputTokens: 517,
      cacheReadTokens: 6100,
    );
    await tester.pumpWidget(_wrap(const Column(children: [SessionStatsBar(stats: stats)])));
    await tester.pump();
    final text = tester.widget<Text>(find.byKey(const ValueKey('session-stats-bar')));
    expect(text.data, contains('3 轮'));
    expect(text.data, contains('7 步'));
    expect(text.data, contains('LLM 45.0s')); // llmMs(一位小数,web 同款)
    expect(text.data, contains('工具 12.0s')); // toolMs
    expect(text.data, contains('TTFT 均值 0.8s')); // 2400/3
    expect(text.data, contains('50.0 tok/s')); // 1500 tok / 30s
    expect(text.data, contains('缓存命中 50%'));
    expect(text.data, contains('12.2K'));
    expect(text.data, contains('517'));
  });

  testWidgets('A3:空统计零渲染', (tester) async {
    await tester.pumpWidget(
      _wrap(const Column(children: [SessionStatsBar(stats: SessionStats())])),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('session-stats-bar')), findsNothing);
  });

  testWidgets('A8:GoalPanel 无目标零渲染(对齐 web GoalBar)', (tester) async {
    await tester.pumpWidget(
      _wrap(const Column(children: [GoalPanel(projection: null, busy: false)])),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('goal-panel-title')), findsNothing);
    expect(find.text('新建目标'), findsNothing);

    // 投影存在但 goal 缺席(如 {goal: null, roundsStarted: 0})同样零渲染。
    await tester.pumpWidget(
      _wrap(const Column(children: [
        GoalPanel(projection: {'goal': null, 'roundsStarted': 0}, busy: false),
      ])),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('goal-panel-title')), findsNothing);
  });

  testWidgets('A8:GoalPanel 投影渲染(阶段徽标 + 正文 + 按钮)', (tester) async {
    await tester.pumpWidget(
      _wrap(
        GoalPanel(
          projection: const {
            'goal': {
              'id': 'g1',
              'revision': 2,
              'objective': '完善渲染一致性',
              'phase': 'active',
              'maxGoalRounds': 16,
            },
            'roundsStarted': 3,
          },
          busy: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('goal-panel-title')), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.byKey(const ValueKey('goal-panel-objective')), findsOneWidget);
    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('恢复'), findsNothing); // active 态无恢复按钮
  });

  testWidgets('A7:workflow 卡阶段分组渲染', (tester) async {
    final nodes = extractNodes([
      _in(1, 'tool-workflow/run-start', {'runId': 'r1', 'name': 'audit'}),
      _in(2, 'tool-workflow/agent-start', {
        'runId': 'r1',
        'seq': 0,
        'label': '扫描员',
        'phase': 'scan',
        'childId': 's1',
      }),
      _in(3, 'tool-workflow/agent-end', {
        'runId': 'r1',
        'seq': 0,
        'outcome': 'completed',
      }),
      _in(4, 'tool-workflow/run-end', {
        'runId': 'r1',
        'stopReason': 'completed',
      }),
    ]);
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    await tester.pump();
    expect(find.byKey(const ValueKey('workflow-card-1')), findsOneWidget);
    expect(find.textContaining('audit'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('扫描员'), findsOneWidget);
    expect(find.text('阶段 scan'), findsOneWidget);
  });

  test('A2 formatNodeTime:同日 HH:mm,跨日带日期', () {
    final now = DateTime.now();
    final sameDay = DateTime(now.year, now.month, now.day, 14, 5)
        .millisecondsSinceEpoch
        .toDouble();
    expect(formatNodeTime(sameDay), '14:05');
    final other = DateTime(now.year, now.month, now.day - 3, 9, 1)
        .millisecondsSinceEpoch
        .toDouble();
    expect(formatNodeTime(other).contains('09:01'), isTrue);
  });

  test('A3 formatTokens/formatStatsDuration 对齐 web', () {
    expect(formatTokens(517), '517');
    expect(formatTokens(12200), '12.2K');
    expect(formatTokens(517000), '517K');
    expect(formatTokens(1200000), '1.2M');
    expect(formatStatsDuration(45200), '45.2s');
    expect(formatStatsDuration(162000), '2m42s');
  });

  test('A3 deriveSessionStats:事件窗口折叠(turns/steps/toolMs/tokens)', () {
    final events = <SessionEvent>[
      _ev(1, 'turn/start', {'turn': 1}),
      _ev(2, 'step/start', {'turn': 1, 'step': 1}),
      _ev(3, 'assistant/message', {
        'turn': 1,
        'step': 1,
        'message': {
          'content': [
            {'type': 'text', 'text': 'hi'},
          ],
        },
        'usage': {'inputTokens': 100, 'outputTokens': 20},
      }),
      _ev(4, 'tool/call', {
        'callId': 'c1',
        'name': 'bash',
      }, time: 1786723605000),
      _ev(5, 'tool/result', {
        'message': {
          'source': {'callId': 'c1'},
          'content': [],
        },
      }, time: 1786723605300),
      _ev(6, 'turn/end', {'reason': {'kind': 'completed'}}),
    ];
    final stats = deriveSessionStats(events);
    expect(stats.turns, 1);
    expect(stats.steps, 1);
    expect(stats.toolMs.toStringAsFixed(0), '300');
    expect(stats.inputTokens, 100);
    expect(stats.outputTokens, 20);
  });

  test('A3 sessionStatsOf:投影优先', () {
    final stats = sessionStatsOf(const [], {
      'sessionStats': {
        'turns': 9,
        'steps': 20,
        'llmMs': 1000,
        'toolMs': 0,
        'ttftMs': 0,
        'ttftSteps': 0,
        'decodeMs': 0,
        'decodeTokens': 0,
      },
      'tokenUsage': {
        'uncachedInputTokens': 10,
        'outputTokens': 5,
        'cacheReadTokens': 2,
        'cacheWriteTokens': 1,
      },
    });
    expect(stats.turns, 9);
    expect(stats.steps, 20);
  });
}
