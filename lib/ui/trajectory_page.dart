// TrajectoryPage — 轨迹视图(W3-A;web trajectory 的移动化复刻,纯客户端视图,整页推入)。
//
// 关键事实(DSH-PROTOCOL §9):轨迹视图零新 RPC —— 数据 = SessionLog 事件(已注入);
// 「加载更早」调注入的 onLoadOlder 回调(= session.history 分页,SessionStore 已有)。
// 数据层见 sessions/trajectory_model.dart(TrajectoryExtractor,纯函数)。
//
// 性能纪律(懒渲染,避免卡 UI):
// - 提取缓存:TrajectoryExtractor.extract 按 _events 身份缓存 —— 滚动 FAB/搜索/
//   折叠等 setState 不再重复 O(n) 提取;过滤结果按 (events, query) 缓存
// - 拍平缓存:滚动 FAB 的 setState 不再重复创建全量 _TEntry 描述符;仅事件/
//   搜索/折叠状态变化时重建
// - 实时流刷新按 100ms 合并,避免 assistant 流式事件逐帧触发全量重建
// - 虚拟化:轮次头与行拍平成扁平条目进 ListView.builder —— 展开一个大轮
//   (单页可达上千事件)只构建可视行,不再整组 Column 全量构建
// - 检查器原始 JSON 预览截断(完整内容走「复制全部」),防巨型 SelectableText 卡布局
//
// 移动纪律(硬性,PLAN W3 横切要求):
// - 轮头/行卡触控区 ≥44dp;行点击 → 底部 sheet 检查器(完整摘要 + 原始 JSON 折叠)
// - 原始 JSON 等宽 + 横向滚动;hover 语义全部改为常显按钮/常显触发行
// - 顶部工具条:全部折叠/展开 + 搜索(按类型/摘要实时过滤,命中强制展开)
// - 「加载更早」按钮 + 「回到尾部」FAB
// - 宽屏(≥900):行内两列(左摘要/右元信息);检查器右侧 panel 可后置(不强制,暂用底部 sheet)
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:singleman/sessions/trajectory_model.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 轨迹页(整页推入)。集成方构造时注入事件快照 + 可选实时流 + 加载更早回调。
class TrajectoryPage extends StatefulWidget {
  const TrajectoryPage({
    super.key,
    required this.sessionId,
    required this.events,
    this.eventStream,
    this.onLoadOlder,
    this.hasOlder = false,
  });

  final String sessionId;

  /// 当前事件快照(SessionLog 注入)。
  final List<SessionEvent> events;

  /// 可选实时流(集成方订阅 store.logFor(id).eventStream 传入;缺省则静态快照)。
  final Stream<List<SessionEvent>>? eventStream;

  /// 「加载更早」回调(= session.history 分页;web loadOlder 同义)。null 时按钮置灰。
  final Future<void> Function()? onLoadOlder;

  /// 是否还有更早历史(由集成方按 session.history.hasMore 维护)。
  final bool hasOlder;

  /// 宽屏断点(≥900 行内两列)。
  static const double kWideBreakpoint = 900;

  @override
  State<TrajectoryPage> createState() => _TrajectoryPageState();
}

/// 扁平条目:轮次头 / 轮外区段头 / 行(拍平进 ListView.builder 虚拟化)。
sealed class _TEntry {
  const _TEntry();
}

class _TTurnHeader extends _TEntry {
  const _TTurnHeader({
    required this.turn,
    required this.index,
    required this.hasRows,
  });
  final TrajectoryTurn turn;
  final int index;

  /// 折叠时无行跟随,头部自闭合圆角。
  final bool hasRows;
}

class _TBetweenHeader extends _TEntry {
  const _TBetweenHeader({required this.count});
  final int count;
}

class _TRowItem extends _TEntry {
  const _TRowItem({
    required this.row,
    this.turnNumber,
    required this.groupLast,
  });
  final TrajectoryRow row;
  final int? turnNumber;

  /// 组内最后一行:底部圆角收边。
  final bool groupLast;
}

