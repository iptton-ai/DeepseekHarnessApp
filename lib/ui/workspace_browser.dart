// WorkspaceBrowser — W1-A 侧栏 Workspace 浏览器(复刻 dsh web 分组视图)。
//
// 纪律:
// - 纯视图:状态只来自 WorkspaceStoreView(广播流+快照)与会话摘要流;
//   所有动作经回调上抛,由主会话路由到 WorkspaceStore / SessionStore
// - 移动硬性:行/按钮触控区 ≥44dp;菜单、重命名、删除确认一律
//   showModalBottomSheet(宽屏行为可后调);hover 语义降级为常显按钮
// - origin=='subagent' 的会话行隐藏;归档会话从分组视图过滤
// - 每组默认收 [initialExpandedCount] 条(默认 5),「展开其余」临时展开
// - 视图模式(web WorkspaceViewStore 复刻):groupMode 按工作区分组/单列表,
//   orderMode 最近更新(默认,updatedAt 倒序)/手动排序(注册表顺序);
//   单列表模式无组头、无每组 5 条折叠(web flat 模式同款)
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
    this.onReorderSession,
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

  /// 手动排序落盘:workspace.insertSessionBefore(wsId, sessionId,
  /// beforeSessionId?)。仅按工作区分组模式下的真实工作区账号会触发
  /// (未分组/单列表为客户端本地顺序,web 同款);失败由调用方吞掉,
  /// store 广播会把顺序收敛回服务端真实状态。
  final Future<void> Function(
    String workspaceId,
    String sessionId,
    String? beforeSessionId,
  )?
  onReorderSession;
}

/// 分组方式(复刻 web WorkspaceViewStore.groupBy;默认按工作区)。
enum WorkspaceGroupMode {
  workspace,
  flat;

  /// 菜单文案(web locale:groupBy.workspace / groupBy.flat)。
  String get label => switch (this) {
    WorkspaceGroupMode.workspace => '按工作区',
    WorkspaceGroupMode.flat => '单列表',
  };
}

/// 排序方式(复刻 web WorkspaceViewStore.orderBy;默认最近更新)。
enum WorkspaceOrderMode {
  updated,
  manual;

  /// 菜单文案(web locale:orderBy.updated / orderBy.manual)。
  String get label => switch (this) {
    WorkspaceOrderMode.updated => '最近更新',
    WorkspaceOrderMode.manual => '手动排序',
  };
}

/// 单列表模式的手动排序账号键(web FLAT_SESSION_ORDER_KEY;NUL 前缀
/// 保证不可能与真实 workspaceId 撞名)。该账号顺序纯客户端,不落盘。
const String _kFlatOrderKey = '\u0000flat';

/// 最新 updatedAt 在前,sessionId 稳定 tie-break
/// (复刻 web compareSessionRecency;侧栏扁平回退列表共用)。
int sessionRecencyCompare(SessionSummary a, SessionSummary b) {
  if (a.updatedAt != b.updatedAt) return b.updatedAt.compareTo(a.updatedAt);
  return a.sessionId.compareTo(b.sessionId);
}

/// 手动排序 reconcile(复刻 web reconciledSessionOrder):stored 顺序
/// 优先(仅保留仍存在的会话),不在 stored 里的(新会话)按 wire/注册表
/// 顺序补到末尾。
List<SessionSummary> reconcileSessionOrder(
  List<SessionSummary> rows,
  List<String> stored,
) {
  final byId = <String, SessionSummary>{for (final s in rows) s.sessionId: s};
  final seen = <String>{};
  final out = <SessionSummary>[];
  for (final id in stored) {
    final s = byId[id];
    if (s == null || !seen.add(id)) continue;
    out.add(s);
  }
  for (final s in rows) {
    if (seen.contains(s.sessionId)) continue;
    out.add(s);
  }
  return out;
}

/// 长按拖拽排序的数据载荷(accountKey 约束拖放范围)。
class SessionDragPayload {
  const SessionDragPayload({
    required this.accountKey,
    required this.sessionId,
    required this.title,
  });

  /// 排序账号:分组模式 = workspaceId(未分组为 ''),单列表 = 平铺键。
  final String accountKey;
  final String sessionId;
  final String title;
}

