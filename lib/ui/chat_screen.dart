// ChatScreen — 会话主界面(W1 集成:workspace 分组侧栏 + 节点流 + jobs/subagent 入口 + 设置;
// <600dp 移动形态 = 抽屉侧栏,桌面 ≥600dp 保持双栏,见 PLAN「W1 集成规格」)。
// 只消费注入的 store 视图与 ChatViewModel,不含任何 socket/HTTP 逻辑。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/job_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/subagent_store.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/sessions/attachment_fetch.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/sessions/directory_store.dart';
import 'package:singleman/sessions/feedback_store.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/command_menu_sheet.dart';
import 'package:singleman/ui/composer_pro.dart';
import 'package:singleman/ui/directory_browse_sheet.dart';
import 'package:singleman/ui/node_widgets.dart';
import 'package:singleman/sessions/theme_store.dart';
import 'package:singleman/ui/theme_mode_row.dart';
import 'package:singleman/ui/trajectory_page.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/wire/generated/wire_generated.dart';
import 'package:singleman/ui/interactor_widgets.dart';
import 'package:singleman/ui/jobs_sheet.dart';
import 'package:singleman/ui/settings_screen.dart';
import 'package:singleman/ui/subagent_catalog.dart';
import 'package:singleman/ui/workspace_browser.dart';

/// 会话操作回调束(M4:模型/搜索/fork/导出/重命名;main 注入)。
class SessionActions {
  const SessionActions({
    this.onPickModel,
    this.onRename,
    this.onFork,
    this.onExport,
    this.onPickSkill,
  });
  final VoidCallback? onPickModel;
  final void Function(String sessionId, String title)? onRename;
  final void Function(String sessionId)? onFork;
  final void Function(String sessionId)? onExport;
  final void Function(String skillName)? onPickSkill;
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({
    super.key,
    required this.vm,
    this.onNewSession,
    this.actions,
    this.workspaces,
    this.jobs,
    this.subagents,
    this.settings,
    this.scope,
    this.commands,
    this.directory,
    this.attachments,
    this.feedback,
    this.theme,
    this.onCancelSession,
    this.onOpenGatewayLogin,
    this.gatewayLabel,
  });
  final ChatViewModel vm;
  final VoidCallback? onNewSession;
  final SessionActions? actions;

  // W1 域注入(均 optional:测试/过渡期可缺省)。
  final WorkspaceStoreView? workspaces;
  final JobStoreView? jobs;
  final SubagentStore? subagents;
  final SettingsStoreView? settings;
  final PrivilegeScope? scope;

  // W2 域注入。
  final CommandStoreView? commands;
  final DirectoryBrowserStore? directory;
  final AttachmentFetchView? attachments;

  // W3 域注入。
  final FeedbackStoreView? feedback;
  final ThemeStoreView? theme;
  final void Function(String sessionId)? onCancelSession;

  // M6 远程网关:侧栏常驻入口(不门控 —— 手机首启/桌面加远程都靠它)。
  final VoidCallback? onOpenGatewayLogin;
  final String? gatewayLabel;