class _TrajectoryPageState extends State<TrajectoryPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  StreamSubscription<List<SessionEvent>>? _sub;
  Timer? _eventsUpdateTimer;
  List<SessionEvent>? _pendingEvents;
  late List<SessionEvent> _events;
  final Set<int> _collapsed = <int>{}; // 收起的轮次(startSeq)
  String _query = '';
  bool _loadingOlder = false;
  bool _showTailFab = false;

  // 提取/过滤缓存(性能纪律:滚动与折叠的 setState 不重复 O(n) 提取)。
  TrajectoryView? _view;
  List<SessionEvent>? _viewFor;
  Map<int, int>? _turnNumbers;
  List<TrajectoryItem>? _filtered;
  List<SessionEvent>? _filteredFor;
  String? _filteredQuery;
  List<_TEntry>? _flat;
  List<TrajectoryItem>? _flatFor;
  Set<int>? _flatCollapsed;
  bool _tailScrollInProgress = false;

  static const Duration _kEventRefreshInterval = Duration(milliseconds: 100);

  @override
  void initState() {
    super.initState();
    _events = widget.events;
    _sub = widget.eventStream?.listen(_queueEventUpdate);
    _scroll.addListener(_onScroll);
  }

  void _queueEventUpdate(List<SessionEvent> events) {
    _pendingEvents = events;
    if (_eventsUpdateTimer != null) return;
    _eventsUpdateTimer = Timer(_kEventRefreshInterval, () {
      _eventsUpdateTimer = null;
      final events = _pendingEvents;
      _pendingEvents = null;
      if (mounted && events != null) setState(() => _events = events);
    });
  }

  @override
  void didUpdateWidget(covariant TrajectoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.events, widget.events) &&
        widget.eventStream == null) {
      _events = widget.events;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _eventsUpdateTimer?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final atTail =
        _scroll.hasClients &&
        _scroll.position.maxScrollExtent - _scroll.position.pixels < 64;
    if (atTail != !_showTailFab) {
      setState(() => _showTailFab = !atTail);
    }
  }

  void _jumpToTail() {
    if (!_scroll.hasClients || _tailScrollInProgress) return;
    _tailScrollInProgress = true;
    unawaited(
      _scroll
          .animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          )
          .then(
            (_) {
              _tailScrollInProgress = false;
              if (mounted) _convergeToTail(12);
            },
            onError: (_, __) {
              _tailScrollInProgress = false;
            },
          ),
    );
  }

  /// ListView.builder 可能在跳转到尾部后才物化尾部子项,导致
  /// maxScrollExtent 在动画结束后继续增长。用有界的逐帧跳转收敛，
  /// 不在滚动回调中递归启动新动画。
  void _convergeToTail(int passes) {
    if (!mounted || !_scroll.hasClients || passes <= 0) return;
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels <= 0.5) return;
    _scroll.jumpTo(position.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _convergeToTail(passes - 1);
    });
  }

  Future<void> _loadOlder() async {
    final cb = widget.onLoadOlder;
    if (cb == null || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    try {
      await cb();
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// 提取缓存:仅当事件列表身份变化(新页装载/实时帧)才重算。
  TrajectoryView _ensureView() {
    if (_view == null || !identical(_viewFor, _events)) {
      final view = TrajectoryExtractor.extract(_events);
      final numbers = <int, int>{
        for (var i = 0; i < view.turns.length; i++)
          view.turns[i].startSeq: i + 1,
      };
      _view = view;
      _turnNumbers = numbers;
      _viewFor = _events;
      _filtered = null; // 事件变了,过滤缓存作废。
      _flat = null;
    }
    return _view!;
  }

  Map<int, int> get _turnNumbersOf => _turnNumbers!;

  List<TrajectoryItem> _ensureFiltered(TrajectoryView view) {
    if (_filtered == null ||
        !identical(_filteredFor, _viewFor) ||
        _filteredQuery != _query) {
      _filtered = _filter(view.items);
      _filteredFor = _viewFor;
      _filteredQuery = _query;
    }
    return _filtered!;
  }

  @override
  Widget build(BuildContext context) {
    final view = _ensureView();
    final turnNumbers = _turnNumbersOf;
    final items = _ensureFiltered(view);
    return Scaffold(
      appBar: AppBar(
        title: const Text('轨迹'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                '${view.turns.length} 轮 · ${view.between.length} 轮外',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildToolbar(context),
          const Divider(height: 1),
          Expanded(child: _buildList(context, view, items, turnNumbers)),
        ],
      ),
      floatingActionButton: _showTailFab
          ? FloatingActionButton.small(
              key: const ValueKey('trajectory-scroll-to-tail'),
              tooltip: '回到尾部',
              onPressed: _jumpToTail,
              child: const Icon(Icons.vertical_align_bottom),
            )
          : null,
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
      child: Row(
        children: [
          IconButton(
            tooltip: '全部折叠',
            onPressed: () => setState(() {
              _collapsed
                ..clear()
                ..addAll(_view!.turns.map((t) => t.startSeq));
            }),
            icon: const Icon(Icons.unfold_less),
          ),
          IconButton(
            tooltip: '全部展开',
            onPressed: () => setState(_collapsed.clear),
            icon: const Icon(Icons.unfold_more),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              decoration: InputDecoration(
                hintText: '搜索(类型/摘要)',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索过滤:按类型/摘要(大小写不敏感)过滤行;命中的轮次/轮外区段保留。
  List<TrajectoryItem> _filter(List<TrajectoryItem> items) {
    if (_query.isEmpty) return items;
    bool match(TrajectoryRow r) =>
        r.type.toLowerCase().contains(_query) ||
        r.summary.toLowerCase().contains(_query);
    final out = <TrajectoryItem>[];
    for (final item in items) {
      switch (item) {
        case TrajectoryBetweenItem():
          final rows = item.between.rows.where(match).toList();
          if (rows.isNotEmpty) {
            out.add(TrajectoryBetweenItem(TrajectoryBetween(rows: rows)));
          }
        case TrajectoryTurnItem():
          final rows = item.turn.rows.where(match).toList();
          if (rows.isNotEmpty) {
            out.add(
              TrajectoryTurnItem(
                TrajectoryTurn(
                  startSeq: item.turn.startSeq,
                  startTime: item.turn.startTime,
                  endSeq: item.turn.endSeq,
                  endTime: item.turn.endTime,
                  rows: rows,
                ),
              ),
            );
          }
      }
    }
    return out;
  }

  bool _turnExpanded(TrajectoryTurn turn) =>
      _query.isNotEmpty || !_collapsed.contains(turn.startSeq);

  /// 拍平:头 + 行交错成扁平条目(搜索命中或未折叠的轮次展开行)。
  /// 只构建描述符,不构建 widget —— widget 由 ListView.builder 按可视区懒构建。
  List<_TEntry> _flatten(
    List<TrajectoryItem> items,
    Map<int, int> turnNumbers,
  ) {
    final flat = <_TEntry>[];
    for (final item in items) {
      switch (item) {
        case TrajectoryBetweenItem():
          final rows = item.between.rows;
          flat.add(_TBetweenHeader(count: rows.length));
          for (var i = 0; i < rows.length; i++) {
            flat.add(
              _TRowItem(
                row: rows[i],
                turnNumber: null,
                groupLast: i == rows.length - 1,
              ),
            );
          }
        case TrajectoryTurnItem():
          final expanded = _turnExpanded(item.turn);
          flat.add(
            _TTurnHeader(
              turn: item.turn,
              index: turnNumbers[item.turn.startSeq] ?? 0,
              hasRows: expanded && item.turn.rows.isNotEmpty,
            ),
          );
          if (expanded) {
            final rows = item.turn.rows;
            for (var i = 0; i < rows.length; i++) {
              flat.add(
                _TRowItem(
                  row: rows[i],
                  turnNumber: turnNumbers[item.turn.startSeq],
                  groupLast: i == rows.length - 1,
                ),
              );
            }
          }
      }
    }
    return flat;
  }

  List<_TEntry> _ensureFlat(
    List<TrajectoryItem> items,
    Map<int, int> turnNumbers,
  ) {
    final collapsed = _flatCollapsed;
    final collapsedUnchanged =
        collapsed != null &&
        collapsed.length == _collapsed.length &&
        _collapsed.every(collapsed.contains);
    if (_flat == null || !identical(_flatFor, items) || !collapsedUnchanged) {
      _flat = _flatten(items, turnNumbers);
      _flatFor = items;
      _flatCollapsed = Set<int>.of(_collapsed);
    }
    return _flat!;
  }

  Widget _buildList(
    BuildContext context,
    TrajectoryView view,
    List<TrajectoryItem> items,
    Map<int, int> turnNumbers,
  ) {
    if (items.isEmpty && !widget.hasOlder) {
      return Center(
        child: Text(
          _query.isEmpty ? '暂无轨迹事件' : '无匹配轨迹',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    final hasLoadOlder = widget.hasOlder;
    final flat = _ensureFlat(items, turnNumbers);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96), // 底部给 FAB 留空。
      itemCount: flat.length + (hasLoadOlder ? 1 : 0),
      itemBuilder: (context, i) {
        if (hasLoadOlder) {
          if (i == 0) return _loadOlderButton(context);
          i -= 1;
        }
        final entry = flat[i];
        return switch (entry) {
          _TTurnHeader() => _TurnHeaderCard(
            index: entry.index,
            turn: entry.turn,
            hasRows: entry.hasRows,
            expanded: _turnExpanded(entry.turn),
            onToggle: () => setState(() {
              if (!_collapsed.add(entry.turn.startSeq)) {
                _collapsed.remove(entry.turn.startSeq);
              }
            }),
          ),
          _TBetweenHeader() => _BetweenHeaderCard(count: entry.count),
          _TRowItem() => _RowCard(
            key: ValueKey('traj-row-${entry.row.seq}'),
            row: entry.row,
            groupLast: entry.groupLast,
            onTap: () => _openInspector(
              context,
              entry.row,
              turnNumber: entry.turnNumber,
            ),
          ),
        };
      },
    );
  }

  Widget _loadOlderButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SizedBox(
        height: 44,
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _loadingOlder ? null : _loadOlder,
          icon: _loadingOlder
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.history, size: 18),
          label: Text(_loadingOlder ? '加载中…' : '加载更早'),
        ),
      ),
    );
  }

  void _openInspector(
    BuildContext context,
    TrajectoryRow row, {
    int? turnNumber,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _InspectorSheet(row: row, turnNumber: turnNumber),
    );
  }
}

/// 轮次头(扁平条目):分组头可折叠;圆角随是否有行跟随自适应。
class _TurnHeaderCard extends StatelessWidget {
  const _TurnHeaderCard({
    required this.index,
    required this.turn,
    required this.hasRows,
    required this.expanded,
    required this.onToggle,
  });

  final int index;
  final TrajectoryTurn turn;
  final bool hasRows;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.vertical(
          top: const Radius.circular(12),
          bottom: Radius.circular(hasRows ? 0 : 12),
        ),
        border: Border.all(color: theme.dividerColor.withValues(alpha: .5)),
      ),
      child: InkWell(
        onTap: onToggle,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                index > 0 ? '第 $index 轮' : '轮次',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
              _chip(
                theme,
                turn.inProgress ? '进行中' : '已结束',
                turn.inProgress
                    ? Colors.blue.shade700
                    : theme.colorScheme.outline,
              ),
              const Spacer(),
              if (turn.durationMs != null)
                Text(
                  _fmtDuration(turn.durationMs),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(width: 8),
              Text(
                '${turn.rows.length} 行',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 轮外区段头(扁平条目)。
class _BetweenHeaderCard extends StatelessWidget {
  const _BetweenHeaderCard({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.55,
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.more_horiz,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            '轮外事件($count)',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 行卡(扁平条目):移动单列(徽标/摘要/元信息纵排),宽屏两列;
/// 组内末行收底部圆角,视觉上与头部拼回一张整卡。
class _RowCard extends StatelessWidget {
  const _RowCard({
    super.key,
    required this.row,
    required this.groupLast,
    required this.onTap,
  });
  final TrajectoryRow row;
  final bool groupLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 宽屏(≥900,页面级断点)行内两列:左摘要,右元信息;窄屏单列纵排。
    final wide =
        MediaQuery.sizeOf(context).width >= TrajectoryPage.kWideBreakpoint;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow.withValues(alpha: .96),
          border: Border.fromBorderSide(
            BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
          ),
          borderRadius: groupLast
              ? const BorderRadius.vertical(bottom: Radius.circular(12))
              : BorderRadius.zero,
        ),
        child: wide
            ? Row(
                children: [
                  Expanded(child: _summary(context)),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [_badge(context), _meta(context)],
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _badge(context),
                  const SizedBox(height: 2),
                  _summary(context),
                  _meta(context),
                ],
              ),
      ),
    );
  }

  Widget _badge(BuildContext context) {
    final (color, label, icon) = _roleStyle(context, row.role);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _summary(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        row.summary.isEmpty ? row.type : row.summary,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  Widget _meta(BuildContext context) {
    return Text(
      'seq ${row.seq} · ${row.type} · ${_fmtDuration(row.durationMs)}',
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 检查器(底部 sheet):完整摘要 + 原始 JSON 折叠视图(等宽横滚)。
/// 原始 JSON 预览截断(巨型事件的完整 JSON 会卡布局);完整内容走「复制全部」。
class _InspectorSheet extends StatelessWidget {
  const _InspectorSheet({required this.row, this.turnNumber});
  final TrajectoryRow row;
  final int? turnNumber;

  /// JSON 预览截断阈值(字符)。
  static const int _kJsonPreviewCap = 16000;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, label, icon) = _roleStyle(context, row.role);
    final json = _jsonOf(row.event);
    final truncated = json.length > _kJsonPreviewCap;
    final preview = truncated
        ? '${json.substring(0, _kJsonPreviewCap)}\n'
            '…(共 ${json.length} 字符,已截断 —— 「复制全部」取完整 JSON)'
        : json;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    row.type,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _kv('seq', '${row.seq}'),
                _kv('时间', _fmtClock(row.time)),
                _kv('耗时', _fmtDuration(row.durationMs)),
                if (turnNumber != null) _kv('轮次', '第 $turnNumber 轮'),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '摘要',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  TrajectoryExtractor.fullSummary(row.event),
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('原始 JSON', style: TextStyle(fontSize: 13)),
              children: [
                if (truncated)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: json));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              duration: Duration(milliseconds: 1200),
                              content: Text('已复制完整 JSON'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 14),
                        label: const Text(
                          '复制全部',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal, // 等宽横滚(宽内容不挤爆)。
                    child: SelectableText(
                      preview,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Text('$k: $v', style: const TextStyle(fontSize: 12));
  }
}

Widget _chip(ThemeData theme, String label, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(label, style: TextStyle(fontSize: 11, color: color)),
  );
}

(Color, String, IconData) _roleStyle(
  BuildContext context,
  TrajectoryRole role,
) {
  final scheme = Theme.of(context).colorScheme;
  return switch (role) {
    TrajectoryRole.user => (Colors.blue.shade700, '用户', Icons.person),
    TrajectoryRole.assistant => (Colors.teal.shade700, '助手', Icons.smart_toy),
    TrajectoryRole.tool => (Colors.purple.shade700, '工具', Icons.construction),
    TrajectoryRole.compaction => (Colors.brown.shade700, '压缩', Icons.compress),
    TrajectoryRole.retry => (Colors.orange.shade800, '重试', Icons.refresh),
    TrajectoryRole.error => (scheme.error, '错误', Icons.error_outline),
    TrajectoryRole.other => (scheme.outline, '其他', Icons.more_horiz),
  };
}

String _fmtDuration(double? ms) {
  if (ms == null) return '—';
  if (ms < 1000) return '${ms.round()}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final m = (ms / 60000).floor();
  final s = ((ms % 60000) / 1000).round();
  if (m < 60) return '${m}m ${s}s';
  return '${m ~/ 60}h ${m % 60}m';
}

String _fmtClock(double ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms.round());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

String _jsonOf(SessionEvent event) {
  try {
    return const JsonEncoder.withIndent('  ').convert(event.toJson());
  } catch (_) {
    return event.toJson().toString();
  }
}
