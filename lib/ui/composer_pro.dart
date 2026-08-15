// UpgradeComposer — W2-A composer 升级(独立交付组件,不动 _Composer)。
//
// 集成方摆放:替换 lib/ui/chat_screen.dart 里 _Composer 的位置(消息流下方、
// 交互面板下方),传入当前会话的 running / canSend(取自 ChatViewModel 与
// SessionSummary.running)与回调束。回调契约见文件尾「集成契约」。
//
// 行为(W2-A 规格):
// - 多行输入:移动端回车换行(全按钮化,无 busyEnter 快捷键依赖);
//   桌面保留 Enter 发送(W1 语义延续)
// - 动作区常显按钮(≥48dp):发送(mode queue)/ 运行中变「插话」(mode steer,
//   steer-unavailable 等拒绝原因内联提示)/「停止」(调注入的 onCancel);
//   canSend=false 时整体置灰
// - 斜杠命令检测:文本以 '/' 开头 → 输入框上方出现命令菜单占位(本体由 W2-D
//   经 commandMenu 注入;未注入时显示内置占位条);query 经 onCommandIntent 上抛
// - 图片附件栏占位:W2-C 的 AttachmentRail 由集成方经 attachmentsSlot 注入;
//   拾取意图经 onPickImages 上抛
// - 发送失败:内联错误(role=alert,文案经 promptErrorMessage 映射),保留输入可
//   重试;成功清空输入
import 'package:flutter/material.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/sessions/prompt_modes.dart';

/// 从发送异常提取业务错误码;非业务异常返回 null(走兜底文案)。
///
/// 业务错误在 ApiClient 折叠为 [RpcBusinessError],其 error 是生成的 sealed
/// RpcError;code 取 toJson 的 'code' 键(对 codegen 变化稳健)。
String? promptErrorCode(Object error) {
  if (error is RpcBusinessError) {
    final code = error.error.toJson()['code'];
    if (code is String) return code;
  }
  return null;
}

class UpgradeComposer extends StatefulWidget {
  const UpgradeComposer({
    super.key,
    required this.running,
    required this.canSend,
    required this.onSend,
    this.onCancel,
    this.onCommandIntent,
    this.onPickImages,
    this.commandMenu,
    this.attachmentsSlot,
    this.controller,
    this.hintText = '输入消息(移动端回车换行,发送靠按钮)',
  });

  /// 当前会话 running 状态(host/session-status 折叠而来;集成方从选中会话
  /// SessionSummary.running 取)。
  final bool running;

  /// 是否可发送(连接就绪 + 已选会话等;集成方从 ChatViewModel.canSend 取)。
  final bool canSend;

  /// 发送回调:steer=true 走 session.prompt mode:'steer'(插话),否则
  /// mode:'queue'。失败抛异常 → 内联错误(steer-unavailable / agent-busy 等)。
  final Future<void> Function(String text, {required bool steer}) onSend;

  /// 停止回调(对应 session.cancel;仅 running 且非空时渲染,非 running 禁用)。
  final VoidCallback? onCancel;

  /// 斜杠命令查询回调:文本以 '/' 开头时 query = '/' 后内容(trim);
  /// 退出斜杠态时回调 ''。随输入变化去重触发。
  final void Function(String query)? onCommandIntent;

  /// 图片拾取意图上抛(W2-C 的 AttachmentRail 经 [attachmentsSlot] 注入,
  /// 本体不实现拾取;集成方接此回调拉起 W2-C 的拾取流程)。
  final VoidCallback? onPickImages;

  /// W2-D 命令菜单本体(集成方注入;null 时显示内置占位条)。
  final Widget? commandMenu;

  /// W2-C AttachmentRail(集成方注入;显示在输入框上方、命令菜单下方)。
  final Widget? attachmentsSlot;

  /// 可选外部控制器(W2-D 选中命令后插入文本用;null 则内部自建并自管生命周期)。
  final TextEditingController? controller;

  final String hintText;

  @override
  State<UpgradeComposer> createState() => _UpgradeComposerState();
}