  static const _kWideBreakpoint = 600.0;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: vm,
      builder: (context, _) {
        final sidebar = _Sidebar(
          vm: vm,
          onNewSession: onNewSession,
          actions: actions,
          workspaces: workspaces,
          settings: settings,
          scope: scope,
          directory: directory,
          theme: theme,
          onOpenGatewayLogin: onOpenGatewayLogin,
          gatewayLabel: gatewayLabel,
        );
        final pane = _MessagePane(
          vm: vm,
          jobs: jobs,
          subagents: subagents,
          commands: commands,
          attachments: attachments,
          feedback: feedback,
          onCancelSession: onCancelSession,
          onApproval: (a, allow) async {
            final it = vm.interactor;
            if (it == null) return;
            try {
              final receipt = await it.respondApproval(
                a.rpcId,
                a.sessionId,
                a.approvalId,
                allow: allow,
              );
              if (receipt.late) {
                _toast(context, '该审批已被处理(回复过期)');
              } else if (receipt.malformed) {
                _toast(context, '审批应答被拒绝: 响应格式问题');
              }
            } on Object catch (e) {
              _toast(context, '审批应答发送失败: ' + e.toString());
            }
          },
          onQuestion: (q, drafts) async {
            final it = vm.interactor;
            if (it == null) return '交互通道不可用';
            final err = it.validateQuestionAnswers(q, drafts);
            if (err != null) {
              return '应答不完整: ' + err;
            }
            final payload = drafts
                .map(
                  (d) => <String, dynamic>{
                    'id': d.questionId,
                    'selected': d.selected,
                    if (d.custom != null && d.custom!.isNotEmpty)
                      'custom': d.custom,
                  },
                )
                .toList();
            try {
              final receipt = await it.respondQuestions(
                q.rpcId,
                q.sessionId,
                payload,
              );
              if (receipt.late) return '该问题已被处理(回复过期)';
              if (receipt.malformed) return '应答被拒绝: 响应格式问题';
              return null;
            } on Object catch (e) {
              return '应答发送失败: ' + e.toString();
            }
          },
          onQueueRemove: null,
        );
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _kWideBreakpoint;
            if (wide) {
              return Scaffold(
                body: Row(
                  children: [
                    sidebar,
                    const VerticalDivider(width: 1),
                    Expanded(child: _ConversationBackdrop(child: pane)),
                  ],
                ),
              );
            }
            // 移动形态(<600dp):侧栏进抽屉,消息 pane 全屏。
            return Scaffold(
              appBar: AppBar(
                title: Row(
                  children: [
                    const _BrandMark(size: 28),
                    const SizedBox(width: 10),
                    const Text('singleman'),
                    const SizedBox(width: 10),
                    _PhaseBadge(vm: vm),
                  ],
                ),
                actions: [
                  if (onNewSession != null)
                    IconButton(
                      tooltip: '新建会话',
                      onPressed: onNewSession,
                      icon: const Icon(Icons.add),
                    ),
                ],
                leading: Builder(
                  builder: (context) {
                    return IconButton(
                      tooltip: '会话列表',
                      onPressed: () => Scaffold.of(context).openDrawer(),
                      icon: const Icon(Icons.menu),
                    );
                  },
                ),
              ),
              drawer: Drawer(width: 320, child: SafeArea(child: sidebar)),
              body: _ConversationBackdrop(child: pane),
            );
          },
        );
      },
    );
  }
}

