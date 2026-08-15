// FeedbackActions + ProducedFilesRow widget 测试(W3-B):360dp 窄屏,
// 反馈三态/切换保留 note/备注 sheet/重连 resync;产出 lane 截断/+N/回调/fit 纯函数。
// 模式:假 FeedbackStoreView(不碰 socket/HTTP)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/feedback_store.dart';
import 'package:singleman/ui/deliverables_row.dart';
import 'package:singleman/ui/feedback_row.dart';

/// 假 FeedbackStoreView:常驻 items + 调用记录;put/delete 同步更新本地。
class _FakeFeedbackStore implements FeedbackStoreView {
  List<FeedbackItem> items = <FeedbackItem>[];
  final List<String> puts = <String>[];
  final List<String> deletes = <String>[];
  int listCalls = 0;
  Object? putError;
  final StreamController<void> _changed = StreamController<void>.broadcast();

  @override
  List<FeedbackItem> itemsFor(String sessionId) => items;

  @override
  Stream<void> get changed => _changed.stream;

  @override
  Future<List<FeedbackItem>> list(String sessionId,
      {bool force = false}) async {
    listCalls += 1;
    return items;
  }

  @override
  Future<FeedbackItem> put(
    String sessionId,
    String messageId,
    FeedbackRating rating, {
    String? note,
    Object? ifVersion,
  }) async {
    puts.add(messageId +
        ':' +
        rating.wire +
        ':' +
        (note ?? '') +
        ':' +
        (ifVersion == null ? '-' : ifVersion.toString()));
    if (putError != null) throw putError!;
    final item = FeedbackItem(
      messageId: messageId,
      rating: rating,
      note: note,
      version: ifVersion == null ? 1 : 2,
      createdAt: 'c',
      updatedAt: 'u',
    );
    items = <FeedbackItem>[
      for (final e in items)
        if (e.messageId != messageId) e,
      item,
    ];
    _changed.add(null);
    return item;
  }

  @override
  Future<bool> delete(String sessionId, String messageId,
      {Object? ifVersion}) async {
    deletes.add(messageId +
        ':' +
        (ifVersion == null ? '-' : ifVersion.toString()));
    items = <FeedbackItem>[
      for (final e in items)
        if (e.messageId != messageId) e,
    ];
    _changed.add(null);
    return false;
  }
}

FeedbackItem _item(String messageId,
        {FeedbackRating rating = FeedbackRating.positive,
        String? note,
        Object? version = 1}) =>
    FeedbackItem(
      messageId: messageId,
      rating: rating,
      note: note,
      version: version,
      createdAt: 'c',
      updatedAt: 'u',
    );

