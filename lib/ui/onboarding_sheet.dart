// WelcomeOnboarding — W3-C 首用三步引导(底部 sheet 流)。
//
// 复刻(docs/audit/conversation.md §2 设置外壳 onboarding + sidebar-layout.md
// §7 primitives OnboardingSurface):首次使用引导逐步骤挂载,应用根节点 inert;
// 完成/关闭后不再出现。
//
// 状态持久化(docs/audit/conversation.md §2/§3 + 活体 describe 实证):
// - settings 命名空间 "ui-onboarding" 的 welcomeNoticeVersion 字段
//   (活体当前值 "2026-08-13.1" → kWelcomeNoticeVersion)
// - 用户值 == 当前版本 → 已看过,不再显示;sheet 以任意方式关闭(完成按钮/
//   点背板/下拉)后由 maybeShow 统一后台写一次该版本(不阻塞关闭)
// - 读写经注入薄通道 OnboardingChannel(集成方用 SettingsStore.scope('ui-onboarding')
//   适配:snapshot 读 value.welcomeNoticeVersion、setField 写、load 重读)
// - 读失败(未加载/LAN 403)→ 降级本地:默认显示;写失败本地标记兜底,
//   本会话不再出现
//
// 形态与移动硬性:
// - 底部 sheet(showModalBottomSheet);窄屏(<600dp)步骤内容全屏化
//   (高度 ≈92% 屏),宽屏限高 420 居中内容
// - 步骤间进度点;上一步/下一步(末步「完成」即关闭)——按钮路径零 await
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';

/// 当前欢迎公告版本(与活体 ui-onboarding.welcomeNoticeVersion 值对齐)。
/// 用户值等于该版本 → 公告已看过,不再显示。
const String kWelcomeNoticeVersion = '2026-08-13.1';

/// WelcomeOnboarding 依赖的薄 onboarding 通道(集成方用
/// SettingsStore.scope('ui-onboarding') 适配;LAN 读失败 → welcomeVersion null)。
abstract class OnboardingChannel {
  /// ui-onboarding.welcomeNoticeVersion 当前用户值(未加载/读失败 → null)。
  String? get welcomeVersion;

  /// 显式重读(读失败向上抛,调用方按「降级本地」处理)。
  Future<void> load();

  /// 写 welcomeNoticeVersion(disable 不再提示);成功 true,失败 false。
  Future<bool> setWelcomeVersion(String version);
}

/// 首用引导控制器:持有会话内本地「不再提示」标记 + 薄通道读写。
/// 集成方在 app 启动处构造一个,调 [maybeShowWelcomeOnboarding] 弹出。
class WelcomeOnboardingController {
  WelcomeOnboardingController(this.channel);

  final OnboardingChannel channel;
  bool _localDismissed = false;

  /// 会话内本地已关(写失败兜底,本会话不再出现)。
  bool get isDismissed => _localDismissed;

  /// 是否应弹出:本地已关 → false;读不到(降级本地)→ true;
  /// 否则已看过(版本匹配)→ false。
  Future<bool> shouldShow() async {
    if (_localDismissed) return false;
    String? stored;
    try {
      if (channel.welcomeVersion == null) await channel.load();
      stored = channel.welcomeVersion;
    } catch (_) {
      stored = null; // 读失败 → 降级本地。
    }
    if (stored == null) return true;
    return stored != kWelcomeNoticeVersion;
  }

  /// 「不再提示」/「完成」:写 settings;失败 → 本地标记兜底(本会话不重现)。
  Future<bool> dismiss() async {
    _localDismissed = true;
    try {
      return await channel.setWelcomeVersion(kWelcomeNoticeVersion);
    } catch (_) {
      return false;
    }
  }
}

/// 检查并弹出首用引导(底部 sheet);已看过/本地已关 → 不弹。
///
/// [onFinished] 在引导关闭后回调(集成方清除首个启动标记/统计)。
Future<void> maybeShowWelcomeOnboarding(
  BuildContext context, {
  required WelcomeOnboardingController controller,
  VoidCallback? onFinished,
}) async {
  final show = await controller.shouldShow();
  if (!show || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (context) => WelcomeOnboarding(controller: controller),
  );
  // sheet 以任意方式关闭(完成按钮/点背板/下拉)→ 后台写一次「已看」版本。
  // 不在按钮点击路径里 await 网络写:此前先写后关,首连未就绪时写挂起,
  // 「完成/不再提示」看起来点了没反应。写失败由控制器本地兜底。
  unawaited(controller.dismiss());
  onFinished?.call();
}

/// 三步引导 sheet 体:欢迎(双形态)→ 连接形态提示 → 完结。
class WelcomeOnboarding extends StatefulWidget {
  const WelcomeOnboarding({super.key, required this.controller});

  final WelcomeOnboardingController controller;

  @override
  State<WelcomeOnboarding> createState() => _WelcomeOnboardingState();
}

class _Step {
  const _Step(this.eyebrow, this.icon, this.title, this.body, this.tags);
  final String eyebrow;
  final IconData icon;
  final String title;
  final String body;
  final List<String> tags;
}

