// ChatNodeList widget 测试:360dp 窄屏下 think 折叠展开、工具卡配对渲染、
// markdown 气泡渲染。直接构造节点列表(不碰 socket,绕开 HttpClient 假货坑)。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    // 触控行 ≥44dp 硬性下限(量可点击行高度而非文本本身)。
    final rowSize = tester.getSize(
        find.ancestor(of: find.text('思考过程'), matching: find.byType(InkWell)));
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

  testWidgets('think 直播标题:先打字,满行后窗口锚定行尾向左滑(最右字符永远是最新字符)', (tester) async {
    const style = TextStyle(fontWeight: FontWeight.w600, fontSize: 13);
    Widget build(String text) => _wrap(ChatNodeList(nodes: <ChatNode>[
          ChatNodeThink(
            seq: 1,
            type: 'assistant/chunk/reasoning',
            text: text,
            streaming: true,
          ),
        ]));

    double measure(String s) {
      final p = TextPainter(
        text: TextSpan(text: s, style: style),
        textScaler: TextScaler.noScaling,
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    double dxOf(String snippet) {
      // 从滚动文本向上找它的 Transform(树里还有无关的 Material Transform)。
      final t = tester.widget<Transform>(
        find
            .ancestor(
              of: find.textContaining(snippet),
              matching: find.byType(Transform),
            )
            .first,
      );
      return t.transform.getTranslation().x;
    }

    // ① 未超宽:静止(流式追加即打字效果),无位移。
    await tester.pumpWidget(build('短思考行'));
    await tester.pumpAndSettle();
    expect(dxOf('短思考行'), 0);

    // ② 超宽:滑到位后 dx = -(文本宽-视口宽) —— 窗口锚定行尾。
    final long = '短思考行' + '持续输出的超长思考行' * 12;
    await tester.pumpWidget(build(long));
    await tester.pumpAndSettle();
    final clip = tester.renderObject(
      find
          .ancestor(of: find.text(long), matching: find.byType(ClipRect))
          .first,
    ) as RenderBox;
    final overflow1 = measure(long) - clip.size.width;
    expect(overflow1, greaterThan(0));
    expect(dxOf(long), moreOrLessEquals(-overflow1, epsilon: 0.5));

    // ③ 同一行继续追加:进一步左滑,仍锚定行尾(新字符始终可见)。
    final longer = long + '新到的尾部字符';
    await tester.pumpWidget(build(longer));
    await tester.pumpAndSettle();
    final overflow2 = measure(longer) - clip.size.width;
    expect(overflow2, greaterThan(overflow1));
    expect(dxOf(longer), moreOrLessEquals(-overflow2, epsilon: 0.5));

    // ④ 新行(开头不同):立即回到行首,重新开始打字。
    await tester.pumpWidget(build('全新的一行'));
    await tester.pump();
    expect(dxOf('全新的一行'), 0);
  });

  testWidgets('定稿助手消息操作区:复制全文进剪贴板;分叉回调带消息 seq', (tester) async {
    // 剪贴板走 mock messenger(真 platform channel 在测试环境永挂)。
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = ((call.arguments as Map?)?['text']) as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final nodes = <ChatNode>[
      const ChatNodeAssistant(
        seq: 7,
        type: 'assistant/message',
        text: '复制我,全文进剪贴板',
      ),
    ];
    int? forkedSeq;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 640,
            child: ChatNodeList(nodes: nodes, onFork: (seq) => forkedSeq = seq),
          ),
        ),
      ),
    ));
    // 常显操作区:复制 + 分叉;流式结束(定稿)才出现。
    expect(find.byTooltip('复制全文'), findsOneWidget);
    expect(find.byTooltip('从此处分叉新会话'), findsOneWidget);
    await tester.tap(find.byTooltip('复制全文'));
    await tester.pump();
    expect(copied, '复制我,全文进剪贴板');
    expect(find.byTooltip('已复制'), findsOneWidget); // 图标反馈
    // 消化掉 800ms 图标复位 Timer(测试结束不许留 pending timer)。
    await tester.pump(const Duration(milliseconds: 850));
    expect(find.byTooltip('复制全文'), findsOneWidget); // 复位
    await tester.tap(find.byTooltip('从此处分叉新会话'));
    await tester.pump();
    expect(forkedSeq, 7);
    // 流式消息不出现操作区(定稿才挂)。
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: <ChatNode>[
      ChatNodeAssistant(
        seq: 8,
        type: 'assistant/chunk',
        text: '生成中',
        streaming: true,
      ),
    ])));
    await tester.pump();
    expect(find.byTooltip('复制全文'), findsNothing);
  });

  testWidgets('think 生成中可展开且展开态在后续流式更新下保持', (tester) async {
    Widget build(String text) => _wrap(ChatNodeList(nodes: <ChatNode>[
          ChatNodeThink(
            seq: 2, // firstSeq 稳定:key 不随 delta 漂移
            type: 'assistant/chunk/reasoning',
            text: text,
            streaming: true,
          ),
        ]));
    // 两行文本:标题=最后行「第二行」,正文是整段多行 Text ——
    // 正文断言用 textContaining(子串),标题断言用 text(全等)。
    await tester.pumpWidget(build('第一行\n第二行'));
    expect(find.textContaining('第一行'), findsNothing); // 收起:首行只在正文
    await tester.tap(find.text('第二行')); // 点标题展开
    await tester.pump();
    expect(find.textContaining('第一行'), findsOneWidget);

    // 流式追加(同一块,seq 不变 → State 保留):仍保持展开,新行可见。
    await tester.pumpWidget(build('第一行\n第二行\n第三行'));
    await tester.pump();
    expect(find.textContaining('第一行'), findsOneWidget); // 展开态保持
    expect(find.textContaining('第三行'), findsWidgets); // 新内容已渲染
    // 收起:正文整体隐藏,标题行只留最后一行(尾随滚动模式)。
    await tester.tap(find.text('第三行'));
    await tester.pump();
    expect(find.textContaining('第一行'), findsNothing);
    expect(find.text('第三行'), findsOneWidget); // 标题 = 最后非空行
  });

  testWidgets('think 直播也默认收起:标题行滚动显示最后一行(过滤空行/空白)', (tester) async {
    final nodes = <ChatNode>[
      ChatNodeThink(
        seq: 2,
        type: 'assistant/chunk/reasoning',
        text: '先想第一步\n\n   \n中间思路\n最新的想法  ',
        streaming: true,
      ),
    ];
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    // 直播中也保持收起:思考全文不铺开(不抢占滚动)。
    expect(find.text('先想第一步'), findsNothing);
    expect(find.textContaining('中间思路'), findsNothing);
    // 标题行显示最后一个非空行(尾随空白被过滤),并带「思考中」标记。
    expect(find.text('最新的想法'), findsOneWidget);
    expect(find.text('思考中'), findsOneWidget);
    // 手动展开仍可见全文。
    await tester.tap(find.text('最新的想法'));
    await tester.pump();
    expect(find.textContaining('先想第一步'), findsOneWidget);
    await tester.tap(find.text('最新的想法'));
    await tester.pump();
    expect(find.textContaining('先想第一步'), findsNothing);
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
    // 收起态:名称(人类可读 + 原名) + 摘要 + 状态徽标。
    expect(find.text('终端命令 · bash'), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('ls -la'), findsOneWidget);
    // 展开详情:输入/输出标签与内容出现 + 复制/全屏常显按钮。
    await tester.tap(find.text('终端命令 · bash'));
    await tester.pump();
    expect(find.text('输入'), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    expect(find.textContaining('ls -la'), findsWidgets);
    expect(find.textContaining('file.txt'), findsWidgets);
    expect(find.text('全屏查看'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('工具卡展开态高度贴合内容,无大半空白(回归)', (tester) async {
    // 20 行、每行 ~110 字符带空格的多行输出:旧实现在 IntrinsicHeight 下
    // intrinsic 按卡宽折行(高 ~1900px)、实际布局横向不折行(~360px),
    // 卡片撑出 ~1.6k px 空白。Stack 化后卡片高度必须贴合实际内容。
    final output = List.generate(
        20, (i) => 'line $i ' + List.filled(5, 'a b c d e f g h i j ').join()).join('\n');
    final nodes = <ChatNode>[
      ChatNodeTool(
        seq: 7,
        type: 'tool/call',
        toolName: 'bash',
        callId: 'c7',
        input: {'cmd': 'ls -la'},
        output: {'stdout': output},
        status: ToolStatus.success,
        summary: 'ls -la',
        callSeq: 7,
        resultSeq: 8,
      ),
    ];
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    await tester.tap(find.text('终端命令 · bash'));
    await tester.pump();

    final cardRect = tester.getRect(find.byKey(const ValueKey('tool-card-7')));
    final lastLine = tester.getRect(find.textContaining('line 19'));
    // 卡底与内容末行之间只剩按钮行 + 内边距(~50-120px),不再有千级空白。
    expect(cardRect.bottom - lastLine.bottom, inExclusiveRange(30, 160));
    expect(cardRect.height, lessThan(700));
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