class _UpgradeComposerState extends State<UpgradeComposer> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  String? _error;
  bool _sending = false;
  String? _lastEmittedQuery;

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  String get _text => _controller.text;

  /// 斜杠查询:文本以 '/' 开头(允许前导空白)→ '/' 之后内容 trim;否则 null。
  String? get _slashQuery {
    final t = _text.trimLeft();
    if (!t.startsWith('/')) return null;
    return t.substring(1).trim();
  }

  bool get _slashActive => _slashQuery != null;

  /// 主按钮可用性:可发送 + 非空白 + 不在发送中。
  bool get _canPrimary =>
      widget.canSend && _text.trim().isNotEmpty && !_sending;

  void _onChanged(String _) {
    setState(() => _error = null); // 重新输入即清除旧错误
    _emitCommandIntent();
  }

  /// 斜杠查询变化才上抛(去重;退出斜杠态抛 '')。
  void _emitCommandIntent() {
    final q = _slashQuery ?? '';
    if (q == _lastEmittedQuery) return;
    _lastEmittedQuery = q;
    widget.onCommandIntent?.call(q);
  }

  Future<void> _send() async {
    if (_sending || !widget.canSend) return;
    final text = _text.trim();
    if (text.isEmpty) return;
    final steer = widget.running; // running → 插话,否则排队
    setState(() => _sending = true);
    try {
      await widget.onSend(text, steer: steer);
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _error = null;
        _sending = false;
      });
      _emitCommandIntent(); // 清空后斜杠态退出,通知菜单关闭
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describeError(e);
        _sending = false;
      });
    }
  }

  String _describeError(Object e) {
    final code = promptErrorCode(e);
    final server = e is RpcBusinessError ? e.error.toJson()['message'] : null;
    final serverMessage = server is String && server.isNotEmpty ? server : null;
    if (code == null && serverMessage == null) {
      // 非业务异常:直出异常原文,便于排查。
      return '发送失败: ${e.toString()}';
    }
    return promptErrorMessage(code, serverMessage: serverMessage);
  }

  /// 移动端回车换行(全按钮化);桌面保留 Enter 发送(W1 语义延续)。
  void _onSubmitted(String _) {
    if (_isDesktop) _send();
  }

  bool get _isDesktop {
    switch (Theme.of(context).platform) {
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
      case TargetPlatform.ohos:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = PromptMode.forRunning(widget.running);
    final stopEnabled = widget.running && !_sending;
    final colors = theme.colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow.withValues(alpha: .96),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: widget.running
              ? colors.tertiary.withValues(alpha: .42)
              : colors.outlineVariant.withValues(alpha: .65),
        ),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .06),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_slashActive) _buildCommandMenu(theme),
          if (widget.attachmentsSlot != null) widget.attachmentsSlot!,
          TextField(
            key: const ValueKey('composer-input'),
            controller: _controller,
            enabled: widget.canSend,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            onChanged: _onChanged,
            onSubmitted: _onSubmitted,
            decoration: InputDecoration(
              hintText: widget.hintText,
              prefixIcon: Icon(
                Icons.edit_note_rounded,
                color: colors.primary,
                size: 20,
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          if (_error != null)
            Semantics(
              liveRegion: true,
              container: true,
              child: Container(
                key: const ValueKey('composer-error'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (widget.onPickImages != null)
                SizedBox(
                  height: 48,
                  width: 48,
                  child: IconButton(
                    key: const ValueKey('composer-attach'),
                    tooltip: '添加图片',
                    onPressed: widget.canSend ? widget.onPickImages : null,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                  ),
                ),
              const Spacer(),
              if (widget.onCancel != null) ...[
                SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    key: const ValueKey('composer-stop'),
                    onPressed: stopEnabled ? widget.onCancel : null,
                    icon: const Icon(Icons.stop, size: 20),
                    label: const Text('停止'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  key: const ValueKey('composer-send'),
                  onPressed: _canPrimary ? _send : null,
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    child: _sending
                        ? const SizedBox(
                            key: ValueKey('sending-spinner'),
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : Icon(
                            key: const ValueKey('send-icon'),
                            mode == PromptMode.steer
                                ? Icons.call_made
                                : Icons.send,
                          ),
                  ),
                  label: Text(mode.label),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(88, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 命令菜单占位:本体由 W2-D 经 commandMenu 注入;未注入时显示内置占位条。
  Widget _buildCommandMenu(ThemeData theme) {
    final placeholder = Container(
      key: const ValueKey('composer-command-menu'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        children: [
          Icon(
            Icons.keyboard_command_key,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '命令菜单(待 W2-D 接入): /${_slashQuery ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
    final menu = widget.commandMenu;
    if (menu == null) return placeholder;
    return KeyedSubtree(
      key: const ValueKey('composer-command-menu'),
      child: menu,
    );
  }
}

// ─── 集成契约 ────────────────────────────────────────────────────────────
// 回调签名:
//   onSend(String text, {required bool steer}) → Future<void>
//     - steer=true 时集成方调 session.prompt mode:'steer'(插话),否则 mode:'queue';
//     - 抛 RpcBusinessError(steer-unavailable/agent-busy 等)→ 组件内联展示映射文案;
//     - 成功返回后组件清空输入。
//   onCancel() → void               —— 集成方调 session.cancel(仅中止当前 turn)。
//   onCommandIntent(String query)   —— query='/' 后内容(trim);退出斜杠态回调 ''。
//   onPickImages() → void           —— 集成方拉起 W2-C 拾取流程,结果经 attachmentsSlot
//                                     的 AttachmentRail 回填展示。
// 摆放位置:chat_screen.dart _MessagePane 中 _Composer(vm:vm, controller:...) 处,
// 替换为 UpgradeComposer(running: <选中会话 running>, canSend: vm.canSend, ...)。
// W2-D 需要向输入框插入命令文本(选中 '/name' 后回填):集成方持有并传入
// controller 参数即可直接 controller.text = ... 注入。