Future<void> _pumpFeedback(
  WidgetTester tester,
  _FakeFeedbackStore store, {
  ValueNotifier<int>? tick,
}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: FeedbackActions(
          store: store,
          sessionId: 's1',
          messageId: 'm1',
          resyncTick: tick,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('FeedbackActions', () {
    testWidgets(
        '360dp 反馈三态:未评 outline → 点 👍 put(positive)+高亮 → 再点撤回(delete)→ 未评',
        (tester) async {
      final store = _FakeFeedbackStore();
      await _pumpFeedback(tester, store);

      // 未评:outline 图标,无 filled;请求在途后已归位。
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_down_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsNothing);
      expect(store.puts, isEmpty);

      // 点 👍 → put(positive);图标转 filled 高亮。
      await tester.tap(find.byKey(const ValueKey('feedback-thumb-up')));
      await tester.pumpAndSettle();
      expect(store.puts, ['m1:positive::-']);
      expect(find.byIcon(Icons.thumb_up), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);

      // 再点 👍 → 撤回(delete,ifVersion 为 put 后版本 1);回未评。
      await tester.tap(find.byKey(const ValueKey('feedback-thumb-up')));
      await tester.pumpAndSettle();
      expect(store.deletes, ['m1:1']);
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up), findsNothing);
    });

    testWidgets('360dp 切换保留 note:已评 positive 带 note → 点 👎 → put(negative,note 保留)',
        (tester) async {
      final store = _FakeFeedbackStore();
      store.items = [_item('m1', rating: FeedbackRating.positive, note: '细节不错', version: 7)];
      await _pumpFeedback(tester, store);

      expect(find.byIcon(Icons.thumb_up), findsOneWidget); // 已评高亮。
      await tester.tap(find.byKey(const ValueKey('feedback-thumb-down')));
      await tester.pumpAndSettle();
      expect(store.puts, ['m1:negative:细节不错:7']);
      expect(find.byIcon(Icons.thumb_down), findsOneWidget);
    });

    testWidgets('360dp 备注 sheet:保存 put 带 note;本地预拒 maxLength=8192',
        (tester) async {
      final store = _FakeFeedbackStore();
      store.items = [_item('m1', rating: FeedbackRating.positive, version: 5)];
      await _pumpFeedback(tester, store);

      await tester.tap(find.byKey(const ValueKey('feedback-note')));
      await tester.pumpAndSettle();
      expect(find.text('消息反馈备注'), findsOneWidget);
      // 本地预拒:输入框 maxLength == 8192(与 store 常量同值)。
      final field = tester.widget<TextField>(
          find.byKey(const ValueKey('feedback-note-field')));
      expect(field.maxLength, kFeedbackNoteMaxBytes);

      await tester.enterText(
          find.byKey(const ValueKey('feedback-note-field')), '补充说明');
      await tester.tap(find.byKey(const ValueKey('feedback-note-save')));
      await tester.pumpAndSettle();
      expect(store.puts, ['m1:positive:补充说明:5']);
      expect(find.text('消息反馈备注'), findsNothing); // sheet 已关闭。
    });

    testWidgets('360dp 备注保存:未评分 → 内联提示先评分,不发 put', (tester) async {
      final store = _FakeFeedbackStore();
      await _pumpFeedback(tester, store);

      await tester.tap(find.byKey(const ValueKey('feedback-note')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('feedback-note-field')), 'x');
      await tester.tap(find.byKey(const ValueKey('feedback-note-save')));
      await tester.pumpAndSettle();
      expect(find.text('请先选择 👍/👎 评分再保存备注'), findsOneWidget);
      expect(store.puts, isEmpty);
    });

    testWidgets('360dp 备注保存:服务端 note-too-large → 行内错误文案(原因码)',
        (tester) async {
      final store = _FakeFeedbackStore();
      store.items = [_item('m1', rating: FeedbackRating.positive, version: 3)];
      store.putError = const FeedbackNoteTooLargeException();
      await _pumpFeedback(tester, store);

      await tester.tap(find.byKey(const ValueKey('feedback-note')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('feedback-note-field')), '很长很长的备注');
      await tester.tap(find.byKey(const ValueKey('feedback-note-save')));
      await tester.pumpAndSettle();
      expect(find.text('备注过长(上限 8192 字符,note-too-large)'),
          findsOneWidget);
    });

    testWidgets('360dp 重连 resync:resyncTick 变化 → 重拉 list', (tester) async {
      final store = _FakeFeedbackStore();
      final tick = ValueNotifier<int>(0);
      await _pumpFeedback(tester, store, tick: tick);
      expect(store.listCalls, 1);

      tick.value = 1; // 代际翻转 → resync 重拉。
      await tester.pumpAndSettle();
      expect(store.listCalls, 2);
    });
  });

  group('ProducedFilesRow', () {
    Future<void> pumpLane(
      WidgetTester tester,
      List<String> paths, {
      void Function(String)? onOpenFile,
      double width = 360,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: ProducedFilesRow(paths: paths, onOpenFile: onOpenFile),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    List<String> shortPaths(int n) => <String>[
          for (var i = 0; i < n; i++)
            '/tmp/w/' + String.fromCharCode(97 + i) + '.dart',
        ];

    testWidgets('360dp 产出 lane 窄屏截断:最大前缀 + 精确余数 + tooltip + 回调 + ≥44dp',
        (tester) async {
      final opened = <String>[];
      final paths = shortPaths(8); // a.dart … h.dart(basename 6 字符)。
      await pumpLane(tester, paths, onOpenFile: opened.add);

      // 360dp 下 6 个放不下:精确前缀(2 chip)+ 余数计数恒可见。
      expect(find.byKey(const ValueKey('deliverables-chip-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('deliverables-chip-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('deliverables-chip-2')), findsNothing);
      expect(find.text('+6 个文件'), findsOneWidget);

      // chip = basename;tooltip = 完整路径。
      expect(find.text('a.dart'), findsOneWidget);
      expect(find.byTooltip('/tmp/w/a.dart'), findsOneWidget);

      // 点击回调收到完整路径。
      await tester.tap(find.byKey(const ValueKey('deliverables-chip-0')));
      expect(opened, ['/tmp/w/a.dart']);

      // 触控高度 ≥44(移动硬性)。
      expect(
          tester
              .getSize(find.byKey(const ValueKey('deliverables-chip-0')))
              .height,
          greaterThanOrEqualTo(44));
    });

    testWidgets('宽屏(800dp)产出 lane:6 chip 上限 + N 个文件;basename 认反斜杠',
        (tester) async {
      final paths = <String>[
        r'C:\\tmp\\w\\app.dart', // 反斜杠路径 → basename 'app.dart'。
        ...shortPaths(7),
      ];
      await pumpLane(tester, paths, width: 800);

      for (var i = 0; i < 6; i++) {
        expect(
            find.byKey(ValueKey('deliverables-chip-' + i.toString())),
            findsOneWidget);
      }
      expect(find.byKey(const ValueKey('deliverables-chip-6')), findsNothing);
      expect(find.text('+2 个文件'), findsOneWidget);
      expect(find.text('app.dart'), findsOneWidget);
    });

    testWidgets('空路径 → 不渲染 lane', (tester) async {
      await pumpLane(tester, const <String>[]);
      expect(find.byKey(const ValueKey('deliverables-lane')), findsNothing);
      expect(find.byType(ProducedFilesRow), findsOneWidget); // 占位 shrink。
    });

    test('fitProducedFiles 纯函数:最大前缀 + 精确余数 + cap 上限 + 仅余数兜底', () {
      // 截断 + 余数:[100,100,100],可用 280,gap 8,label 50:
      // k=3(无 label)→ 316 > 280;k=2 → 100+8+100=208,more>0 → +8+50=266 ≤ 280。
      final fit = fitProducedFiles(
        chipWidths: const [100, 100, 100],
        availableWidth: 280,
        moreLabelWidth: (more) => 50.0,
      );
      expect(fit.shownCount, 2);
      expect(fit.moreCount, 1);

      // 全部放下:无 label(余数 0),k=3 → 50+8+50+8+50=166 ≤ 200。
      final all = fitProducedFiles(
        chipWidths: const [50, 50, 50],
        availableWidth: 200,
        moreLabelWidth: (more) => 60.0,
      );
      expect(all.shownCount, 3);
      expect(all.moreCount, 0);

      // cap=6:8 个都能放,仍只显示 6 个,余数 2。
      final capped = fitProducedFiles(
        chipWidths: List<double>.filled(8, 30),
        availableWidth: 1000,
        moreLabelWidth: (more) => 50.0,
      );
      expect(capped.shownCount, 6);
      expect(capped.moreCount, 2);

      // 什么都放不下 → 仅余数计数(恒可见)。
      final bare = fitProducedFiles(
        chipWidths: const [200, 200],
        availableWidth: 150,
        moreLabelWidth: (more) => 60.0,
      );
      expect(bare.shownCount, 0);
      expect(bare.moreCount, 2);

      // 空列表。
      final empty = fitProducedFiles(
        chipWidths: const [],
        availableWidth: 100,
        moreLabelWidth: (more) => 60.0,
      );
      expect(empty.shownCount, 0);
      expect(empty.moreCount, 0);
    });
  });
}