class _Sidebar extends StatefulWidget {
  const _Sidebar({
    required this.vm,
    this.onNewSession,
    this.actions,
    this.workspaces,
    this.settings,
    this.scope,
    this.directory,
    this.theme,
    this.onOpenGatewayLogin,
    this.gatewayLabel,
  });
  final ChatViewModel vm;
  final VoidCallback? onNewSession;
  final SessionActions? actions;
  final WorkspaceStoreView? workspaces;
  final SettingsStoreView? settings;
  final PrivilegeScope? scope;
  final DirectoryBrowserStore? directory;
  final ThemeStoreView? theme;
  final VoidCallback? onOpenGatewayLogin;
  final String? gatewayLabel;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<SessionSummary> get _visible {
    if (_query.isEmpty) return widget.vm.sessions;
    final q = _query.toLowerCase();
    return widget.vm.sessions
        .where(
          (s) =>
              s.sessionId.toLowerCase().contains(q) ||
              (s.cwd ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 292,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(
            right: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .28),
            ),
          ),
        ),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const _BrandMark(),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'singleman',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text('AI 工作台', style: TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '新建会话',
                          onPressed: widget.onNewSession,
                          style: IconButton.styleFrom(
                            backgroundColor: colors.primary,
                            foregroundColor: colors.onPrimary,
                          ),
                          icon: const Icon(Icons.add, size: 20),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _PhaseBadge(vm: widget.vm),
                        const Spacer(),
                        if (widget.actions?.onPickModel != null)
                          IconButton(
                            tooltip: '选择模型',
                            onPressed: widget.actions!.onPickModel,
                            icon: const Icon(Icons.tune),
                          ),
                        if (widget.actions?.onPickSkill != null)
                          IconButton(
                            tooltip: '技能',
                            onPressed: () =>
                                widget.actions!.onPickSkill?.call(''),
                            icon: const Icon(Icons.bolt),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (widget.vm.phase == ConnectionPhase.down &&
                widget.vm.failureReason != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Text(
                  '断线原因: ' +
                      (widget.vm.failureReason!.length > 120
                          ? widget.vm.failureReason!.substring(0, 120) + '…'
                          : widget.vm.failureReason!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: '搜索会话或工作区',
                  prefixIcon: Icon(Icons.search, size: 18),
                  isDense: true,
                  suffixIcon: Icon(Icons.tune, size: 16),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const Divider(height: 1),
            // W2:添加工作区(应用内目录浏览,单列下钻;确认即 create)。
            if (widget.workspaces != null && widget.directory != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: () => showDirectoryBrowseSheet(
                    context,
                    store: widget.directory!,
                    onConfirm: (path) async {
                      // 确认即创建 workspace;失败 snackBar,成功由广播刷新浏览器。
                      try {
                        await widget.workspaces!.create(path);
                      } on Object catch (e) {
                        debugPrint('workspace create failed: ' + e.toString());
                      }
                    },
                  ),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('添加工作区', style: TextStyle(fontSize: 13)),
                ),
              ),
            // W1:workspace 分组浏览器(注入存在时显示;替代纯扁平列表的分组语义)。
            if (widget.workspaces != null)
              Expanded(
                child: WorkspaceBrowser(
                  store: widget.workspaces!,
                  sessionStream: widget.vm.summaries,
                  initialSessions: widget.vm.sessions,
                  selectedSessionId: widget.vm.selectedId,
                  query: _query,
                  callbacks: WorkspaceBrowserCallbacks(
                    onSelectSession: widget.vm.select,
                    onNewSession: (_) => widget.onNewSession?.call(),
                    onRenameSession: (id, title) =>
                        widget.actions?.onRename?.call(id, title),
                    onFork: (id) => widget.actions?.onFork?.call(id),
                    onArchive: (_) {},
                  ),
                ),
              ),
            if (widget.workspaces == null)
              Expanded(
                child: visible.isEmpty
                    ? _SidebarEmptyState(hasQuery: _query.isNotEmpty)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        itemCount: visible.length,
                        itemBuilder: (context, i) {
                          final s = visible[i];
                          final selected = s.sessionId == widget.vm.selectedId;
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
                            minVerticalPadding: 7,
                            selected: selected,
                            leading: Icon(
                              s.running
                                  ? Icons.autorenew
                                  : s.blank
                                  ? Icons.circle_outlined
                                  : Icons.chat_bubble_outline,
                              size: 18,
                            ),
                            title: Text(
                              s.projections != null &&
                                      s.projections!.values.isNotEmpty &&
                                      _titleOf(s) != null
                                  ? _titleOf(s)!
                                  : (s.sessionId.split('-')
                                          ..removeWhere((p) => p.isEmpty))
                                        .reversed
                                        .take(2)
                                        .toList()
                                        .reversed
                                        .join('-'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              s.cwd ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => widget.vm.select(s.sessionId),
                            trailing: _hasActions()
                                ? PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert, size: 16),
                                    itemBuilder: (context) => [
                                      if (widget.actions?.onRename != null)
                                        const PopupMenuItem(
                                          value: 'rename',
                                          child: Text('重命名'),
                                        ),
                                      if (widget.actions?.onFork != null)
                                        const PopupMenuItem(
                                          value: 'fork',
                                          child: Text('在此分叉'),
                                        ),
                                      if (widget.actions?.onExport != null)
                                        const PopupMenuItem(
                                          value: 'export',
                                          child: Text('导出 ZIP'),
                                        ),
                                    ],
                                    onSelected: (v) => _onMenu(v, s.sessionId),
                                  )
                                : null,
                          );
                        },
                      ),
              ),
            // M6:远程网关入口(常驻,不门控 —— 手机首启配置/桌面加远程/换网关)。
            if (widget.onOpenGatewayLogin != null) ...[
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('远程网关'),
                subtitle: Text(
                  widget.gatewayLabel ?? '点此登录配置',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: widget.onOpenGatewayLogin,
              ),
            ],
            // W1:设置入口(仅 loopback;PrivilegeScope 门控在组件内)。
            if (widget.settings != null && widget.scope != null) ...[
              const Divider(height: 1),
              SettingsEntryButton(
                scope: widget.scope!,
                store: widget.settings!,
              ),
            ],
            // W3-C:主题三选一(非 loopback 也可用 —— theme 经 settings 通道但本机回退 system)。
            if (widget.theme != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: ThemeModeRow(store: widget.theme!),
              ),
          ],
        ),
      ),
    );
  }

  bool _hasActions() =>
      widget.actions?.onRename != null ||
      widget.actions?.onFork != null ||
      widget.actions?.onExport != null;

  Future<void> _onMenu(String action, String sessionId) async {
    final actions = widget.actions;
    if (actions == null) return;
    switch (action) {
      case 'rename':
        final controller = TextEditingController();
        final title = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('重命名会话'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '新标题', isDense: true),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (title != null && title.trim().isNotEmpty) {
          actions.onRename?.call(sessionId, title.trim());
        }
      case 'fork':
        actions.onFork?.call(sessionId);
      case 'export':
        actions.onExport?.call(sessionId);
    }
  }

  String? _titleOf(s) {
    final values = s.projections?.values;
    if (values is Map && values['title'] is Map) {
      final t = values['title']['title'];
      if (t is String && t.isNotEmpty) return t;
    }
    return null;
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({this.size = 34});
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .3),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primary, colors.tertiary],
        ),
        boxShadow: [
          BoxShadow(
            color: colors.primary.withValues(alpha: .24),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Center(
        child: Text(
          's',
          style: TextStyle(
            color: colors.onPrimary,
            fontSize: size * .52,
            fontWeight: FontWeight.w900,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _ConversationBackdrop extends StatelessWidget {
  const _ConversationBackdrop({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _BackdropPainter(Theme.of(context).colorScheme)),
        child,
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.colors);
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    final wash = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [
          colors.primary.withValues(alpha: .07),
          colors.surface.withValues(alpha: .02),
          colors.tertiary.withValues(alpha: .045),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, wash);
    final dot = Paint()..color = colors.primary.withValues(alpha: .05);
    for (var x = 36.0; x < size.width; x += 48) {
      for (var y = 26.0; y < size.height; y += 48) {
        canvas.drawCircle(Offset(x, y), 1.1, dot);
      }
    }
    final glow = Paint()
      ..shader =
          RadialGradient(
            colors: [colors.primary.withValues(alpha: .09), Colors.transparent],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * .86, size.height * .08),
              radius: 220,
            ),
          );
    canvas.drawCircle(Offset(size.width * .86, size.height * .08), 220, glow);
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) =>
      oldDelegate.colors != colors;
}

class _SidebarEmptyState extends StatelessWidget {
  const _SidebarEmptyState({required this.hasQuery});
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasQuery ? Icons.search_off_rounded : Icons.forum_outlined,
            size: 30,
            color: colors.primary.withValues(alpha: .65),
          ),
          const SizedBox(height: 10),
          Text(
            hasQuery ? '没有找到匹配会话' : '还没有会话',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hasQuery ? '换个关键词试试' : '点击右上角 + 开始新的对话',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.vm});
  final ChatViewModel vm;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final Color color;
    final String label;
    switch (vm.phase) {
      case ConnectionPhase.ready:
        color = colors.tertiary;
        label = 'gen ${vm.generation}';
      case ConnectionPhase.connecting:
        color = colors.secondary;
        label = '连接中';
      case ConnectionPhase.down:
        color = colors.error;
        label = '已断开 · 重试中';
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: .86, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOut,
      builder: (context, scale, child) => Transform.scale(
        scale: scale,
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withValues(alpha: .2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.primary.withValues(alpha: .1),
                border: Border.all(
                  color: colors.primary.withValues(alpha: .16),
                ),
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 34,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '准备好开始了吗？',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              '选择一个会话，或从侧栏创建新的对话。\n你可以直接描述目标、粘贴代码，或使用 / 命令。',
              textAlign: TextAlign.center,
              style: TextStyle(height: 1.55, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: const [
                _HintPill(icon: Icons.code_rounded, label: '代码协作'),
                _HintPill(icon: Icons.lightbulb_outline_rounded, label: '想法梳理'),
                _HintPill(icon: Icons.task_alt_rounded, label: '任务执行'),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '选择或创建一个会话开始对话',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _HintPill extends StatelessWidget {
  const _HintPill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: colors.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _MessagePane extends StatelessWidget {
  const _MessagePane({
    required this.vm,
    this.onApproval,
    this.onQuestion,
    this.onQueueRemove,
    this.jobs,
    this.subagents,
    this.commands,
    this.attachments,
    this.feedback,
    this.onCancelSession,
  });
  final ChatViewModel vm;
  final JobStoreView? jobs;
  final SubagentStore? subagents;
  final CommandStoreView? commands;
  final AttachmentFetchView? attachments;
  final FeedbackStoreView? feedback;
  final void Function(String sessionId)? onCancelSession;
  final Future<void> Function(PendingApproval a, bool allow)? onApproval;
  final Future<String?> Function(PendingQuestion q, List<QuestionAnswerDraft> drafts)?
  onQuestion;
  final void Function(Map<String, dynamic> item)? onQueueRemove;

  @override
  Widget build(BuildContext context) {
    final sid = vm.selectedId;
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        // W1/W2:页头动作区(subagent 目录 + 后台任务 + 斜杠命令;无内容不渲染)。
        if (sid != null &&
            (jobs != null || subagents != null || commands != null))
          Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: .78),
              border: Border(
                bottom: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: .3),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.forum_outlined, size: 18, color: colors.primary),
                const SizedBox(width: 9),
                Text(
                  '对话工作台',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(width: 10),
                if (vm.selectedRunning)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.tertiary.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '处理中',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.tertiary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const Spacer(),
                if (subagents != null)
                  SubagentEntryButton(store: subagents!, parentSessionId: sid),
                if (jobs != null) JobsTrigger(store: jobs!, sessionId: sid),
                // W3:轨迹视图入口(整页推入;零新 RPC,纯 SessionLog 视图)。
                IconButton(
                  tooltip: '轨迹',
                  icon: const Icon(Icons.timeline),
                  onPressed: () {
                    final log = vm.logForSelected;
                    if (log == null) return;
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TrajectoryPage(
                          sessionId: sid,
                          events: log.events,
                          eventStream: log.eventStream,
                          onLoadOlder: () => vm.loadOlderSelected(),
                          hasOlder: vm.hasOlderSelected,
                        ),
                      ),
                    );
                  },
                ),
                if (commands != null)
                  IconButton(
                    tooltip: '命令',
                    icon: const Icon(Icons.terminal),
                    onPressed: () async {
                      await showCommandMenu(
                        context,
                        sessionId: sid,
                        store: commands!,
                        onPick: (line) async {
                          // 命令 → execute(预校验在 store 内);skill → prompt。
                          if (line.startsWith('/')) {
                            try {
                              await commands!.execute(sid, line);
                            } on Object catch (e) {
                              debugPrint('command failed: ' + e.toString());
                            }
                          }
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: vm.nodes.isNotEmpty
                ? ChatNodeList(
                    key: const ValueKey('node-list'),
                    nodes: vm.nodes,
                    sessionId: vm.selectedId,
                    attachmentFetcher: attachments,
                    feedbackStore: feedback,
                  )
                : (vm.bubbles.isEmpty
                      ? const _EmptyConversation(
                          key: ValueKey('empty-conversation'),
                        )
                      : ListView.builder(
                          key: const ValueKey('legacy-bubbles'),
                          padding: const EdgeInsets.all(12),
                          itemCount: vm.bubbles.length,
                          itemBuilder: (context, i) {
                            final b = vm.bubbles[i];
                            final isUser = b.role == 'user';
                            return Align(
                              alignment: isUser
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.78,
                                ),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: b.role == 'assistant'
                                    ? MarkdownBody(
                                        data: b.text,
                                        styleSheet:
                                            MarkdownStyleSheet.fromTheme(
                                              Theme.of(context),
                                            ).copyWith(
                                              p: const TextStyle(fontSize: 14),
                                              codeblockDecoration: BoxDecoration(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .surfaceContainerHighest,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                            ),
                                      )
                                    : Text(
                                        b.text,
                                        style: TextStyle(
                                          color: b.ephemeral
                                              ? Theme.of(context).disabledColor
                                              : null,
                                        ),
                                      ),
                              ),
                            );
                          },
                        )),
          ),
        ),
        _InteractorPane(
          vm: vm,
          onApproval: onApproval,
          onQuestion: onQuestion,
          onQueueRemove: onQueueRemove,
        ),
        if (vm.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Text(
              vm.lastError!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: UpgradeComposer(
              key: ValueKey('composer-${sid ?? 'none'}'),
              running: vm.selectedRunning,
              canSend: vm.canSend,
              onSend: (text, {required steer}) async {
                final sid = vm.selectedId;
                if (sid == null) return;
                // 发送/插话同一回调;错误由组件内联映射展示。
                final senderWithSteer = ChatSenderBinding.senderWithSteerOf(
                  context,
                );
                vm.send(text, (id, t) => senderWithSteer(id, t, steer));
              },
              onCancel: (onCancelSession != null && vm.selectedId != null)
                  ? () => onCancelSession!(vm.selectedId!)
                  : null,
              onCommandIntent: commands == null
                  ? null
                  : (query) {
                      final sid = vm.selectedId;
                      if (sid == null || query.isEmpty) return;
                      // 占位回调:真正菜单经底部 sheet 打开(见页头动作区)。
                    },
            ),
          ),
        ),
      ],
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({required this.vm, required this.controller});
  final ChatViewModel vm;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: vm.canSend,
            decoration: const InputDecoration(
              hintText: '输入消息,Enter 发送',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (text) {
              if (text.trim().isEmpty) return;
              controller.clear();
              vm.send(text, vm._senderOf(context));
            },
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: '发送',
          onPressed: vm.canSend
              ? () {
                  final text = controller.text;
                  if (text.trim().isEmpty) return;
                  controller.clear();
                  vm.send(text, vm._senderOf(context));
                }
              : null,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }
}

extension on ChatViewModel {
  Future<void> Function(String, String) _senderOf(BuildContext context) {
    // 由 main.dart 注入真实发送器;这里无法拿到 store,采用注册回调。
    return ChatSenderBinding.of(context);
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      duration: const Duration(milliseconds: 2000),
      content: Text(message),
    ),
  );
}

/// 交互帧面板:审批卡 + 问答表单 + 队列 Dock。
/// 刷新安全(硬性纪律 —— 交互卡不因界面刷新丢渲染):
/// - initState 先用 store.current* 快照播种(错过流事件也能自愈:
///   重连重放 pending 帧发生在面板挂载之前时,纯 listen 会永远漏渲染);
/// - 订阅随 vm.interactor 引用变化重挂(vm 是 Listenable,面板随其重建);
/// - 问答表单/审批卡以 rpcId 为 key,列表增删不丢已选/已输入状态;
/// - 切换会话时从快照重读当前会话队列(队列流只在变更时推送)。
class _InteractorPane extends StatefulWidget {
  const _InteractorPane({
    required this.vm,
    this.onApproval,
    this.onQuestion,
    this.onQueueRemove,
  });
  final ChatViewModel vm;
  final Future<void> Function(PendingApproval a, bool allow)? onApproval;
  final Future<String?> Function(PendingQuestion q, List<QuestionAnswerDraft> drafts)?
  onQuestion;
  final void Function(Map<String, dynamic> item)? onQueueRemove;

  @override
  State<_InteractorPane> createState() => _InteractorPaneState();
}

class _InteractorPaneState extends State<_InteractorPane> {
  List<PendingApproval> _approvals = const [];
  List<PendingQuestion> _questions = const [];
  List<Map<String, dynamic>> _queue = const [];
  InteractorStore? _subscribedTo;
  final _subs = <StreamSubscription<dynamic>>[];
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    widget.vm.addListener(_onVmChanged);
    _connect();
  }

  void _onVmChanged() {
    if (!mounted) return;
    // interactor 换引用(测试注入/未来重装)→ 重挂订阅。
    if (widget.vm.interactor != _subscribedTo) {
      _connect();
    }
    // 会话切换 → 队列从快照重读。
    if (widget.vm.selectedId != _selectedId) {
      _selectedId = widget.vm.selectedId;
      final queues = _subscribedTo?.currentQueues;
      final sid = _selectedId;
      setState(() => _queue = (sid != null && queues != null) ? (queues[sid] ?? const []) : const []);
    }
  }

  void _connect() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final it = widget.vm.interactor;
    _subscribedTo = it;
    if (it == null) return;
    // 播种:current* 是最新收敛快照(广播流不重放,纯 listen 会漏)。
    _approvals = it.currentApprovals;
    _questions = it.currentQuestions;
    _selectedId = widget.vm.selectedId;
    final sid0 = _selectedId;
    _queue = sid0 == null ? const [] : (it.currentQueues[sid0] ?? const []);
    _subs.add(
      it.approvals.listen((l) {
        if (mounted) setState(() => _approvals = l);
      }),
    );
    _subs.add(
      it.questions.listen((l) {
        if (mounted) setState(() => _questions = l);
      }),
    );
    _subs.add(
      it.queues.listen((m) {
        final sid = widget.vm.selectedId;
        if (mounted && sid != null) {
          setState(() => _queue = m[sid] ?? const []);
        }
      }),
    );
  }

  @override
  void dispose() {
    widget.vm.removeListener(_onVmChanged);
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    super.dispose();
  }

  /// 会话短标签:当前会话 → null(不显示);其它会话 → '会话·后 4 位'。
  String? _labelFor(String sessionId) {
    final selected = widget.vm.selectedId;
    if (selected == sessionId) return null;
    final tail = sessionId.length <= 4 ? sessionId : sessionId.substring(sessionId.length - 4);
    return '会话 ·$tail';
  }

  @override
  Widget build(BuildContext context) {
    // 多卡并存时限高滚动:待办审批/问答/队列可能同时堆积,不限高会把
    // composer 挤出屏幕(Column 溢出);限到视口 45%,内部滚动。
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .45,
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            ApprovalCards(
              approvals: _approvals,
              onRespond: (a, allow) => widget.onApproval?.call(a, allow),
              sessionLabel: {
                for (final a in _approvals)
                  if (_labelFor(a.sessionId) != null) a.rpcId: _labelFor(a.sessionId)!,
              },
            ),
            for (final q in _questions)
              QuestionForm(
                key: ValueKey('question-form-${q.rpcId}'),
                question: q,
                onSubmit: (drafts) =>
                    widget.onQuestion?.call(q, drafts) ?? Future.value(null),
                sessionLabel: _labelFor(q.sessionId),
              ),
            QueueDock(items: _queue, onRemove: widget.onQueueRemove),
          ],
        ),
      ),
    );
  }
}

