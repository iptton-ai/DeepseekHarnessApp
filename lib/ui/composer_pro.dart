// UpgradeComposer — W2-A composer 升级(独立交付组件,不动 _Composer)。
//
// 集成方摆放:替换 lib/ui/chat_screen.dart 里 _Composer 的位置(消息流下方、
// 交互面板下方),传入当前会话的 running / canSend(取自 ChatViewModel 与
// SessionSummary.running)与回调束。回调契约见文件尾「集成契约」。
//
// 行为(W2-A 规格 + web InputBar 对齐):
// - 上方行(可注入):当前工作区 chip(可切换)+ 工作模式 chip(Agent 预设,
//   会话开始后只读)—— 对齐 web conversation.hero.workspaceRow
// - 多行输入:移动端回车换行(全按钮化,无 busyEnter 快捷键依赖);
//   桌面保留 Enter 发送(W1 语义延续)
// - 底部工具行:左「+」添加命令 / 添加图片 / 权限切换 chip;右模型切换
//   chip / 发送 / 停止 —— 对齐 web InputBar.row(tools | trailing)
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
    this.hintText = '输入消息',
    // ── web InputBar 对齐(上方行:工作区 + 工作模式) ──
    this.workspaceLabel,
    this.onSwitchWorkspace,
    this.workModeLabel,
    this.workModeLocked = false,
    this.onSwitchWorkMode,
    // ── web InputBar 对齐(底部工具行:+ 命令 / 权限 / 模型) ──
    this.onAddCommand,
    this.permissionLabel,
    this.onSwitchPermission,
    this.modelLabel,
    this.onPickModel,
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

  // ── 上方行(web conversation.hero.workspaceRow 对齐) ──

  /// 当前工作区名(null = 集成方无工作区域 → 不渲染 chip)。
  final String? workspaceLabel;

  /// 打开工作区切换(web WorkspaceChip → workspace picker)。
  final VoidCallback? onSwitchWorkspace;

  /// 当前工作模式名(Agent 预设;null = 域不可用 → 不渲染 chip)。
  final String? workModeLabel;

  /// 会话已开始,预设固定(web:运行会话保持开始时的预设;chip 只读)。
  final bool workModeLocked;

  /// 打开工作模式选择(web conversation.hero.agentPreset)。
  final VoidCallback? onSwitchWorkMode;

  // ── 底部工具行(web InputBar.row 对齐) ──

  /// 「+」添加命令(web input.commands → 命令/技能/子智能体菜单)。
  final VoidCallback? onAddCommand;

  /// 当前访问模式/权限名(null = 集成方无命令域 → 不渲染 chip)。
  final String? permissionLabel;

  /// 打开权限选择(web PermissionSelect;/permission 斜杠命令落地)。
  final VoidCallback? onSwitchPermission;

  /// 当前模型名(null = 不渲染;空串渲染占位「模型」)。
  final String? modelLabel;

  /// 打开模型选择(web conversation.input.model slot)。
  final VoidCallback? onPickModel;

  @override
  State<UpgradeComposer> createState() => _UpgradeComposerState();
}

