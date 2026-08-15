// WelcomeOnboarding — W3-C 首用三步引导(底部 sheet 流)。
//
// 复刻(docs/audit/conversation.md §2 设置外壳 onboarding + sidebar-layout.md
// §7 primitives OnboardingSurface):首次使用引导逐步骤挂载,应用根节点 inert;
// 完成/关闭后不再出现。
//
// 状态持久化(docs/audit/conversation.md §2/§3 + 活体 describe 实证):
// - settings 命名空间 "ui-onboarding" 的 welcomeNoticeVersion 字段
//   (活体当前值 "2026-08-13.1" → kWelcomeNoticeVersion)
// - 用户值 == 当前版本 → 已看过,不再显示;「不再提示」/「完成」写该版本
// - 读写经注入薄通道 OnboardingChannel(集成方用 SettingsStore.scope('ui-onboarding')
//   适配:snapshot 读 value.welcomeNoticeVersion、setField 写、load 重读)
// - 读失败(未加载/LAN 403)→ 降级本地:默认显示,「不再提示」本地标记兜底,
//   本会话不再出现
//
// 形态与移动硬性:
// - 底部 sheet(showModalBottomSheet);窄屏(<600dp)步骤内容全屏化
//   (高度 ≈92% 屏),宽屏限高 420 居中内容
// - 步骤间进度点;上一步/下一步/完成;每步可「不再提示」
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
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (context) =>
        WelcomeOnboarding(controller: controller, onFinished: onFinished),
  );
}

/// 三步引导 sheet 体:欢迎(双形态)→ 连接形态提示 → 完结。
class WelcomeOnboarding extends StatefulWidget {
  const WelcomeOnboarding({
    super.key,
    required this.controller,
    this.onFinished,
  });

  final WelcomeOnboardingController controller;
  final VoidCallback? onFinished;

  @override
  State<WelcomeOnboarding> createState() => _WelcomeOnboardingState();
}

class _Step {
  const _Step(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}

const List<_Step> _steps = <_Step>[
  _Step(
    Icons.auto_awesome,
    '欢迎使用 singleman',
    'singleman 是 dsh 桌面 GUI 的 Flutter 客户端,支持桌面与移动双形态。'
        '桌面端提供完整工作区与设置能力;移动端为触控优化,常用操作一触即达,'
        '两个形态共用同一份会话与配置。',
  ),
  _Step(
    Icons.lan_outlined,
    '连接形态',
    '本机连接(loopback)解锁全部功能,包括设置、凭据与模型配置。'
        '局域网(LAN)连接保留核心聊天、审批与队列能力,'
        '特权面板(设置/凭据/目录选择)自动隐藏,连接前请确认信任围栏。',
  ),
  _Step(
    Icons.flag_outlined,
    '开始使用',
    '创建或选择一个会话即可开始对话;侧栏可切换工作区,'
        '右上角可随时进入设置调整外观、连接与模型。祝使用愉快!',
  ),
];

class _WelcomeOnboardingState extends State<WelcomeOnboarding> {
  int _index = 0;
  bool _busy = false;

  bool get _isLast => _index == _steps.length - 1;

  void _next() {
    if (_isLast) {
      _finish();
    } else {
      setState(() => _index += 1);
    }
  }

  void _back() {
    if (_index == 0) return;
    setState(() => _index -= 1);
  }

  /// 「不再提示」/「完成」:写 settings(失败本地兜底)后关闭。
  Future<void> _finish() async {
    if (_busy) return;
    _busy = true;
    await widget.controller.dismiss();
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onFinished?.call();
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
          final content = Padding(
            key: const ValueKey('onboarding-sheet-content'),
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
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
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: content,
                );
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme scheme, _Step step) {
    return Column(
      mainAxisSize: MainAxisSize.min,
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
        const SizedBox(height: 20),
        Icon(step.icon, size: 44, color: scheme.primary),
        const SizedBox(height: 14),
        Text(
          step.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 12),
        Flexible(
          child: SingleChildScrollView(
            child: Text(
              step.body,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 进度点。
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [for (var i = 0; i < _steps.length; i++) _dot(scheme, i)],
        ),
        const SizedBox(height: 16),
        // 按钮行:上一步 / 不再提示 / 下一步(完成)。
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
            TextButton(
              key: const ValueKey('onboarding-dismiss'),
              onPressed: _finish,
              child: const Text('不再提示'),
            ),
            const SizedBox(width: 4),
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