const List<_Step> _steps = <_Step>[
  _Step(
    '你的 AI 工作台',
    Icons.auto_awesome,
    '欢迎使用 DshAPP',
    'DshAPP 是 dsh 桌面 GUI 的 Flutter 客户端,支持桌面与移动双形态。'
        '桌面端提供完整工作区与设置能力;移动端为触控优化,常用操作一触即达,'
        '两个形态共用同一份会话与配置。',
    ['桌面 + 移动', '会话同步', '触控优化'],
  ),
  _Step(
    '连接，清晰可控',
    Icons.lan_outlined,
    '连接形态',
    '本机连接(loopback)解锁全部功能,包括设置、凭据与模型配置。'
        '局域网(LAN)连接保留核心聊天、审批与队列能力,'
        '特权面板(设置/凭据/目录选择)自动隐藏,连接前请确认信任围栏。',
    ['loopback · 全功能', 'LAN · 核心能力', '信任围栏'],
  ),
  _Step(
    '准备就绪',
    Icons.flag_outlined,
    '开始使用',
    '创建或选择一个会话即可开始对话;侧栏可切换工作区,'
        '右上角可随时进入设置调整外观、连接与模型。祝使用愉快!',
    ['选择会话', '切换工作区', '随时调整'],
  ),
];

class _WelcomeOnboardingState extends State<WelcomeOnboarding> {
  int _index = 0;

  bool get _isLast => _index == _steps.length - 1;

  void _next() {
    if (_isLast) {
      // 关闭即完成;版本持久化由 maybeShow 在 sheet 关闭后统一收口
      // (点击路径零 await,网络写慢/挂起也不影响关闭)。
      Navigator.of(context).pop();
    } else {
      setState(() => _index += 1);
    }
  }

  void _back() {
    if (_index == 0) return;
    setState(() => _index -= 1);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final step = _steps[_index];
    // 断点用 LayoutBuilder 的实际约束(不依赖 MediaQuery.size —— 本 SDK 的
    // setSurfaceSize 只改布局约束,MediaQuery 会报旧值;与 ChatScreen 同模式)。
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 600;
          final content = Container(
            key: const ValueKey('onboarding-sheet-content'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.surface,
                  Color.alphaBlend(
                    scheme.primary.withValues(alpha: .045),
                    scheme.surface,
                  ),
                ],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
            child: _buildContent(context, scheme, step),
          );
          // 移动硬性:窄屏步骤内容全屏化(≈92% 可用高,内容区滚动);
          // 宽屏限高居中内容。
          return isNarrow
              ? SizedBox(
                  key: const ValueKey('onboarding-sheet'),
                  height: constraints.maxHeight * 0.92,
                  child: content,
                )
              : ConstrainedBox(
                  key: const ValueKey('onboarding-sheet'),
                  constraints: const BoxConstraints(maxHeight: 520),
                  child: content,
                );
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme scheme, _Step step) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 拖拽条(触屏语义)。
        Align(
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: scheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: Image.asset(
                'assets/singleman_icon_master.png',
                width: 30,
                height: 30,
                filterQuality: FilterQuality.high,
              ),
            ),
            const SizedBox(width: 9),
            Text(
              'DshAPP',
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: -.2,
              ),
            ),
            const Spacer(),
            Text(
              '${(_index + 1).toString().padLeft(2, '0')} / ${_steps.length.toString().padLeft(2, '0')}',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildVisual(scheme, step),
                const SizedBox(height: 20),
                Text(
                  step.eyebrow.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.7,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  step.title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 27,
                    height: 1.1,
                    letterSpacing: -.8,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  step.body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.55,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final tag in step.tags) _buildTag(scheme, tag),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        // 进度点。
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [for (var i = 0; i < _steps.length; i++) _dot(scheme, i)],
        ),
        const SizedBox(height: 14),
        // 按钮行:上一步 / 下一步(末步「完成」)。单一 CTA ——
        // sheet 本就每版本只弹一次,「不再提示」与「完成」语义重复,已删。
        Row(
          children: [
            if (_index > 0)
              TextButton(
                key: const ValueKey('onboarding-back'),
                onPressed: _back,
                child: const Text('上一步'),
              )
            else
              const SizedBox(width: 64),
            const Spacer(),
            FilledButton(
              key: const ValueKey('onboarding-next'),
              onPressed: _next,
              child: Text(_isLast ? '完成' : '下一步'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVisual(ColorScheme scheme, _Step step) {
    final accent = _index == 1 ? scheme.tertiary : scheme.primary;
    return SizedBox(
      height: 154,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: accent.withValues(alpha: .18)),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    accent.withValues(alpha: .16),
                    scheme.primary.withValues(alpha: .04),
                  ],
                ),
              ),
            ),
          ),
          Positioned(top: -36, right: -18, child: _glowCircle(accent, 110)),
          Positioned(
            bottom: -46,
            left: -28,
            child: _glowCircle(scheme.primary, 118),
          ),
          Center(
            child: Container(
              width: 94,
              height: 94,
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: accent.withValues(alpha: .4)),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: .24),
                    blurRadius: 26,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(21),
                child: Image.asset(
                  'assets/singleman_icon_master.png',
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            top: 15,
            child: Text(
              'DSHAPP / CORE',
              style: TextStyle(
                color: scheme.onSurfaceVariant.withValues(alpha: .82),
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Positioned(
            right: 15,
            bottom: 14,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .16),
                shape: BoxShape.circle,
                border: Border.all(color: accent.withValues(alpha: .28)),
              ),
              child: Icon(step.icon, size: 19, color: accent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _glowCircle(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [color.withValues(alpha: .19), color.withValues(alpha: 0)],
      ),
    ),
  );

  Widget _buildTag(ColorScheme scheme, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest.withValues(alpha: .58),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: scheme.outlineVariant.withValues(alpha: .48)),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _dot(ColorScheme scheme, int i) {
    final active = i == _index;
    return AnimatedContainer(
      key: ValueKey('onboarding-dot-$i'),
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      width: active ? 18 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: active ? scheme.primary : scheme.outlineVariant,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}
