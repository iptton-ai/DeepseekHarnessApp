// SessionStateDot — 会话行状态点(复刻 dsh web ui-primitives StateDot)。
//
// web 规格(packages/client/ui-primitives/src/StateDot.tsx + .module.css):
// - ongoing:3×3 像素矩阵的外圈 8 格顺时针「追逐」;每格亮度是阶梯保持
//   (1 → 0.6 → 0.35 → 0.15,不补间),周期 1s、步进 125ms;蓝
//   rgb(86,134,254)。
// - 实心态(done/warning/error):10% 同色 halo + 60% 直径实心核。
// 本端色彩从 web design token 平移:success rgb(34,197,94)、warn
// rgb(245,158,11)、error 明 rgb(236,19,19)/暗 rgb(242,90,90)。
import 'package:flutter/material.dart';

import 'package:singleman/sessions/session_attention_store.dart';

/// 追逐动画的 8 个外圈格(10 单位坐标系,自左上角顺时针)。
const List<(double, double)> _kMatrixCells = [
  (0, 0), (4, 0), (8, 0), (8, 4), (8, 8), (4, 8), (0, 8), (0, 4),
];

/// web ongoing 蓝(static-deepseek-450)。
const Color kDotRunningColor = Color(0xFF5686FE);

/// web success 绿(unread 未读点同色)。
const Color kDotUnreadColor = Color(0xFF22C55E);

/// web warn 琥珀(待审批/待问答)。
const Color kDotNeedsInputColor = Color(0xFFF59E0B);

/// 明/暗主题的 error 红(web red-600 / red-400)。
Color kDotErrorColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFFF25A5A)
    : const Color(0xFFEC1313);

/// 会话行 18dp 前置槽的状态点;idle 不渲染(保持标题左缘对齐)。
class SessionStateDot extends StatelessWidget {
  const SessionStateDot({
    super.key,
    required this.status,
    this.size = 14,
  });

  final SessionRowStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case SessionRowStatus.idle:
        return const SizedBox.shrink();
      case SessionRowStatus.running:
        return SessionPixelChaseDot(size: size, color: kDotRunningColor);
      case SessionRowStatus.unread:
        return _HaloDot(size: size, color: kDotUnreadColor);
      case SessionRowStatus.needsInput:
        return _HaloDot(size: size, color: kDotNeedsInputColor);
      case SessionRowStatus.error:
        return _HaloDot(
          size: size,
          color: kDotErrorColor(Theme.of(context).brightness),
        );
    }
  }
}

/// 实心态:10% 同色 halo + 60% 直径实心核(web .dot ::before/::after)。
class _HaloDot extends StatelessWidget {
  const _HaloDot({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: size * 0.6,
          height: size * 0.6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// ongoing 像素追逐:单个 1s 线性循环 AnimationController 驱动 CustomPaint,
/// 每格按「自峰值起算的相位」查阶梯亮度表(web keyframes 的等价闭式)。
/// 公开类型:测试用它精确断言「running 行渲染追逐动画」。
class SessionPixelChaseDot extends StatefulWidget {
  const SessionPixelChaseDot({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  State<SessionPixelChaseDot> createState() => _SessionPixelChaseDotState();
}

class _SessionPixelChaseDotState extends State<SessionPixelChaseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(widget.size),
      painter: _ChasePainter(animation: _controller, color: widget.color),
    );
  }
}

class _ChasePainter extends CustomPainter {
  _ChasePainter({required this.animation, required this.color})
      : super(repaint: animation);

  final Animation<double> animation;
  final Color color;

  /// 阶梯亮度(web dsh-state-dot-chase:0–12.4% → 1,12.5–24.9% → 0.6,
  /// 25–37.4% → 0.35,37.5–100% → 0.15)。
  static const List<double> _steps = [1.0, 0.6, 0.35, 0.15];

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 10;
    final t = animation.value;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false; // web shapeRendering=crispEdges
    for (var i = 0; i < _kMatrixCells.length; i++) {
      final (x, y) = _kMatrixCells[i];
      // 相位:距该格峰值已走过的周期占比(web 负 animationDelay 的等价)。
      final phase = (t - i / _kMatrixCells.length) % 1.0;
      final step = (phase * 4).floor().clamp(0, 3);
      canvas.drawRect(
        Rect.fromLTWH(x * unit, y * unit, 2 * unit, 2 * unit),
        paint..color = color.withValues(alpha: _steps[step]),
      );
    }
  }

  @override
  bool shouldRepaint(_ChasePainter oldDelegate) => oldDelegate.color != color;
}
