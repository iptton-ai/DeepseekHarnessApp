// MessageImages / AttachmentLightbox — W2-C 图片消息渲染(web dsh-client-ui-attachment
// 画廊/灯箱原子组件的 Flutter 化;audit/settings-system.md §6)。
//
// 职责边界:只渲染「已有 ImageAttachmentRef」;从事件里提取 refs 的管线属集成方
// (event_nodes.dart 目前只产文本节点,不产 refs —— 对接点见报告)。
//
// 移动纪律(硬性):
// - 单图:长边 ≤240 逻辑像素、宽高比钳 [0.25,4]、cover、不放大超原尺寸(web 同款)
// - 多图:64px 方块网格(弹性换行),点击进灯箱
// - 灯箱:全屏 dialog、双指缩放(InteractiveViewer)、下滑关闭、左右滑动切换(PageView)
// - 加载失败显式重试按钮(≥44dp);hover 语义 → 常显按钮
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:singleman/sessions/attachment_fetch.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 单图展示长边上限(逻辑像素,web 同款 240px)。
const double kMessageImageMaxEdge = 240;

/// 多图网格方块边长(web 同款 64px)。
const double kMessageImageTile = 64;

/// 触控目标下限(移动可用性硬性)。
const double kAttachmentMinTouch = 44;

/// 灯箱下滑关闭阈值(逻辑像素)。
const double kLightboxCloseDragDistance = 120;

/// 单图展示盒尺寸:长边 ≤240、宽高比钳 [0.25,4]、不放大超原尺寸。
/// 极高图按 0.25 下限钳宽,极宽图按 4 上限钳高;宽高比已在 [0.25,4] 内时只做长边缩放。
Size messageImageSize(ImageAttachmentRef ref) {
  final w = ref.width.toDouble();
  final h = ref.height.toDouble();
  if (w <= 0 || h <= 0) {
    return const Size(kMessageImageMaxEdge, kMessageImageMaxEdge);
  }
  final scale = math.min(1.0, kMessageImageMaxEdge / math.max(w, h));
  var dw = w * scale;
  var dh = h * scale;
  final ratio = dw / dh;
  if (ratio < 0.25) {
    dw = dh * 0.25; // 极高图:钳到 0.25(cover 横向裁切)。
  } else if (ratio > 4) {
    dh = dw / 4; // 极宽图:钳到 4(cover 纵向裁切)。
  }
  return Size(dw, dh);
}

/// cover 锚点:宽图(图比 > 盒比)锚左,高图锚顶(web 同款)。
Alignment _coverAnchor(ImageAttachmentRef ref) {
  final box = messageImageSize(ref);
  if (ref.width <= 0 || ref.height <= 0) return Alignment.center;
  final imageRatio = ref.width / ref.height;
  final boxRatio = box.width / box.height;
  return imageRatio > boxRatio ? Alignment.centerLeft : Alignment.topCenter;
}

/// 图片画廊:单图(长边 240,cover)+ 多图(64px 方块网格)。点击任意一张进灯箱。
class MessageImages extends StatelessWidget {
  const MessageImages({
    super.key,
    required this.sessionId,
    required this.refs,
    required this.fetcher,
    this.alignment = WrapAlignment.start,
  });

  /// 图片所属会话(附件按会话授权拉取)。
  final String sessionId;
  final List<ImageAttachmentRef> refs;
  final AttachmentFetchView fetcher;

  /// 画廊对齐:用户消息 end、助手消息 start(web 同款)。
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    if (refs.isEmpty) return const SizedBox.shrink();
    if (refs.length == 1) {
      return _SingleImage(
          sessionId: sessionId, ref: refs.first, fetcher: fetcher);
    }
    return _ImageGrid(
        sessionId: sessionId, refs: refs, fetcher: fetcher, alignment: alignment);
  }
}

/// 单图:长边 ≤240、比例钳 [0.25,4] 的固定盒,cover 填充,点击进灯箱。
class _SingleImage extends StatelessWidget {
  const _SingleImage(
      {required this.sessionId, required this.ref, required this.fetcher});
  final String sessionId;
  final ImageAttachmentRef ref;
  final AttachmentFetchView fetcher;

