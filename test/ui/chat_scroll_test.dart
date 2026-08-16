// ChatNodeList 滚动行为测试:贴底跟随、滚离停跟随 + 「回到底部」按钮。
// 场景来自 2026-08-15 反馈:消息进来时用户被死死按在底部,无法上翻。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/ui/node_widgets.dart';

/// 短消息(单行):让内容总量只有几个视口高,惰性物化在少数几帧内收敛,
/// 测试不用泵几十帧等贴底(收敛逻辑见 _convergeToBottom)。
ChatNode _msg(int seq, {int bulk = 20}) =>
    ChatNodeUser(seq: seq, type: 'user/message', text: '消息 $seq' * bulk);

class _Harness extends StatefulWidget {
  const _Harness({required this.initial});
  final List<ChatNode> initial;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<ChatNode> nodes = widget.initial;
  void append(ChatNode n) => setState(() => nodes = [...nodes, n]);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 360, height: 640, child: ChatNodeList(nodes: nodes)),
        ),
      ),
    );
  }
}

double _offset(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

double _maxExtent(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;

void main() {
  testWidgets('用户在底部:新节点到达自动贴底跟随', (tester) async {
    await tester.pumpWidget(_Harness(initial: [for (var i = 0; i < 40; i++) _msg(i)]));
    await tester.pump();
    // 惰性物化下贴底需要几帧收敛(每帧物化新条目后继续追)。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_maxExtent(tester), greaterThan(0));
    expect(_offset(tester), _maxExtent(tester)); // 初始即贴底(收敛)

    tester.state<_HarnessState>(find.byType(_Harness)).append(_msg(40));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_offset(tester), _maxExtent(tester)); // 仍在底部 = 跟随生效
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing);
  });

  testWidgets('用户滚离底部:不再抢滚动,常显「回到底部」按钮', (tester) async {
    await tester.pumpWidget(_Harness(initial: [for (var i = 0; i < 40; i++) _msg(i)]));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_offset(tester), _maxExtent(tester));

    // 用户向上拖(远离底部)。
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    final offsetAfterDrag = _offset(tester);
    expect(offsetAfterDrag, lessThan(_maxExtent(tester) - 120));
    // 按钮出现。
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsOneWidget);

    // 新消息到达:不得把用户拽回底部。
    tester.state<_HarnessState>(find.byType(_Harness)).append(_msg(41));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_offset(tester), offsetAfterDrag);
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsOneWidget);

    // 点「回到底部」:平滑回底,按钮消失,恢复跟随。
    await tester.tap(find.byKey(const ValueKey('scroll-to-bottom')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_offset(tester), _maxExtent(tester));
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing);

    // 回底后新消息恢复自动跟随。
    tester.state<_HarnessState>(find.byType(_Harness)).append(_msg(42));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_offset(tester), _maxExtent(tester));
  });

  testWidgets('短 fling 惯性停在底部附近(120dp 内):不恢复跟随,后续新消息不拽回', (tester) async {
    await tester.pumpWidget(_Harness(initial: [for (var i = 0; i < 40; i++) _msg(i)]));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_offset(tester), _maxExtent(tester));

    // 小幅向上 fling(拖 90dp + 抬手惯性):停在底部 120dp 阈值内。
    await tester.fling(find.byType(ListView), const Offset(0, 90), 200);
    await tester.pump();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final after = _offset(tester);
    expect(after, lessThan(_maxExtent(tester))); // 离开了底部
    expect(_maxExtent(tester) - after, lessThan(120)); // 但仍在旧阈值内
    // 半屏阈值(用户诉求):离底 < 视口一半(640/2=320)不弹按钮;
    // 「回到底部」按钮只在真正翻远后出现。
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing,
        reason: '离底 90dp < 半屏 320dp:按钮不出现');

    // 流式新内容持续到达:位置纹丝不动(绝不程序性滚动)。
    final before = _offset(tester);
    tester.state<_HarnessState>(find.byType(_Harness)).append(_msg(41));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_offset(tester), before);
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing);
  });

  testWidgets('半屏阈值:轻微上翻不弹按钮,翻过半屏才出现;滚回半屏内自动隐藏',
      (tester) async {
    await tester.pumpWidget(_Harness(initial: [for (var i = 0; i < 40; i++) _msg(i)]));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_offset(tester), _maxExtent(tester));

    // 小幅上翻(150dp < 半屏 320dp):跟随停,但按钮不出现。
    await tester.drag(find.byType(ListView), const Offset(0, 150));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_maxExtent(tester) - _offset(tester), greaterThan(100),
        reason: '前置:确已离开底部一段(拖拽阻尼后 ~130dp)');
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing,
        reason: '离底不到半屏:不弹按钮');

    // 继续上翻越过半屏:按钮出现。
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
        _maxExtent(tester) - _offset(tester), greaterThan(320),
        reason: '前置:确已越过半屏');
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsOneWidget,
        reason: '离底超过半屏:按钮出现');

    // 往回滚进半屏内(未到底):按钮自动隐藏;新消息不拽人(跟随仍关)。
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('scroll-to-bottom')), findsNothing,
        reason: '滚回半屏内:按钮隐藏(尽管未贴底)');
    final before = _offset(tester);
    tester.state<_HarnessState>(find.byType(_Harness)).append(_msg(41));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_offset(tester), before,
        reason: '半屏内但未贴底:跟随不复活,不被拽动');
  });
}