class _UpgradeComposerState extends State<UpgradeComposer> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();
  final _focus = FocusNode();
  String? _error;
  bool _sending = false;
  String? _lastEmittedQuery;

  @override
  void dispose() {
    _focus.dispose();
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
    // 发送恒走队列(web busyEnter 默认 queue):AI 运行中发消息进 Queue,
    // 想插话去队列 Dock 按每条的「插话」(session.updateQueue kind:steer)。
    setState(() => _sending = true);
    try {
      await widget.onSend(text, steer: false);
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
      return '发送失败: ' + e.toString();
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
    final stopEnabled = widget.running && !_sending;
    final colors = theme.colorScheme;
    final hasTopRow =
        widget.workspaceLabel != null || widget.workModeLabel != null;
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
          // web 对齐:输入框上方行(hero workspaceRow)—— 当前工作区 + 工作模式。
          if (hasTopRow) _buildTopRow(theme),
          if (_slashActive) _buildCommandMenu(theme),
          if (widget.attachmentsSlot != null) widget.attachmentsSlot!,
          // 输入区独立成行(web InputBar textarea + mirror)。
          TextField(
            key: const ValueKey('composer-input'),
            controller: _controller,
            focusNode: _focus,
            enabled: widget.canSend,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            onChanged: _onChanged,
            onSubmitted: _onSubmitted,
            decoration: InputDecoration(
              // placeholder 恒单行(用户诉求:长提示折两行把默认
              // 高度撑得太高)—— 用 hint widget 强制 maxLines:1 +
              // 省略号,hintText 字符串会跟随输入框 maxLines 折行。
              hint: Text(
                widget.hintText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: theme.hintColor,
                  fontSize: 15,
                ),
              ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // web 对齐:底部工具行(InputBar.row)—— 左侧「+」命令/图片/权限,
          // 右侧模型 + 发送/停止。
          _buildToolbarRow(theme, stopEnabled),
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
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 上方行:工作区 chip + 工作模式 chip(web heroWorkspaceRow 对齐)。
  Widget _buildTopRow(ThemeData theme) {
    final ws = widget.workspaceLabel;
    final mode = widget.workModeLabel;
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2, bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (ws != null)
            _ComposerChip(
              key: const ValueKey('composer-workspace'),
              icon: Icons.workspaces_outlined,
              label: ws,
              onTap: widget.onSwitchWorkspace,
            ),
          if (mode != null)
            _ComposerChip(
              key: const ValueKey('composer-workmode'),
              icon: Icons.tune,
              label: mode,
              locked: widget.workModeLocked,
              onTap: widget.onSwitchWorkMode,
            ),
        ],
      ),
    );
  }

  /// 底部工具行:左「+」命令/图片/权限,右模型/发送/停止(web InputBar.row)。
  ///
  /// 窄屏降级(用户诉求:宽度不足时只显示图标,绝不让文本穿透按钮/Row 溢出):
  /// 余量 ≥220 → chip 带文案;
  /// 余量 ≥100 → 权限/模型 chip 仅图标(完整名进 Tooltip);
  /// 更窄 → 模型 chip 隐藏 + 发送钮收成图标(Tooltip 补「发送」)。
  Widget _buildToolbarRow(ThemeData theme, bool stopEnabled) {
    final perm = widget.permissionLabel;
    final model = widget.modelLabel;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 固定元素宽度账本(与下方渲染分支一一对应,改动需同步):
        // 命令 48 / 图片 2+48 / 权限位 6 / 发送 80 / 模型位 6 / 停止 6+48。
        var fixed = 0.0;
        if (widget.onAddCommand != null) fixed += 48;
        if (widget.onPickImages != null) fixed += 50;
        if (perm != null) fixed += 6;
        fixed += 80;
        if (model != null) fixed += 6;
        if (widget.onCancel != null && widget.running) fixed += 54;
        final remaining = constraints.maxWidth - fixed;
        final chipsIconOnly = remaining < 220;
        final squeezeSend = remaining < 100;
        return Row(
          children: [
            if (widget.onAddCommand != null)
              _ToolIconButton(
                key: const ValueKey('composer-add-command'),
                tooltip: '命令',
                icon: Icons.add,
                onTap: widget.onAddCommand,
              ),
            if (widget.onPickImages != null) ...[
              const SizedBox(width: 2),
              _ToolIconButton(
                key: const ValueKey('composer-attach'),
                tooltip: '添加图片',
                icon: Icons.add_photo_alternate_outlined,
                onTap: widget.canSend ? widget.onPickImages : null,
              ),
            ],
            if (perm != null) ...[
              const SizedBox(width: 6),
              // 权限 chip 不进 Flexible:flex 份额会小于 chip 内在宽度,
              // 把内部 Row(不可收缩的图标/文本)压出溢出 —— 放得下与否
              // 由上面的余量分级保证。
              _ComposerChip(
                key: const ValueKey('composer-permission'),
                icon: _permissionIcon(perm),
                label: _permissionLabel(perm),
                onTap: widget.onSwitchPermission,
                compact: chipsIconOnly,
              ),
            ],
            const Spacer(),
            if (model != null && !squeezeSend)
              // 模型名可长:带文案时进 Flexible 让文本 ellipsize 收缩;
              // 仅图标形态内在宽度固定,同样不进 Flexible(份额平分问题)。
              chipsIconOnly
                  ? _ComposerChip(
                      key: const ValueKey('composer-model'),
                      icon: Icons.memory,
                      label: model.isEmpty ? '模型' : model,
                      onTap: widget.onPickModel,
                      compact: true,
                    )
                  : Flexible(
                      child: _ComposerChip(
                        key: const ValueKey('composer-model'),
                        icon: Icons.memory,
                        label: model.isEmpty ? '模型' : model,
                        onTap: widget.onPickModel,
                      ),
                    ),
            if (model != null && !squeezeSend) const SizedBox(width: 6),
            squeezeSend
                ? Tooltip(
                    message: '发送',
                    child: FilledButton(
                      key: const ValueKey('composer-send'),
                      onPressed: _canPrimary ? _send : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: _sendSwitcher(),
                    ),
                  )
                : FilledButton.icon(
                    key: const ValueKey('composer-send'),
                    onPressed: _canPrimary ? _send : null,
                    icon: _sendSwitcher(),
                    label: const Text('发送'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(80, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                  ),
            if (widget.onCancel != null && widget.running) ...[
              const SizedBox(width: 6),
              // 停止保持 48dp 方块(移动可用性硬性:触控目标 ≥48dp)。
              SizedBox(
                width: 48,
                height: 48,
                child: Tooltip(
                  message: '停止',
                  child: FilledButton(
                    key: const ValueKey('composer-stop'),
                    onPressed: stopEnabled ? widget.onCancel : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                      minimumSize: const Size(48, 48),
                      padding: EdgeInsets.zero,
                    ),
                    child: const Icon(Icons.stop, size: 22),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// 发送钮视觉:发送中转圈,平时纸飞机(带文案/极窄图标两形态共用)。
  Widget _sendSwitcher() => AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        child: _sending
            ? const SizedBox(
                key: ValueKey('sending-spinner'),
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : const Icon(
                key: ValueKey('send-icon'),
                Icons.send,
              ),
      );

  /// 权限值 → 图标(web permissionGlyph 对齐:按档位换盾形)。
  static IconData _permissionIcon(String value) {
    switch (value) {
      case 'read-only':
        return Icons.verified_user_outlined;
      case 'workspace-write':
        return Icons.edit_note_outlined;
      case 'danger-full-access':
        return Icons.gpp_maybe_outlined;
      default:
        return Icons.shield_outlined;
    }
  }

  /// 权限值 → 用户可读名(与 settings 页展示一致)。
  static String _permissionLabel(String value) {
    switch (value) {
      case 'default':
        return '默认';
      case 'read-only':
        return '只读';
      case 'workspace-write':
        return '工作区可写';
      case 'danger-full-access':
        return '完全访问';
      default:
        return value;
    }
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

/// composer 内的窄 chip(工作区/工作模式/权限/模型;web WorkspaceChip 与
/// PermissionSelect trigger 的移动端形态):图标 + 单行文本 + 尾随箭头,
/// [locked] 时箭头换成锁(web:会话开始后预设固定只读)。
///
/// [compact](窄屏降级):只显图标,文本/箭头/锁全部让位(完整名进 Tooltip)
/// —— 宽度不足时保住可点击性,绝不撑破工具行。
class _ComposerChip extends StatelessWidget {
  const _ComposerChip({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.locked = false,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool locked;

  /// 紧凑形态:仅图标(Tooltip 补全名)。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final chip = Material(
      color: colors.surfaceContainerHigh.withValues(alpha: .9),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 14 : 10,
            vertical: 7,
          ),
          child: ClipRect(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: colors.onSurfaceVariant),
                if (!compact) ...[
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: enabled
                            ? colors.onSurfaceVariant
                            : colors.onSurfaceVariant.withValues(alpha: .6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    locked ? Icons.lock_outline : Icons.keyboard_arrow_down,
                    size: 14,
                    color: colors.onSurfaceVariant.withValues(alpha: .7),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (compact) return Tooltip(message: label, child: chip);
    return chip;
  }
}

/// 底部工具行的方形图标按钮(「+」命令 / 添加图片);48dp 触控区
/// (移动可用性硬性:≥48dp,同发送/停止)。
class _ToolIconButton extends StatelessWidget {
  const _ToolIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 48,
      height: 48,
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          onPressed: onTap,
          icon: Icon(icon, size: 22),
          style: IconButton.styleFrom(
            foregroundColor: colors.onSurfaceVariant,
            backgroundColor: colors.surfaceContainerHigh.withValues(alpha: .9),
          ),
        ),
      ),
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