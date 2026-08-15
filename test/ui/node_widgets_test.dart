// ChatNodeList widget 测试:360dp 窄屏下 think 折叠展开、工具卡配对渲染、
// markdown 气泡渲染。直接构造节点列表(不碰 socket,绕开 HttpClient 假货坑)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/ui/node_widgets.dart';

/// 360dp 宽度的移动视口包装(硬性移动形态验收)。
Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 360, height: 640, child: child),
        ),
      ),
    );

void main() {
  testWidgets('think 块默认收起,点击整行展开/再点收起', (tester) async {
    final nodes = <ChatNode>[
      ChatNodeThink(seq: 1, type: 'assistant/reasoning', text: '这是被折叠的深度思考内容'),
    ];
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    // 默认收起:内容不可见,只看到标题行。
    expect(find.text('这是被折叠的深度思考内容'), findsNothing);
    expect(find.text('思考过程'), findsOneWidget);
    // 触控行 ≥44dp 硬性下限(量整卡高度而非文本本身)。
    final rowSize = tester.getSize(
        find.ancestor(of: find.text('思考过程'), matching: find.byType(Card)));
    expect(rowSize.height, greaterThanOrEqualTo(44));
    // 点击展开:全文可见。
    await tester.tap(find.text('思考过程'));
    await tester.pump();
    expect(find.text('这是被折叠的深度思考内容'), findsOneWidget);
    // 再点收起。
    await tester.tap(find.text('思考过程'));
    await tester.pump();
    expect(find.text('这是被折叠的深度思考内容'), findsNothing);
  });

  testWidgets('工具卡配对渲染:名称+状态徽标,展开显示输入/输出详情', (tester) async {
    final nodes = <ChatNode>[
      ChatNodeTool(
        seq: 2,
        type: 'tool/call',
        toolName: 'bash',
        callId: 'c1',
        input: {'cmd': 'ls -la'},
        output: {'exitCode': 0, 'stdout': 'file.txt'},
        status: ToolStatus.success,
        summary: 'ls -la',
        callSeq: 2,
        resultSeq: 3,
      ),
    ];
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    // 收起态:名称 + 摘要 + 状态徽标。
    expect(find.text('bash'), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('ls -la'), findsOneWidget);
    // 展开详情:输入/输出标签与内容出现。
    await tester.tap(find.text('bash'));
    await tester.pump();
    expect(find.text('输入'), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    expect(find.textContaining('ls -la'), findsWidgets);
    expect(find.textContaining('file.txt'), findsWidgets);
    // 全屏按钮常显(移动端无 hover)。
    expect(find.text('全屏查看'), findsOneWidget);
  });

  testWidgets('assistant markdown 气泡渲染加粗与行内代码', (tester) async {
    final nodes = <ChatNode>[
      ChatNodeAssistant(seq: 1, type: 'assistant/message', text: '**加粗结论** 与 `code` 片段'),
    ];
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    expect(find.textContaining('加粗结论'), findsOneWidget);
    expect(find.textContaining('code'), findsWidgets);
  });

  testWidgets('todo 计数卡 + 错误行 + 重试行渲染', (tester) async {
    final nodes = <ChatNode>[
      ChatNodeTodo(seq: 4, type: 'todo/write', items: const [
        TodoItem(title: '调研', done: true),
        TodoItem(title: '编码'),
        TodoItem(title: '测试'),
      ]),
      ChatNodeError(seq: 5, type: 'turn/error', message: '模型调用失败'),
      ChatNodeRetry(seq: 6, type: 'llm/retry', reason: '速率限制', attempt: 2),
    ];
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    expect(find.textContaining('计划 3 项'), findsOneWidget);
    expect(find.textContaining('完成 1 项'), findsOneWidget);
    expect(find.text('模型调用失败'), findsOneWidget);
    expect(find.textContaining('重试(第 2 次)'), findsOneWidget);
  });

  testWidgets('用户气泡右对齐 + 未知类型兜底折叠', (tester) async {
    final nodes = <ChatNode>[
      ChatNodeUser(seq: 1, type: 'user/message', text: '帮我写个脚本'),
      ChatNodeUnknown(seq: 2, type: 'mystery/thing', data: {'x': 1}),
    ];
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    expect(find.text('帮我写个脚本'), findsOneWidget);
    // 用户气泡右对齐(对齐值 > 0.5)。
    final center = tester.getCenter(find.text('帮我写个脚本'));
    expect(center.dx, greaterThan(180));
    // 未知兜底:折叠显示类型名,展开显示原始 data。
    expect(find.text('未知事件: mystery/thing'), findsOneWidget);
    await tester.tap(find.text('未知事件: mystery/thing'));
    await tester.pump();
    expect(find.textContaining('"x"'), findsOneWidget);
  });
}
