// WorkspaceBrowser — W1-A 侧栏 Workspace 浏览器(复刻 dsh web 分组视图)。
//
// 纪律:
// - 纯视图:状态只来自 WorkspaceStoreView(广播流+快照)与会话摘要流;
//   所有动作经回调上抛,由主会话路由到 WorkspaceStore / SessionStore
// - 移动硬性:行/按钮触控区 ≥44dp;菜单、重命名、删除确认一律
//   showModalBottomSheet(宽屏行为可后调);hover 语义降级为常显按钮
// - origin=='subagent' 的会话行隐藏;归档会话从分组视图过滤
// - 每组默认收 [initialExpandedCount] 条(默认 5),「展开其余」临时展开
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 动作回调束(主会话注入)。
/// 会话域操作(选中/新建会话/会话重命名/fork)路由到 SessionStore;
/// 工作区域操作(重命名/删除/归档)路由到 WorkspaceStore。
class WorkspaceBrowserCallbacks {
  const WorkspaceBrowserCallbacks({
    required this.onSelectSession,
    required this.onNewSession,
    this.onRenameWorkspace,
    this.onDeleteWorkspace,
    this.onRenameSession,
    this.onFork,
    this.onArchive,
  });

  /// 选中某会话(打开/切换到该会话)。
  final void Function(String sessionId) onSelectSession;

  /// 新建会话;workspaceId 非空 = 归入该分组,null = 未分组。
  final void Function(String? workspaceId) onNewSession;

  /// 重命名工作区。
  final void Function(String workspaceId, String title)? onRenameWorkspace;

  /// 删除工作区(会话保留,移入未分组)。
  final void Function(String workspaceId)? onDeleteWorkspace;

  /// 重命名会话。
  final void Function(String sessionId, String title)? onRenameSession;

  /// 在此分叉会话。
  final void Function(String sessionId)? onFork;

  /// 归档会话(非破坏性,无确认直接提交)。
  final void Function(String sessionId)? onArchive;
}

class WorkspaceBrowser extends StatefulWidget {
  const WorkspaceBrowser({
    super.key,
    required this.store,
    required this.sessionStream,
    required this.initialSessions,
    required this.callbacks,
    this.initialExpandedCount = 5,
  });

  final WorkspaceStoreView store;

  /// 会话摘要流(通常是 SessionStore.summaries)。
  final Stream<List<SessionSummary>> sessionStream;

  /// 挂载时的会话快照(广播流无重放,seed 防首帧空白)。
  final List<SessionSummary> initialSessions;
  final WorkspaceBrowserCallbacks callbacks;

  /// 每组默认显示条数,超出折叠为「展开其余」。
  final int initialExpandedCount;

  @override
  State<WorkspaceBrowser> createState() => _WorkspaceBrowserState();
}

class _WorkspaceBrowserState extends State<WorkspaceBrowser> {
  List<WorkspaceView> _workspaces = const <WorkspaceView>[];
  Set<String> _archived = const <String>{};
  List<SessionSummary> _sessions = const <SessionSummary>[];
  /// 已「展开其余」的分组键(未分组桶用空串)。
  final Set<String> _expanded = <String>{};
  StreamSubscription<List<WorkspaceView>>? _wsSub;
  StreamSubscription<List<String>>? _archSub;
  StreamSubscription<List<SessionSummary>>? _sessionSub;

