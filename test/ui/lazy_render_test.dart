// 懒渲染回归测试:大列表/大文本不卡 UI 的三道防线。
// 1) 轨迹页虚拟化:大量轮次只构建可视行(远处行未被 build);
//    提取缓存(滚动/折叠 setState 不重算)为内部实现,由现有功能测试回归。
// 2) 工具卡行内截断:>4k 字符输出只渲染首段,标注截断;全屏走分块查看器。
// 3) 思考块截断:>6k 字符只渲染首段 + 「全屏查看完整思考」入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/ui/node_widgets.dart';
import 'package:singleman/ui/trajectory_page.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

SessionEvent _ev(int seq, String type, dynamic data) => SessionEvent(
      type: type,
      seq: seq,
      time: 1786723605000 + seq.toDouble(),
      data: data,
    );

/// N 个完整轮次的流(每轮 user+assistant)。
List<SessionEvent> _manyTurns(int count) {
  final out = <SessionEvent>[];
  var seq = 0;
  for (var i = 0; i < count; i++) {
    out.add(_ev(seq++, 'turn/start', <String, dynamic>{}));
    out.add(_ev(seq++, 'user/message', {
      'content': [
        {'type': 'text', 'text': '第$i轮提问'},
      ],
    }));
    out.add(_ev(seq++, 'assistant/message', {
      'message': {
        'content': [
          {'type': 'text', 'text': '第$i轮回答'},
        ],
      },
    }));
    out.add(_ev(seq++, 'turn/end', <String, dynamic>{}));
  }
  return out;
}

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 360, height: 640, child: child),
        ),
      ),
    );

void main() {
  testWidgets('轨迹页虚拟化:200 轮只构建可视行,远处行不 build', (tester) async {
    final events = _manyTurns(200);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: TrajectoryPage(
        sessionId: 's1',
        events: events,
      ),
    ));
    await tester.pump();
    // 列表初始在顶部:首轮可见,末轮(第 199 轮)在数千像素之外 ——
    // 虚拟化下它的行文本不应被构建(旧实现全量 children 必然存在)。
    expect(find.text('第0轮提问'), findsOneWidget);
    expect(find.text('第199轮提问'), findsNothing);
    // 轮次头本身也虚拟化:只出现可见窗口内的头。
    final headerCount = find.textContaining('轮').evaluate().length;
    expect(headerCount, lessThan(200));
    await tester.pumpAndSettle();
  });

  testWidgets('工具卡输出行内截断:>4k 字符只渲染首段 + 截断标注', (tester) async {
    final big = 'x' * 20000;
    final nodes = <ChatNode>[
      ChatNodeTool(
        seq: 1,
        type: 'tool/call',
        toolName: 'bash',
        output: big,
        status: ToolStatus.success,
      ),
    ];
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    // 收起态直接展开详情。
    await tester.tap(find.textContaining('bash'));
    await tester.pump();
    // 截断标注出现,且 SelectableText 不含全部 2 万字符(只渲染首段)。
    expect(find.textContaining('已截断'), findsOneWidget);
    final selectable = tester.widgetList<SelectableText>(find.byType(SelectableText));
    for (final s in selectable) {
      final data = s.data ?? '';
      expect(data.length, lessThan(20000));
    }
  });

  testWidgets('思考块截断:>6k 字符渲染首段 + 全屏入口', (tester) async {
    final longThink = '深' * 12000;
    final nodes = <ChatNode>[
      ChatNodeThink(seq: 1, type: 'assistant/reasoning', text: longThink),
    ];
    await tester.pumpWidget(_wrap(ChatNodeList(nodes: nodes)));
    await tester.tap(find.text('思考过程'));
    await tester.pump();
    expect(find.textContaining('已截断'), findsOneWidget);
    expect(find.text('全屏查看完整思考'), findsOneWidget);
    // 全屏入口在长文下方,先滚到位再点(限高滚动容器内的按钮)。
    await tester.ensureVisible(find.text('全屏查看完整思考'));
    await tester.pump();
    await tester.tap(find.text('全屏查看完整思考'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('复制全部'), findsOneWidget);
  });

  testWidgets('分块查看器:巨型文本按块渲染,滚动不炸', (tester) async {
    final huge = 'a' * 60000; // 10 块。
    var built = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChunkedTextViewer(
          text: huge,
        ),
      ),
    ));
    await tester.pump();
    // 统计首帧后构建的 SelectableText 数(虚拟化下应远小于总块数)。
    built = tester.widgetList<SelectableText>(find.byType(SelectableText)).length;
    expect(built, greaterThanOrEqualTo(1));
    expect(built, lessThan(10));
    expect(tester.takeException(), isNull);
  });
}
