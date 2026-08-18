// 移动端「会话需要关注」提醒(M5):
// - 非当前会话的审批/问答**不再**就地弹卡(交互卡只渲染当前会话的,
//   见 _InteractorPane 门控);到达时经 SessionAttentionStore.attentionArrivals
//   广播 → 本 watcher 在移动形态(窄屏)振动 3 秒并弹**唯一**聚合 dialog。
// - 多个待关注会话汇入同一个 dialog(列表实时增减);点条目直接切过去,
//   交互卡随即在该会话内就地渲染。全部 resolved → dialog 自动收起。
// - 宽屏(桌面形态)不振动不弹窗:侧栏琥珀点 + hover 标题已足够。
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:singleman/sessions/session_attention_store.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/session_state_dot.dart';
import 'package:singleman/ui/workspace_browser.dart' show sessionDisplayTitle;

/// 振动器抽象(测试注入假实现;生产 = HapticFeedback 脉冲串)。
abstract class AttentionVibrator {
  void vibrate3s();
}

/// 生产振动:移动平台(Android/iOS/OHOS)上以 ~350ms 节奏脉冲
/// HapticFeedback.vibrate 约 3 秒;桌面平台为 no-op。重复触发重启脉冲窗。
class HapticAttentionVibrator implements AttentionVibrator {
  Timer? _timer;
  int _pulses = 0;

  @visibleForTesting
  static bool get mobilePlatform =>
      Platform.isAndroid || Platform.isIOS || Platform.operatingSystem == 'ohos';

  static const int _kPulses = 9;
  static const Duration _kInterval = Duration(milliseconds: 350);

  @override
  void vibrate3s() {
    _timer?.cancel();
    if (!mobilePlatform) return;
    _pulses = 0;
    _timer = Timer.periodic(_kInterval, (t) {
      HapticFeedback.vibrate();
      _pulses += 1;
      if (_pulses >= _kPulses) {
        t.cancel();
        _timer = null;
      }
    });
    HapticFeedback.vibrate(); // leading:窗口起点立即震动
  }

  /// 停止脉冲(dispose 时调用,防泄漏)。
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// 包在 ChatScreen 两形态外:enabled(移动形态)才对到达事件作出反应。
class SessionAttentionWatcher extends StatefulWidget {
  const SessionAttentionWatcher({
    super.key,
    required this.vm,
    required this.enabled,
    required this.child,
    this.vibrator,
  });

  final ChatViewModel vm;
  final bool enabled;
  final Widget child;
  final AttentionVibrator? vibrator;

  @override
  State<SessionAttentionWatcher> createState() => _SessionAttentionWatcherState();
}

class _SessionAttentionWatcherState extends State<SessionAttentionWatcher> {
  StreamSubscription<String>? _arrivalSub;
  bool _dialogOpen = false;
  AttentionVibrator? _ownedVibrator;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant SessionAttentionWatcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vm.attention != widget.vm.attention) _subscribe();
  }

  void _subscribe() {
    _arrivalSub?.cancel();
    _arrivalSub = widget.vm.attention?.attentionArrivals.listen(_onArrival);
  }

  void _onArrival(String sessionId) {
    if (!mounted || !widget.enabled) return;
    final vibrator = widget.vibrator ?? (_ownedVibrator ??= HapticAttentionVibrator());
    if (_dialogOpen) {
      // dialog 已开:新条目经 ListenableBuilder 汇入,不再重复振动。
      return;
    }
    vibrator.vibrate3s();
    _dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _SessionAttentionDialog(vm: widget.vm),
    ).whenComplete(() {
      _dialogOpen = false;
    });
  }

  @override
  void dispose() {
    _arrivalSub?.cancel();
    if (_ownedVibrator is HapticAttentionVibrator) {
      (_ownedVibrator as HapticAttentionVibrator).stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 聚合弹窗:非当前会话的待审批/待问答列表;实时增减,空了自收。
class _SessionAttentionDialog extends StatefulWidget {
  const _SessionAttentionDialog({required this.vm});

  final ChatViewModel vm;

  @override
  State<_SessionAttentionDialog> createState() => _SessionAttentionDialogState();
}

class _SessionAttentionDialogState extends State<_SessionAttentionDialog> {
  @override
  Widget build(BuildContext context) {
    final attention = widget.vm.attention;
    final colors = Theme.of(context).colorScheme;
    if (attention == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: attention,
      builder: (context, _) {
        final entries = attention
            .pendingInputSessions()
            .where((id) => id != widget.vm.selectedId)
            .toList();
        if (entries.isEmpty) {
          // 全部 resolved / 被其它端处理:自动收起(下一帧执行,避免
          // build 内 pop 的重入断言)。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
        }
        return AlertDialog(
          title: const Text('需要你的关注'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final id in entries)
                _AttentionEntry(
                  vm: widget.vm,
                  attention: attention,
                  sessionId: id,
                ),
              if (entries.isEmpty)
                Text('暂无待处理事项', style: TextStyle(color: colors.onSurfaceVariant)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('稍后处理'),
            ),
          ],
        );
      },
    );
  }
}

class _AttentionEntry extends StatelessWidget {
  const _AttentionEntry({
    required this.vm,
    required this.attention,
    required this.sessionId,
  });

  final ChatViewModel vm;
  final SessionAttentionStore attention;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasApproval = attention.hasPendingApproval(sessionId);
    final hasQuestion = attention.hasPendingQuestion(sessionId);
    final detail = hasApproval && hasQuestion
        ? '等待审批与回答'
        : (hasApproval ? '等待审批' : '等待回答');
    String title = sessionId;
    for (final s in vm.sessions) {
      if (s.sessionId == sessionId) {
        title = sessionDisplayTitle(s);
        break;
      }
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      leading: const SessionStateDot(
        status: SessionRowStatus.needsInput,
        size: 16,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(detail, style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
      onTap: () {
        Navigator.of(context).pop();
        vm.select(sessionId);
      },
    );
  }
}