class WorkspaceBrowser extends StatefulWidget {
  const WorkspaceBrowser({
    super.key,
    required this.store,
    required this.sessionStream,
    required this.initialSessions,
    required this.callbacks,
    this.query = '',
    this.selectedSessionId,
    this.initialExpandedCount = 5,
    this.groupMode = WorkspaceGroupMode.workspace,
    this.orderMode = WorkspaceOrderMode.updated,
  });

  final WorkspaceStoreView store;

  /// 会话摘要流(通常是 SessionStore.summaries)。
  final Stream<List<SessionSummary>> sessionStream;

  /// 挂载时的会话快照(广播流无重放,seed 防首帧空白)。
  final List<SessionSummary> initialSessions;
  final WorkspaceBrowserCallbacks callbacks;
  final String query;
  final String? selectedSessionId;

  /// 每组默认显示条数,超出折叠为「展开其余」。
  final int initialExpandedCount;

  /// 分组方式:按工作区(组头 + 每组折叠)/ 单列表(无层级)。
  final WorkspaceGroupMode groupMode;

  /// 排序方式:最近更新(updatedAt 倒序)/ 手动(注册表顺序)。
  final WorkspaceOrderMode orderMode;

  @override
  State<WorkspaceBrowser> createState() => _WorkspaceBrowserState();
}

class _WorkspaceBrowserState extends State<WorkspaceBrowser> {
  List<WorkspaceView> _workspaces = const <WorkspaceView>[];
  Set<String> _archived = const <String>{};
  List<SessionSummary> _sessions = const <SessionSummary>[];

  /// 已「展开其余」的分组键(未分组桶用空串)。
  final Set<String> _expanded = <String>{};

  /// 整个分组的折叠状态;默认展开,仅在用户主动点击标题时改变。
  final Set<String> _collapsed = <String>{};

  /// 手动排序的客户端覆叠(accountKey → 顺序,web sessionOrderByAccount
  /// 同构):真实工作区账号在 insertSessionBefore 成功后由 store 广播
  /// 收敛一致;未分组('')与单列表(平铺键)仅本地 —— host 没有这两个
  /// 注册表,web 也是纯客户端顺序。
  final Map<String, List<String>> _manualOrders = <String, List<String>>{};

  /// 长按拖拽排序的活动源(仅手动排序模式;null = 无拖拽)。
  SessionDragPayload? _activeDrag;

  /// 拖拽悬停目标行与其半侧(before = 插到目标行之前)。
  String? _dragOverId;
  bool _dragOverBefore = false;
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
    final visible = _visibleSessions();
    final ungrouped = _ungroupedSessions();