  @override
  Widget build(BuildContext context) {
    final size = messageImageSize(ref);
    return Semantics(
      button: true,
      label: '查看大图',
      child: GestureDetector(
        onTap: () => showAttachmentLightbox(context,
            sessionId: sessionId, refs: <ImageAttachmentRef>[ref], fetcher: fetcher),
        child: SizedBox(
          key: ValueKey<String>('message-image-${ref.attachmentId}'),
          width: size.width,
          height: size.height,
          child: _AttachmentImage(
            sessionId: sessionId,
            ref: ref,
            fetcher: fetcher,
            fit: BoxFit.cover,
            alignment: _coverAnchor(ref),
          ),
        ),
      ),
    );
  }
}

/// 多图:64px 方块弹性换行网格,点击第 i 块进灯箱第 i 张。
class _ImageGrid extends StatelessWidget {
  const _ImageGrid(
      {required this.sessionId,
      required this.refs,
      required this.fetcher,
      required this.alignment});
  final String sessionId;
  final List<ImageAttachmentRef> refs;
  final AttachmentFetchView fetcher;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: alignment,
      children: <Widget>[
        for (var i = 0; i < refs.length; i++)
          _ImageTile(
            index: i,
            sessionId: sessionId,
            ref: refs[i],
            fetcher: fetcher,
            onTap: () => showAttachmentLightbox(context,
                sessionId: sessionId, refs: refs, fetcher: fetcher, initialIndex: i),
          ),
      ],
    );
  }
}

class _ImageTile extends StatelessWidget {
  const _ImageTile(
      {required this.index,
      required this.sessionId,
      required this.ref,
      required this.fetcher,
      required this.onTap});
  final int index;
  final String sessionId;
  final ImageAttachmentRef ref;
  final AttachmentFetchView fetcher;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '查看图片 ${index + 1}',
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            key: ValueKey<String>('message-tile-$index'),
            width: kMessageImageTile,
            height: kMessageImageTile,
            child: _AttachmentImage(
              sessionId: sessionId,
              ref: ref,
              fetcher: fetcher,
              fit: BoxFit.cover,
              alignment: _coverAnchor(ref),
              compactRetry: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// 打开全屏灯箱(fullscreenDialog 路由;refs 为空时不动作)。
Future<void> showAttachmentLightbox(
  BuildContext context, {
  required String sessionId,
  required List<ImageAttachmentRef> refs,
  required AttachmentFetchView fetcher,
  int initialIndex = 0,
}) {
  if (refs.isEmpty) return Future<void>.value();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => AttachmentLightbox(
        sessionId: sessionId,
        refs: refs,
        fetcher: fetcher,
        initialIndex: initialIndex,
      ),
    ),
  );
}

/// 全屏图片灯箱:双指缩放(InteractiveViewer)、左右滑动切换(PageView)、
/// 下滑关闭(Listener 原始指针判定,不与手势竞技场抢)、失败显式重试。
class AttachmentLightbox extends StatefulWidget {
  const AttachmentLightbox({
    super.key,
    required this.sessionId,
    required this.refs,
    required this.fetcher,
    this.initialIndex = 0,
  });
  final String sessionId;
  final List<ImageAttachmentRef> refs;
  final AttachmentFetchView fetcher;
  final int initialIndex;

  @override
  State<AttachmentLightbox> createState() => _AttachmentLightboxState();
}

