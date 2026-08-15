// MessageImages / AttachmentLightbox widget 测试(W2-C,360dp 窄屏):
// 单图尺寸约束(长边 240/小图不放大/极宽钳 4:1)、多图 64px 网格点击开灯箱 +
// 左右滑动切换、失败重试按钮(≥44dp)。注入假 AttachmentFetchView,不 import 共享 helper。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/attachment_fetch.dart';
import 'package:singleman/ui/attachment_views.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 1x1 透明 PNG(base64,可被 Image 解码;解码失败才走 errorBuilder)。
const String _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

/// 假 fetcher:可编程失败;统计调用次数与请求的 attachmentId。
class _FakeFetcher implements AttachmentFetchView {
  _FakeFetcher({this.failAll = false});
  bool failAll;
  int calls = 0;
  final List<String> requested = <String>[];

  @override
  Future<FetchedAttachment> fetch(String sessionId, String attachmentId) async {
    calls += 1;
    requested.add(attachmentId);
    if (failAll) throw Exception('fetch failed');
    return FetchedAttachment(
      ref: ImageAttachmentRef(
        attachmentId: attachmentId,
        mediaType: 'image/png',
        bytes: 67,
        width: 1,
        height: 1,
        name: null,
      ),
      bytes: base64Decode(_png1x1),
    );
  }
}

ImageAttachmentRef _ref(String id, {int width = 400, int height = 200}) =>
    ImageAttachmentRef(
      attachmentId: id,
      mediaType: 'image/png',
      bytes: 100,
      width: width,
      height: height,
      name: null,
    );

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('单图尺寸:长边 240 保持比例;小图不放大;极宽钳到 4:1', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fetcher = _FakeFetcher();

    // 400x200 → 240x120(比例 2 保持,长边钳 240)。
    await tester.pumpWidget(_wrap(MessageImages(
        sessionId: 's1', refs: <ImageAttachmentRef>[_ref('a1', width: 400, height: 200)], fetcher: fetcher)));
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey<String>('message-image-a1'))),
        const Size(240, 120));

    // 小图 100x50 → 100x50(不放大超原尺寸)。
    await tester.pumpWidget(_wrap(MessageImages(
        sessionId: 's1', refs: <ImageAttachmentRef>[_ref('a2', width: 100, height: 50)], fetcher: fetcher)));
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey<String>('message-image-a2'))),
        const Size(100, 50));

    // 极宽 1000x50 → 240x60(宽高比钳到 4)。
    await tester.pumpWidget(_wrap(MessageImages(
        sessionId: 's1', refs: <ImageAttachmentRef>[_ref('a3', width: 1000, height: 50)], fetcher: fetcher)));
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey<String>('message-image-a3'))),
        const Size(240, 60));

    // 极高 50x1000 → 60x240(宽高比钳到 0.25)。
    await tester.pumpWidget(_wrap(MessageImages(
        sessionId: 's1', refs: <ImageAttachmentRef>[_ref('a4', width: 50, height: 1000)], fetcher: fetcher)));
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey<String>('message-image-a4'))),
        const Size(60, 240));
  });

  testWidgets('多图:64px 方块网格,点击进灯箱,左右滑动切换页码', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fetcher = _FakeFetcher();
    final refs = <ImageAttachmentRef>[_ref('a1'), _ref('a2'), _ref('a3')];
    await tester.pumpWidget(_wrap(MessageImages(
        sessionId: 's1', refs: refs, fetcher: fetcher)));
    await tester.pump();

    // 网格方块 64px。
    expect(tester.getSize(find.byKey(const ValueKey<String>('message-tile-0'))),
        const Size(64, 64));

    // 点击第一块 → 灯箱打开,页码 1 / 3。
    await tester.tap(find.byKey(const ValueKey<String>('message-tile-0')));
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentLightbox), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);

    // 左右滑动切换 → 2 / 3。
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    // 点关闭按钮 → 灯箱关闭,网格仍在。
    await tester.tap(find.byKey(const ValueKey<String>('lightbox-close')));
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentLightbox), findsNothing);
    expect(find.byKey(const ValueKey<String>('message-tile-0')), findsOneWidget);
  });

  testWidgets('灯箱下滑关闭:向下拖动超阈值后灯箱关闭', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fetcher = _FakeFetcher();
    await tester.pumpWidget(_wrap(MessageImages(
        sessionId: 's1',
        refs: <ImageAttachmentRef>[_ref('a1', width: 400, height: 200)],
        fetcher: fetcher)));
    await tester.pump();

    // 点单图 → 灯箱打开。
    await tester.tap(find.byKey(const ValueKey<String>('message-image-a1')));
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentLightbox), findsOneWidget);

    // 下滑 150dp > 阈值 120 → 关闭。
    await tester.drag(find.byType(AttachmentLightbox), const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentLightbox), findsNothing);
  });

  testWidgets('加载失败:显式重试按钮 ≥44dp,点击后重试成功', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fetcher = _FakeFetcher(failAll: true);
    await tester.pumpWidget(_wrap(MessageImages(
        sessionId: 's1',
        refs: <ImageAttachmentRef>[_ref('a1', width: 400, height: 200)],
        fetcher: fetcher)));
    await tester.pumpAndSettle();

    // 失败态:显式重试按钮,高度 ≥44dp。
    expect(find.text('重试'), findsOneWidget);
    final retrySize = tester.getSize(find.byKey(const ValueKey<String>('attachment-retry')));
    expect(retrySize.height, greaterThanOrEqualTo(44));

    // 修好 → 点重试 → 错误消失,再次发起请求。
    fetcher.failAll = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsNothing);
    expect(fetcher.calls, 2);
  });

  testWidgets('多图失败:方块内常显重试 icon,点击重试', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fetcher = _FakeFetcher(failAll: true);
    await tester.pumpWidget(_wrap(MessageImages(
        sessionId: 's1',
        refs: <ImageAttachmentRef>[_ref('a1'), _ref('a2')],
        fetcher: fetcher)));
    await tester.pumpAndSettle();

    // 每个方块都是失败态:两张都走重试(常显 refresh icon)。
    expect(find.byIcon(Icons.refresh), findsNWidgets(2));
    // 修好 → 点第一块(方块本身即重试目标)→ 重新拉取。
    fetcher.failAll = false;
    await tester.tap(find.byKey(const ValueKey<String>('message-tile-0')));
    await tester.pumpAndSettle();
    expect(fetcher.requested, <String>['a1', 'a2', 'a1']);
  });
}