/// 发送器绑定:把 UI 与 SessionStore 解耦(main 注入,测试可覆盖)。
class ChatSenderBinding extends InheritedWidget {
  const ChatSenderBinding({
    super.key,
    required this.sender,
    this.steerSender,
    required super.child,
  });
  final Future<void> Function(String sessionId, String text) sender;

  /// W2:带 steer 形态的发送(mode: 'steer' = 插话;默认 queue)。
  /// 与旧 sender 并存:旧回调不知道 mode,插话走 [steerSender](可空)。
  final Future<void> Function(String sessionId, String text, bool steer)?
  steerSender;

  static Future<void> Function(String, String) of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<ChatSenderBinding>();
    assert(w != null, 'ChatSenderBinding missing in tree');
    return w!.sender;
  }

  /// W2:composer 插话/发送统一入口;steerSender 缺席时插话退化为 queue。
  static Future<void> Function(String sessionId, String text, bool steer)
  senderWithSteerOf(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<ChatSenderBinding>();
    assert(w != null, 'ChatSenderBinding missing in tree');
    final withSteer = w!.steerSender;
    final plain = w.sender;
    if (withSteer != null) return withSteer;
    return (id, text, steer) => plain(id, text);
  }

  @override
  bool updateShouldNotify(ChatSenderBinding oldWidget) =>
      oldWidget.sender != sender;
}