  @override
  void initState() {
    super.initState();
    _workspaces = widget.store.currentWorkspaces;
    _archived = widget.store.currentArchivedSessionIds.toSet();
    _sessions = widget.initialSessions;
    _wsSub = widget.store.workspaces.listen((l) {
      if (mounted) setState(() => _workspaces = l);
    });
    _archSub = widget.store.archivedSessionIds.listen((l) {
      if (mounted) setState(() => _archived = l.toSet());
    });
    _sessionSub = widget.sessionStream.listen((l) {
      if (mounted) setState(() => _sessions = l);
    });
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _archSub?.cancel();
    _sessionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 归档 + subagent 从分组视图消失(归档非破坏性,数据仍在 store)。
    final inWorkspaceIds = <String>{
      for (final ws in _workspaces) ...ws.sessionIds,
    };
    final visible = _sessions
        .where((s) =>
            s.origin != 'subagent' && !_archived.contains(s.sessionId))
        .toList();
    final ungrouped = visible
        .where((s) => !inWorkspaceIds.contains(s.sessionId))
        .toList();

    final children = <Widget>[
      for (final ws in _workspaces) ...[
        _workspaceHeader(ws),
        ..._sessionRows(ws.workspaceId, _sessionsOf(ws)),
      ],
      // 未分组桶:有未分组会话时展示;无任何工作区时兜底新建会话入口。
      if (ungrouped.isNotEmpty || _workspaces.isEmpty) ...[
        _ungroupedHeader(),
        ..._sessionRows('', ungrouped),
      ],
    ];

    if (children.isEmpty) {
      return Center(
        child: TextButton.icon(
          onPressed: () => widget.callbacks.onNewSession(null),
          icon: const Icon(Icons.add),
          label: const Text('新建会话'),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: children,
    );
  }

  /// 某 workspace 内、可见(非归档/非 subagent)且已装载摘要的会话。
  List<SessionSummary> _sessionsOf(WorkspaceView ws) {
    final byId = <String, SessionSummary>{
      for (final s in _sessions) s.sessionId: s,
    };
    return [
      for (final sid in ws.sessionIds)
        if (byId[sid] != null &&
            byId[sid]!.origin != 'subagent' &&
            !_archived.contains(sid))
          byId[sid]!,
    ];
  }

  Widget _workspaceHeader(WorkspaceView ws) {
    return _headerRow(
      icon: Icons.folder_outlined,
      title: ws.title,
      actions: [
        _SheetAction(
          label: '新建会话',
          icon: Icons.add,
          onTap: () => widget.callbacks.onNewSession(ws.workspaceId),
        ),
        if (widget.callbacks.onRenameWorkspace != null)
          _SheetAction(
            label: '重命名',
            icon: Icons.edit_outlined,
            onTap: () => _renameWorkspace(ws),
          ),
        if (widget.callbacks.onDeleteWorkspace != null)
          _SheetAction(
            label: '删除',
            icon: Icons.delete_outline,
            onTap: () => _confirmDeleteWorkspace(ws),
          ),
      ],
    );
  }

  Widget _ungroupedHeader() {
    return _headerRow(
      icon: Icons.folder_off_outlined,
      title: '未分组',
      actions: [
        _SheetAction(
          label: '新建会话',
          icon: Icons.add,
          onTap: () => widget.callbacks.onNewSession(null),
        ),
      ],
    );
  }

  Widget _headerRow({
    required IconData icon,
    required String title,
    required List<_SheetAction> actions,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      trailing: _MenuButton(actions: actions),
    );
  }

  /// 组内会话行;默认收 [initialExpandedCount] 条,超出附「展开其余」。
  List<Widget> _sessionRows(String groupKey, List<SessionSummary> rows) {
    final expanded = _expanded.contains(groupKey);
    final shown =
        expanded ? rows : rows.take(widget.initialExpandedCount).toList();
    return <Widget>[
      for (final s in shown) _sessionRow(s),
      if (rows.length > widget.initialExpandedCount)
        TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
          ),
          onPressed: () => setState(() {
            expanded ? _expanded.remove(groupKey) : _expanded.add(groupKey);
          }),
          child: Text(
            expanded
                ? '收起'
                : '展开其余(${rows.length - widget.initialExpandedCount})',
            style: const TextStyle(fontSize: 12),
          ),
        ),
    ];
  }

