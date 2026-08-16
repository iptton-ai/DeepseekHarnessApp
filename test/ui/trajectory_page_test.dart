// TrajectoryPage widget 测试(W3-A;360dp 移动形态)。
// 覆盖:轮次分组渲染 / 展开折叠 / 搜索过滤 / 行点击 → 底部 sheet 检查器 /
// 宽屏(1200dp)两列无溢出冒烟。不 import 共享 helper;事件为自建假数据。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/ui/trajectory_page.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

SessionEvent _ev(int seq, String type, dynamic data, {double? time}) =>
    SessionEvent(
      type: type,
      seq: seq,
      time: time ?? 1786723605000 + seq.toDouble(),
      data: data,
    );

SessionEvent _ts(int seq, {double? time}) =>
    _ev(seq, 'turn/start', <String, dynamic>{}, time: time);
SessionEvent _te(int seq, {double? time}) =>
    _ev(seq, 'turn/end', <String, dynamic>{}, time: time);

SessionEvent _user(int seq, String text) => _ev(seq, 'user/message', {
  'content': <Map<String, dynamic>>[
    {'type': 'text', 'text': text},
  ],
});

SessionEvent _assistant(int seq, String text) => _ev(seq, 'assistant/message', {
  'message': <String, dynamic>{
    'content': <Map<String, dynamic>>[
      {'type': 'text', 'text': text},
    ],
  },
});

/// 双轮 + 一条轮外事件的完整样例流。
List<SessionEvent> _sampleEvents() => <SessionEvent>[
  _ts(1),
  _user(2, '第一轮提问'),
  _assistant(3, '第一轮回答'),
  _te(4),
  _ev(5, 'compaction/start', <String, dynamic>{}),
  _ts(6),
  _user(7, '第二轮提问'),
  _assistant(8, '第二轮回答'),
  _te(9),
];

List<SessionEvent> _manyTurns(int count) {
  final out = <SessionEvent>[];
  var seq = 1;
  for (var i = 0; i < count; i++) {
    out.add(_ts(seq++));
    out.add(_user(seq++, '第$i轮提问'));
    out.add(_assistant(seq++, '第$i轮回答'));
    out.add(_te(seq++));
  }
  return out;
}

Future<void> _pumpPage(
  WidgetTester tester,
  List<SessionEvent> events, {
  Size size = const Size(360, 800),
  bool hasOlder = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: TrajectoryPage(
        sessionId: 's1',
        events: events,
        hasOlder: hasOlder,
        onLoadOlder: () async {},
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('分组渲染:轮头卡 + 行卡 + 轮外区段(360dp)', (tester) async {
    await _pumpPage(tester, _sampleEvents());

    // 轮头:第 1 轮 / 第 2 轮。
    expect(find.text('第 1 轮'), findsOneWidget);
    expect(find.text('第 2 轮'), findsOneWidget);
    // 行卡摘要(默认展开)。
    expect(find.text('第一轮提问'), findsOneWidget);
    expect(find.text('第一轮回答'), findsOneWidget);
    expect(find.text('第二轮提问'), findsOneWidget);
    // 轮外区段头。
    expect(find.textContaining('轮外事件'), findsOneWidget);
    // 顶栏计数。
    expect(find.text('2 轮 · 1 轮外'), findsOneWidget);
  });

  testWidgets('展开/折叠:全部折叠隐藏行,全部展开恢复(360dp)', (tester) async {
    await _pumpPage(tester, _sampleEvents());
    expect(find.text('第一轮提问'), findsOneWidget);

    // 全部折叠 → 行隐藏,轮头仍在。
    await tester.tap(find.byTooltip('全部折叠'));
    await tester.pump();
    expect(find.text('第一轮提问'), findsNothing);
    expect(find.text('第一轮回答'), findsNothing);
    expect(find.text('第 1 轮'), findsOneWidget);
    expect(find.text('第 2 轮'), findsOneWidget);

    // 全部展开 → 行恢复。
    await tester.tap(find.byTooltip('全部展开'));
    await tester.pump();
    expect(find.text('第一轮提问'), findsOneWidget);
    expect(find.text('第二轮提问'), findsOneWidget);
  });

  testWidgets('搜索过滤:按摘要/类型实时过滤,命中强制展开(360dp)', (tester) async {
    await _pumpPage(tester, _sampleEvents());

    // 摘要过滤:只留第二轮的行。
    await tester.enterText(find.byType(TextField), '第二轮');
    await tester.pump();
    expect(find.text('第 1 轮'), findsNothing);
    expect(find.text('第 2 轮'), findsOneWidget);
    expect(find.text('第二轮提问'), findsOneWidget);
    expect(find.text('第二轮回答'), findsOneWidget);
    expect(find.text('第一轮提问'), findsNothing);

    // 类型过滤(即使该轮当前被收起也强制展开显示命中行)。
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.tap(find.byTooltip('全部折叠'));
    await tester.pump();
    expect(find.text('第一轮提问'), findsNothing);
    await tester.enterText(find.byType(TextField), 'user/message');
    await tester.pump();
    expect(find.text('第一轮提问'), findsOneWidget);
    expect(find.text('第二轮提问'), findsOneWidget);
    expect(find.text('第一轮回答'), findsNothing); // assistant 行被过滤。

    // 无匹配提示。
    await tester.enterText(find.byType(TextField), 'zzz不存在');
    await tester.pump();
    expect(find.text('无匹配轨迹'), findsOneWidget);
  });

  testWidgets('行点击 → 底部 sheet 检查器:完整摘要 + 原始 JSON(360dp)', (tester) async {
    await _pumpPage(tester, _sampleEvents());

    await tester.tap(find.text('第一轮回答'));
    await tester.pumpAndSettle();

    // sheet:类型、seq、完整摘要、原始 JSON 折叠入口。
    expect(find.text('assistant/message'), findsOneWidget);
    expect(find.text('原始 JSON'), findsOneWidget);
    expect(find.text('第一轮回答'), findsWidgets);

    // 展开原始 JSON → 等宽 JSON 可见(含 type 字段)。
    await tester.tap(find.text('原始 JSON'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"type": "assistant/message"'), findsOneWidget);
  });

  testWidgets('「加载更早」按钮在 hasOlder 时渲染并触发回调(360dp)', (tester) async {
    var calls = 0;
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: TrajectoryPage(
          sessionId: 's1',
          events: _sampleEvents(),
          hasOlder: true,
          onLoadOlder: () async {
            calls += 1;
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.text('加载更早'), findsOneWidget);
    await tester.tap(find.text('加载更早'));
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('回到尾部 FAB:大列表点击后收敛到尾部且不抛异常', (tester) async {
    await _pumpPage(tester, _manyTurns(80));

    await tester.drag(find.byType(ListView), const Offset(0, -2400));
    await tester.pumpAndSettle();
    expect(find.byTooltip('回到尾部'), findsOneWidget);

    await tester.tap(find.byTooltip('回到尾部'));
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏(1200dp):行内两列渲染无溢出冒烟', (tester) async {
    await _pumpPage(tester, _sampleEvents(), size: const Size(1200, 800));
    expect(find.text('第 1 轮'), findsOneWidget);
    expect(find.text('第一轮提问'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