    // 单列表(web flat 模式):无组头、无每组 5 条折叠;最近更新模式
    // 整表 updatedAt 倒序,手动模式按注册表顺序(工作区 → 未分组)
    // 叠加平铺账号的本地手动顺序。
    if (widget.groupMode == WorkspaceGroupMode.flat) {
      final rows = widget.orderMode == WorkspaceOrderMode.manual
          ? _applyOrder([
              for (final ws in _workspaces) ..._sessionsOf(ws),
              ...ungrouped,
            ], _kFlatOrderKey)
          : _applyOrder(visible, _kFlatOrderKey); // updated:updatedAt 倒序。
      if (rows.isEmpty && _workspaces.isEmpty) {
        return _newSessionFallback();
      }
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: rows.length,
        itemBuilder: (context, i) =>
            _sessionRow(rows[i], accountKey: _kFlatOrderKey),
      );
    }

    // 分组描述符(组头/会话行/展开钮),ListView.builder 虚拟化 ——
    // 会话数增长后一次性 children 全量构建会卡滚动。
    final entries = <_WsEntry>[
      for (final ws in _workspaces) ...[
        _WsEntry.header(ws.workspaceId),
        if (!_collapsed.contains(ws.workspaceId))
          ..._groupRowEntries(ws.workspaceId, _sessionsOf(ws)),
      ],
      // 未分组桶:有未分组会话时展示;无任何工作区时兜底新建会话入口。
      if (ungrouped.isNotEmpty || _workspaces.isEmpty) ...[
        const _WsEntry.header(''),
        if (!_collapsed.contains('')) ..._groupRowEntries('', ungrouped),
      ],
    ];

    if (entries.isEmpty) {
      return _newSessionFallback();
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: entries.length,
      itemBuilder: (context, i) => _buildEntry(context, entries[i]),
    );
  }

  Widget _buildEntry(BuildContext context, _WsEntry e) {
    if (e is _WsHeaderEntry) {
      return e.groupKey.isEmpty
          ? _ungroupedHeader()
          : _workspaceHeader(_workspaceById(e.groupKey)!);
    }
    if (e is _WsSessionEntry) {
      return _sessionRow(e.session, accountKey: e.groupKey);
    }
    final expand = e as _WsExpandEntry;
    return _expandButton(expand.groupKey, expand.total, expand.shown);
  }

  /// 可见会话基表:归档 + subagent 从分组视图消失(归档非破坏性,数据
  /// 仍在 store);blank 仅当前选中那条可见(web sessionVisible)。
  List<SessionSummary> _visibleSessions() => _sessions
      .where(
        (s) =>
            s.origin != 'subagent' &&
            !_archived.contains(s.sessionId) &&
            // web sessionVisible:blank 会话仅当前选中那条可见
            // (选中工作区的临时「新会话」行),其余一律隐藏。
            (!s.blank || s.sessionId == widget.selectedSessionId) &&
            _matches(s, wsTitle: _wsTitleOf(s.sessionId)),
      )
      .toList();

  /// 未分组桶(不在任何工作区内的可见会话),手动模式叠加本地顺序。
  List<SessionSummary> _ungroupedSessions() {
    final inWorkspaceIds = <String>{
      for (final ws in _workspaces) ...ws.sessionIds,
    };
    return _applyOrder(
      _visibleSessions()
          .where((s) => !inWorkspaceIds.contains(s.sessionId))
          .toList(),
      '',
    );
  }

  /// 空列表兜底:无任何工作区且无可显会话时给一个新建入口。
  Widget _newSessionFallback() {
    return Center(
      child: TextButton.icon(
        onPressed: () => widget.callbacks.onNewSession(null),
        icon: const Icon(Icons.add),
        label: const Text('新建会话'),
      ),
    );
  }

  /// 排序落地:最近更新 → updatedAt 倒序(sessionRecencyCompare);
  /// 手动 → 注册表顺序叠加该账号的手动覆叠(reconcileSessionOrder,
  /// 未拖拽过 = 注册表顺序原样)。
  List<SessionSummary> _applyOrder(
    List<SessionSummary> rows,
    String accountKey,
  ) {
    if (widget.orderMode == WorkspaceOrderMode.updated) {
      rows.sort(sessionRecencyCompare);
      return rows;
    }
    final stored = _manualOrders[accountKey];
    if (stored == null) return rows;
    return reconcileSessionOrder(rows, stored);
  }

  /// 手动排序模式才开放长按拖拽(web:updated 模式拖拽不落盘也不显效)。
  bool get _reorderable => widget.orderMode == WorkspaceOrderMode.manual;

  /// 账号当前展示顺序(提交拖拽时计算 anchor 用);null = 账号不存在。
  List<String>? _accountOrderIds(String accountKey) {
    List<SessionSummary> rows;
    if (widget.groupMode == WorkspaceGroupMode.flat) {
      if (accountKey != _kFlatOrderKey) return null;
      rows = _applyOrder([
        for (final ws in _workspaces) ..._sessionsOf(ws),
        ..._ungroupedSessions(),
      ], _kFlatOrderKey);
    } else if (accountKey.isEmpty) {
      rows = _ungroupedSessions();
    } else {
      final ws = _workspaceById(accountKey);
      if (ws == null) return null;
      rows = _sessionsOf(ws);
    }
    return [for (final s in rows) s.sessionId];
  }

  /// 提交一次拖拽排序(复刻 web commitSessionDrag 的 anchor/no-op 判定):
  /// 上半侧 = 插到目标行之前,下半侧 = 插到目标行之后(即下一行之前);
  /// 位置未变 / 相邻等价移动直接忽略。真实工作区账号(分组模式)远端
  /// 落盘 insertSessionBefore,未分组与单列表仅本地。
  void _commitSessionDrag(
    SessionDragPayload data, {
    required String targetId,
    required bool before,
  }) {
    final order = _accountOrderIds(data.accountKey);
    if (order == null) return;
    final targetIndex = order.indexOf(targetId);
    if (targetIndex == -1) return;
    String? anchor;
    if (before) {
      anchor = targetId;
    } else if (targetIndex + 1 < order.length) {
      anchor = order[targetIndex + 1];
    }
    if (anchor == data.sessionId) return;
    final sourceIndex = order.indexOf(data.sessionId);
    if (sourceIndex == -1) return;
    final anchorIndex = anchor == null ? order.length : order.indexOf(anchor);
    if (anchorIndex == sourceIndex || anchorIndex == sourceIndex + 1) return;
    final next = [...order.where((id) => id != data.sessionId)];
    final insertAt = anchor == null ? next.length : next.indexOf(anchor);
    next.insert(insertAt == -1 ? next.length : insertAt, data.sessionId);
    setState(() => _manualOrders[data.accountKey] = next);
    final remote =
        widget.groupMode == WorkspaceGroupMode.workspace &&
        data.accountKey.isNotEmpty &&
        widget.callbacks.onReorderSession != null;
    if (remote) {
      unawaited(
        widget
            .callbacks
            .onReorderSession!(data.accountKey, data.sessionId, anchor)
            .then(
              (_) {},
              onError: (Object e) {
                // web 同款:拒绝仅告警,store 广播会把顺序收敛回真实状态。
                debugPrint('session reorder rejected: ' + e.toString());
              },
            ),
      );
    }
  }

  /// 会话所属工作区标题(搜索「工作区」时其会话整组保留)。
  String? _wsTitleOf(String sessionId) {
    for (final ws in _workspaces) {
      if (ws.sessionIds.contains(sessionId)) return ws.title;
    }
    return null;
  }

  WorkspaceView? _workspaceById(String id) {
    for (final ws in _workspaces) {
      if (ws.workspaceId == id) return ws;
    }
    return null;
  }

  /// 组内条目:可见的会话行描述符 + (收起态下的)展开其余按钮。
  List<_WsEntry> _groupRowEntries(String groupKey, List<SessionSummary> rows) {
    final expanded = _expanded.contains(groupKey);
    final shown = expanded
        ? rows
        : rows.take(widget.initialExpandedCount).toList();
    return <_WsEntry>[
      for (final s in shown) _WsEntry.session(groupKey, s),
      if (rows.length > widget.initialExpandedCount)
        _WsEntry.expand(groupKey, rows.length, shown.length),
    ];
  }

  Widget _expandButton(String groupKey, int total, int shown) {
    final expanded = _expanded.contains(groupKey);
    return TextButton(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.centerLeft,
      ),
      onPressed: () => setState(() {
        expanded ? _expanded.remove(groupKey) : _expanded.add(groupKey);
      }),
      child: Text(
        expanded ? '收起' : '展开其余(${total - shown})',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  /// 某 workspace 内、可见(非归档/非 subagent、blank 仅选中态)且
  /// 已装载摘要的会话;组标题命中搜索词时整组保留(wsTitle 短路)。
  List<SessionSummary> _sessionsOf(WorkspaceView ws) {
    final byId = <String, SessionSummary>{
      for (final s in _sessions) s.sessionId: s,
    };
    return _applyOrder([
      for (final sid in ws.sessionIds)
        if (byId[sid] != null &&
            byId[sid]!.origin != 'subagent' &&
            !_archived.contains(sid) &&
            (!byId[sid]!.blank || sid == widget.selectedSessionId) &&
            _matches(byId[sid]!, wsTitle: ws.title))
          byId[sid]!,
    ], ws.workspaceId);
  }

  bool _matches(SessionSummary s, {String? wsTitle}) {
    final query = widget.query.trim().toLowerCase();
    if (query.isEmpty) return true;
    final values = s.projections?.values;
    final titleValue = values == null ? null : values['title'];
    final title = titleValue is Map && titleValue['title'] is String
        ? titleValue['title'] as String
        : null;
    return s.sessionId.toLowerCase().contains(query) ||
        (s.cwd ?? '').toLowerCase().contains(query) ||
        (title ?? '').toLowerCase().contains(query) ||
        (wsTitle ?? '').toLowerCase().contains(query);
  }

  Widget _workspaceHeader(WorkspaceView ws) {
    return _headerRow(
      icon: Icons.folder_outlined,
      title: ws.title,
      groupKey: ws.workspaceId,
      sessionCount: _sessionsOf(ws).length,
      // 组头常显「+」:在本工作区新建会话(web ProjectRowItem 的
      // onCreate 按钮同构;替代原侧栏工具区的全局「+」)。
      onCreate: () => widget.callbacks.onNewSession(ws.workspaceId),
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
      groupKey: '',
      sessionCount: _ungroupedSessions().length,
      onCreate: () => widget.callbacks.onNewSession(null),
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
    required String groupKey,
    required int sessionCount,
    required VoidCallback onCreate,
    required List<_SheetAction> actions,
  }) {
    final colors = Theme.of(context).colorScheme;
    final collapsed = _collapsed.contains(groupKey);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.fromLTRB(12, 2, 8, 2),
      leading: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, size: 16, color: colors.primary),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      ),
      subtitle: Text(
        '$sessionCount 个会话',
        style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
      ),
      onTap: () => setState(() {
        collapsed ? _collapsed.remove(groupKey) : _collapsed.add(groupKey);
      }),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 常显「+」:在本组新建会话(web ProjectRowItem onCreate 按钮
          // 同构);触控区 44dp。
          IconButton(
            tooltip: '在本组新建会话',
            onPressed: onCreate,
            icon: const Icon(Icons.add, size: 20),
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            padding: EdgeInsets.zero,
          ),
          _MenuButton(actions: actions),
          Icon(
            collapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
            size: 20,
            color: colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _sessionRow(SessionSummary s, {String accountKey = ''}) {
    final colors = Theme.of(context).colorScheme;
    final selected = s.sessionId == widget.selectedSessionId;
    final row = ListTile(
      contentPadding: const EdgeInsets.only(left: 24, right: 8),
      selected: selected,
      selectedTileColor: colors.primary.withValues(alpha: .12),
      // 会话名不配专门图标(复刻 web 行:标题+相对时间);仅正在运行的
      // 会话在保留的 18dp 前置槽内显示 loading 小动画,标题左缘保持对齐。
      leading: SizedBox(
        width: 18,
        height: 18,
        child: s.running
            ? const Center(child: SessionRunningIndicator())
            : null,
      ),
      title: Text(
        sessionDisplayTitle(s),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
          color: selected ? colors.primary : null,
        ),
      ),
      // 相对时间槽:web 仅非 blank 会话渲染(!row.blank && timeLabel),
      // blank 行标题即「新会话」,不再占用时间槽。
      subtitle: s.blank
          ? null
          : Text(
              sessionRelativeTime(s.updatedAt),
              style: TextStyle(
                fontSize: 11,
                color: selected
                    ? colors.primary.withValues(alpha: .8)
                    : colors.onSurfaceVariant,
              ),
            ),
      onTap: () => widget.callbacks.onSelectSession(s.sessionId),
      // 操作菜单同样仅非 blank(web !row.blank && rowActions —— 临时新会话
      // 行不可重命名/分叉/归档)。
      trailing: s.blank
          ? null
          : _MenuButton(
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
    // 手动排序模式:长按拖拽重排(用户诉求);blank 行是临时新会话,
    // 不参与拖拽。分组模式 accountKey = 工作区 id → 拖放被约束在本组
    // (跨组 DragTarget 直接拒绝,web/host insertSessionBefore 同语义)。
    if (!_reorderable || s.blank) return row;
    final payload = SessionDragPayload(
      accountKey: accountKey,
      sessionId: s.sessionId,
      title: sessionDisplayTitle(s),
    );
    final markerActive = _activeDrag != null && _dragOverId == s.sessionId;
    return _ReorderableSessionRow(
      key: ValueKey('ws-reorder-' + s.sessionId),
      payload: payload,
      row: row,
      dragging: _activeDrag?.sessionId == s.sessionId,
      markerBefore: markerActive && _dragOverBefore,
      markerAfter: markerActive && !_dragOverBefore,
      onDragStarted: () => setState(() => _activeDrag = payload),
      onDragEnded: () => setState(() {
        _activeDrag = null;
        _dragOverId = null;
      }),
      onHover: (before) => setState(() {
        _dragOverId = s.sessionId;
        _dragOverBefore = before;
      }),
      onLeave: () {
        if (_dragOverId == s.sessionId) setState(() => _dragOverId = null);
      },
      onDrop: (data) => _commitSessionDrag(
        data,
        targetId: s.sessionId,
        before: _dragOverBefore,
      ),
    );
  }

  /// 会话标题:复用 web displayTitle 链(见 sessionDisplayTitle)。

  Future<void> _renameWorkspace(WorkspaceView ws) async {
    final title = await _promptText(context, '重命名工作区', initial: ws.title);
    if (title != null && title.trim().isNotEmpty) {
      widget.callbacks.onRenameWorkspace?.call(ws.workspaceId, title.trim());
    }
  }

  Future<void> _renameSession(SessionSummary s) async {
    final title = await _promptText(
      context,
      '重命名会话',
      // 预填当前显示名(web 重命名对话框预填 row.title,即 display 链结果)。
      initial: sessionDisplayTitle(s),
    );
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
  Future<String?> _promptText(
    BuildContext context,
    String title, {
    String? initial,
  }) {
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
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
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

/// 会话相对时间标签(复刻 web relativeTime 桶 + 紧凑文案,行内无「前」
/// 后缀 —— 「前」只出现在 hover 卡的 ago 模板;updatedAt 为 epoch 毫秒):
/// 刚刚(<1min) / N分钟(<1h) / N小时(<1d) / N天(<30d) / N个月(<365d) / N年。
String sessionRelativeTime(double updatedAtMs) {
  const min = 60 * 1000, hour = 3600 * 1000, day = 24 * 3600 * 1000;
  final diff = DateTime.now().millisecondsSinceEpoch - updatedAtMs.toInt();
  if (diff < min) return '刚刚';
  if (diff < hour) return '${diff ~/ min}分钟';
  if (diff < day) return '${diff ~/ hour}小时';
  if (diff < 30 * day) return '${diff ~/ day}天';
  if (diff < 365 * day) return '${diff ~/ (30 * day)}个月';
  return '${diff ~/ (365 * day)}年';
}

/// 会话行显示名 —— 复刻 web displayTitleOf + sessionTitle 链:
/// 1. blank 会话 → 本地化「新会话」占位(web t("session.new"));
/// 2. durable title(host projections.title,自动生成或用户重命名);
/// 3. 工作区目录名(cwd 去结尾斜杠取末段,如 …/singleman → singleman);
/// 4. 原始 sessionId。
String sessionDisplayTitle(SessionSummary s) {
  if (s.blank) return '新会话';
  // rc.6 wire:title 投影值是纯字符串(SessionProjectionMap: string|null)。
  final t = s.projections?.values['title'];
  if (t is String && t.isNotEmpty) return t;
  // 兼容旧本地写入的嵌套 map 形态(rename 曾经自造的形状)。
  if (t is Map && t['title'] is String && (t['title'] as String).isNotEmpty) {
    return t['title'] as String;
  }
  final cwd = s.cwd;
  if (cwd != null && cwd.isNotEmpty) {
    final base = cwd
        .replaceAll(RegExp(r'[/\\]+$'), '')
        .split(RegExp(r'[/\\]'))
        .last;
    if (base.isNotEmpty) return base;
  }
  return s.sessionId;
}

/// 会话行 running 小动画(替代原状态图标;仅正在运行的会话显示)。
class SessionRunningIndicator extends StatelessWidget {
  const SessionRunningIndicator({super.key, this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: Theme.of(context).colorScheme.tertiary,
      ),
    );
  }
}

/// 手动排序的会话行:长按拖起(LongPressDraggable)+ 同账号行间投放
/// (DragTarget)。上半侧 = 插到目标行之前,下半侧 = 之后;跨账号
/// (工作区)的目标在 onWillAccept 即拒绝 —— 会话只能在本组内移动。
class _ReorderableSessionRow extends StatefulWidget {
  const _ReorderableSessionRow({
    super.key,
    required this.payload,
    required this.row,
    required this.onDragStarted,
    required this.onDragEnded,
    required this.onHover,
    required this.onLeave,
    required this.onDrop,
    this.dragging = false,
    this.markerBefore = false,
    this.markerAfter = false,
  });

  final SessionDragPayload payload;
  final Widget row;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnded;
  final ValueChanged<bool> onHover;
  final VoidCallback onLeave;
  final ValueChanged<SessionDragPayload> onDrop;
  final bool dragging;
  final bool markerBefore;
  final bool markerAfter;

  @override
  State<_ReorderableSessionRow> createState() => _ReorderableSessionRowState();
}

class _ReorderableSessionRowState extends State<_ReorderableSessionRow> {
  /// 指针相对本行矩形的位置决定插入半侧(web workspaceGroupHalf 同款)。
  bool _isBefore(Offset global) {
    final rob = context.findRenderObject();
    if (rob is! RenderBox || !rob.attached) return true;
    final topLeft = rob.localToGlobal(Offset.zero);
    return global.dy < topLeft.dy + rob.size.height / 2;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final draggable = LongPressDraggable<SessionDragPayload>(
      data: widget.payload,
      // 360ms:比默认 500ms 跟手,又不与行的单击选中打架。
      delay: const Duration(milliseconds: 360),
      // 关键:pointerDragAnchorStrategy 让 dragStartPoint=0,DragTarget
      // 回调里的 offset 即真实指针全局坐标(默认 child 策略会减去行内
      // 抓取点,导致半侧判定整体上移一个抓取偏移)。
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: widget.onDragStarted,
      onDragEnd: (_) => widget.onDragEnded(),
      feedback: _dragFeedback(context, widget.payload.title),
      childWhenDragging: Opacity(opacity: .35, child: widget.row),
      child: widget.row,
    );
    Widget line() => Container(
      height: 3,
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: BorderRadius.circular(2),
      ),
    );
    return DragTarget<SessionDragPayload>(
      onWillAcceptWithDetails: (d) =>
          d.data.accountKey == widget.payload.accountKey &&
          d.data.sessionId != widget.payload.sessionId,
      // 半侧判定必须挂 onMove:onWillAccept 只在进入目标时触发一次,
      // 进入点在上缘会把「下半侧」误锁成 before;onMove 随指针逐帧更新。
      onMove: (update) => widget.onHover(_isBefore(update.offset)),
      onLeave: (_) => widget.onLeave(),
      onAcceptWithDetails: (d) => widget.onDrop(d.data),
      builder: (context, candidate, rejected) {
        // 标记画在行上下缘的 Stack 覆盖层里,不占布局高度(避免悬停时
        // 列表整体跳动)。
        return Stack(
          children: [
            draggable,
            if (widget.markerBefore)
              Positioned(top: 0, left: 16, right: 12, child: line()),
            if (widget.markerAfter)
              Positioned(bottom: 0, left: 16, right: 12, child: line()),
          ],
        );
      },
    );
  }
}

/// 拖拽时跟随手指的浮层行(Material 阴影 + 简化标题)。
Widget _dragFeedback(BuildContext context, String title) {
  final colors = Theme.of(context).colorScheme;
  return Material(
    elevation: 6,
    borderRadius: BorderRadius.circular(10),
    color: colors.surfaceContainerHigh,
    child: Container(
      width: 236,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.drag_indicator, size: 16, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
}

/// 菜单弹层项(≥44dp 行,经 showModalBottomSheet 呈现)。
class _SheetAction {
  const _SheetAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });
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

/// 侧栏扁平条目描述符(组头/会话行/展开钮;widget 在 itemBuilder 懒构建)。
sealed class _WsEntry {
  const _WsEntry();
  const factory _WsEntry.header(String groupKey) = _WsHeaderEntry;
  const factory _WsEntry.session(String groupKey, SessionSummary session) =
      _WsSessionEntry;
  const factory _WsEntry.expand(String groupKey, int total, int shown) =
      _WsExpandEntry;
}

class _WsHeaderEntry extends _WsEntry {
  const _WsHeaderEntry(this.groupKey);
  final String groupKey;
}

class _WsSessionEntry extends _WsEntry {
  const _WsSessionEntry(this.groupKey, this.session);
  final String groupKey;
  final SessionSummary session;
}

class _WsExpandEntry extends _WsEntry {
  const _WsExpandEntry(this.groupKey, this.total, this.shown);
  final String groupKey;
  final int total;
  final int shown;
}