class _AttachmentLightboxState extends State<AttachmentLightbox> {
  late final PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, math.max(0, widget.refs.length - 1));
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    final refs = widget.refs;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: PageView.builder(
              controller: _pageController,
              itemCount: refs.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => _LightboxPage(
                key: ValueKey<String>('lightbox-page-$i'),
                sessionId: widget.sessionId,
                ref: refs[i],
                fetcher: widget.fetcher,
                onClose: _close,
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: <Widget>[
                  IconButton(
                    key: const ValueKey<String>('lightbox-close'),
                    tooltip: '关闭',
                    onPressed: _close,
                    icon: const Icon(Icons.close),
                    color: Colors.white,
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  ),
                  Expanded(
                    child: Text(
                      '${_index + 1} / ${refs.length}',
                      key: const ValueKey<String>('lightbox-counter'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 48), // 平衡关闭按钮宽度。
                ],
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

/// 灯箱单页:InteractiveViewer 双指缩放 + Listener 下滑关闭(仅恒等变换时武装)。
class _LightboxPage extends StatefulWidget {
  const _LightboxPage(
      {super.key,
      required this.sessionId,
      required this.ref,
      required this.fetcher,
      required this.onClose});
  final String sessionId;
  final ImageAttachmentRef ref;
  final AttachmentFetchView fetcher;
  final VoidCallback onClose;

  @override
  State<_LightboxPage> createState() => _LightboxPageState();
}

class _LightboxPageState extends State<_LightboxPage> {
  final TransformationController _transform = TransformationController();
  Offset? _down;
  bool _armed = false;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// 恒等变换判定:scale=1 且无平移(放大/拖动后下滑关闭自动失效,交给画布平移)。
  bool get _atIdentity {
    final m = _transform.value.storage;
    return (m[0] - 1).abs() < 1e-9 &&
        (m[5] - 1).abs() < 1e-9 &&
        (m[10] - 1).abs() < 1e-9 &&
        m[12].abs() < 1e-9 &&
        m[13].abs() < 1e-9;
  }

  void _onPointerDown(PointerDownEvent event) {
    _down = event.position;
    _armed = _atIdentity;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_down == null || !_armed) return;
    final dy = event.position.dy - _down!.dy;
    if (dy > kLightboxCloseDragDistance) {
      _armed = false; // 已触发,不再重复。
      widget.onClose();
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_armed && _down != null) {
      final dy = event.position.dy - _down!.dy;
      if (dy > kLightboxCloseDragDistance) {
        _armed = false;
        widget.onClose();
      }
    }
    _down = null;
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _down = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      behavior: HitTestBehavior.opaque,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 5,
        clipBehavior: Clip.none,
        child: Center(
          child: _AttachmentImage(
            sessionId: widget.sessionId,
            ref: widget.ref,
            fetcher: widget.fetcher,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}

enum _AttachmentPhase { loading, error, loaded }

/// 图片加载组件:经 AttachmentFetchView 拉取 → loading/error/loaded 三态;
/// 失败显式重试(常规 ≥44dp 按钮;网格方块内用紧凑 icon,方块本身即触控目标)。
class _AttachmentImage extends StatefulWidget {
  const _AttachmentImage({
    required this.sessionId,
    required this.ref,
    required this.fetcher,
    required this.fit,
    this.alignment = Alignment.center,
    this.compactRetry = false,
  });
  final String sessionId;
  final ImageAttachmentRef ref;
  final AttachmentFetchView fetcher;
  final BoxFit fit;
  final Alignment alignment;
  final bool compactRetry;

  @override
  State<_AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<_AttachmentImage> {
  _AttachmentPhase _phase = _AttachmentPhase.loading;
  Uint8List? _bytes;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gen = ++_generation;
    setState(() {
      _phase = _AttachmentPhase.loading;
      _bytes = null;
    });
    try {
      final result =
          await widget.fetcher.fetch(widget.sessionId, widget.ref.attachmentId);
      if (!mounted || gen != _generation) return;
      setState(() {
        _bytes = result.bytes;
        _phase = _AttachmentPhase.loaded;
      });
    } catch (_) {
      if (!mounted || gen != _generation) return;
      setState(() => _phase = _AttachmentPhase.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _AttachmentPhase.loading:
        return const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _AttachmentPhase.error:
        return _RetryButton(
          onRetry: _load,
          compact: widget.compactRetry,
        );
      case _AttachmentPhase.loaded:
        return Image.memory(
          _bytes!,
          fit: widget.fit,
          alignment: widget.alignment,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, __, ___) => _RetryButton(
            onRetry: _load,
            compact: widget.compactRetry,
          ),
        );
    }
  }
}

/// 失败重试:常规 FilledButton(≥44dp,常显);compact 为网格方块内 icon(方块 ≥44dp)。
class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onRetry, this.compact = false});
  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Semantics(
        button: true,
        label: '图片加载失败,重试',
        child: Tooltip(
          message: '重试加载',
          child: InkWell(
            onTap: onRetry,
            child: Center(
              child: Icon(
                Icons.refresh,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }
    return Center(
      child: Semantics(
        button: true,
        label: '图片加载失败,重试',
        child: ConstrainedBox(
          key: const ValueKey<String>('attachment-retry'),
          constraints: const BoxConstraints(
            minWidth: 120,
            minHeight: kAttachmentMinTouch,
          ),
          child: FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
          ),
        ),
      ),
    );
  }
}