  Widget _sessionRow(SessionSummary s) {
    return ListTile(
      leading: Icon(
        s.running
            ? Icons.autorenew
            : s.blank
                ? Icons.circle_outlined
                : Icons.chat_bubble_outline,
        size: 18,
      ),
      title: Text(
        _titleOf(s) ?? _fallbackTitle(s.sessionId),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        _relativeTime(s.updatedAt),
        style: const TextStyle(fontSize: 11),
      ),
      onTap: () => widget.callbacks.onSelectSession(s.sessionId),
      trailing: _MenuButton(
        actions: [
          if (widget.callbacks.onRenameSession != null)
            _SheetAction(
              label: '重命名',
              icon: Icons.edit_outlined,
              onTap: () => _renameSession(s),
            ),
          if (widget.callbacks.onFork != null)
            _SheetAction(
              label: '在此分叉',
              icon: Icons.call_split,
              onTap: () => widget.callbacks.onFork!(s.sessionId),
            ),
          if (widget.callbacks.onArchive != null)
            _SheetAction(
              label: '归档',
              icon: Icons.archive_outlined,
              onTap: () => widget.callbacks.onArchive!(s.sessionId),
            ),
        ],
      ),
    );
  }

  /// 会话标题:projections.title(host 规范化值)优先,否则回退短 id。
  String? _titleOf(SessionSummary s) {
    final values = s.projections?.values;
    if (values == null) return null;
    final title = values['title'];
    if (title is Map) {
      final t = title['title'];
      if (t is String && t.isNotEmpty) return t;
    }
    return null;
  }

  String _fallbackTitle(String sessionId) {
    final parts = sessionId.split('-')..removeWhere((p) => p.isEmpty);
    if (parts.isEmpty) return sessionId;
    return parts.take(3).join('-');
  }

  /// 相对时间(updatedAt 为 epoch 毫秒)。
  String _relativeTime(double updatedAtMs) {
    final diff = DateTime.now().millisecondsSinceEpoch - updatedAtMs.toInt();
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 3600 * 1000) return '${diff ~/ 60000} 分钟前';
    if (diff < 24 * 3600 * 1000) return '${diff ~/ 3600000} 小时前';
    return '${diff ~/ 86400000} 天前';
  }

  Future<void> _renameWorkspace(WorkspaceView ws) async {
    final title = await _promptText(context, '重命名工作区', initial: ws.title);
    if (title != null && title.trim().isNotEmpty) {
      widget.callbacks.onRenameWorkspace?.call(ws.workspaceId, title.trim());
    }
  }

  Future<void> _renameSession(SessionSummary s) async {
    final title = await _promptText(context, '重命名会话', initial: _titleOf(s));
    if (title != null && title.trim().isNotEmpty) {
      widget.callbacks.onRenameSession?.call(s.sessionId, title.trim());
    }
  }

  /// 删除确认:说明会话保留(非破坏性),确认后上抛。
  Future<void> _confirmDeleteWorkspace(WorkspaceView ws) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '删除工作区「${ws.title}」?',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '工作区内的会话不会被删除,将移入未分组。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed == true) {
      widget.callbacks.onDeleteWorkspace?.call(ws.workspaceId);
    }
  }

  /// 文本输入弹层(bottom sheet,键盘避让);返回 null = 取消。
  Future<String?> _promptText(BuildContext context, String title,
      {String? initial}) {
    final controller = TextEditingController(text: initial ?? '');
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '新标题',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (v) => Navigator.pop(context, v),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text),
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 菜单弹层项(≥44dp 行,经 showModalBottomSheet 呈现)。
class _SheetAction {
  const _SheetAction({required this.label, required this.icon, required this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

/// 常显菜单按钮(移动端 hover 语义降级);点开底部 sheet。
class _MenuButton extends StatelessWidget {
  const _MenuButton({required this.actions});
  final List<_SheetAction> actions;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '更多操作',
      icon: const Icon(Icons.more_vert, size: 20),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      padding: EdgeInsets.zero,
      onPressed: () => _showActions(context, actions),
    );
  }
}

Future<void> _showActions(BuildContext context, List<_SheetAction> actions) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in actions)
            ListTile(
              leading: Icon(a.icon),
              title: Text(a.label),
              onTap: () {
                Navigator.pop(context);
                a.onTap();
              },
            ),
        ],
      ),
    ),
  );
}
