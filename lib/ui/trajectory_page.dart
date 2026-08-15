// TrajectoryPage — 轨迹视图(W3-A;web trajectory 的移动化复刻,纯客户端视图,整页推入)。
//
// 关键事实(DSH-PROTOCOL §9):轨迹视图零新 RPC —— 数据 = SessionLog 事件(已注入);
// 「加载更早」调注入的 onLoadOlder 回调(= session.history 分页,SessionStore 已有)。
// 数据层见 sessions/trajectory_model.dart(TrajectoryExtractor,纯函数)。
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

class _TrajectoryPageState extends State<TrajectoryPage> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  StreamSubscription<List<SessionEvent>>? _sub;
  late List<SessionEvent> _events;
  final Set<int> _collapsed = <int>{}; // 收起的轮次(startSeq)
  String _query = '';
  bool _loadingOlder = false;
  bool _showTailFab = false;

  @override
  void initState() {
    super.initState();
    _events = widget.events;
    _sub = widget.eventStream?.listen((events) {
      if (mounted) setState(() => _events = events);
    });
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant TrajectoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.events, widget.events) && widget.eventStream == null) {
      _events = widget.events;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final atTail = _scroll.hasClients &&
        _scroll.position.maxScrollExtent - _scroll.position.pixels < 64;
    if (atTail != !_showTailFab) {
      setState(() => _showTailFab = !atTail);
    }
  }

  void _jumpToTail() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
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

  @override
  Widget build(BuildContext context) {
    final view = TrajectoryExtractor.extract(_events);
    final turnNumbers = <int, int>{};
    for (var i = 0; i < view.turns.length; i++) {
      turnNumbers[view.turns[i].startSeq] = i + 1; // 第 N 轮(1 起)。
    }
    final items = _filter(view.items);
    return Scaffold(
      appBar: AppBar(
        title: const Text('轨迹'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                '${view.turns.length} 轮 · ${view.between.length} 轮外',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
      body: Column(children: [
        _buildToolbar(context),
        const Divider(height: 1),
        Expanded(child: _buildList(context, view, items, turnNumbers)),
      ]),
      floatingActionButton: _showTailFab
          ? FloatingActionButton.small(
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
      child: Row(children: [
        IconButton(
          tooltip: '全部折叠',
          onPressed: () => setState(() => _collapsed
            ..clear()
            ..addAll(_allTurnStartSeqs())),
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
      ]),
    );
  }

  Set<int> _allTurnStartSeqs() {
    final view = TrajectoryExtractor.extract(_events);
    return <int>{for (final t in view.turns) t.startSeq};
  }

  /// 搜索过滤:按类型/摘要(大小写不敏感)过滤行;命中的轮次/轮外区段保留。
  List<TrajectoryItem> _filter(List<TrajectoryItem> items) {
    if (_query.isEmpty) return items;
    bool match(TrajectoryRow r) =>
        r.type.toLowerCase().contains(_query) || r.summary.toLowerCase().contains(_query);
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
            out.add(TrajectoryTurnItem(TrajectoryTurn(
              startSeq: item.turn.startSeq,
              startTime: item.turn.startTime,
              endSeq: item.turn.endSeq,
              endTime: item.turn.endTime,
              rows: rows,
            )));
          }
      }
    }
    return out;
  }

  bool _turnExpanded(TrajectoryTurn turn) =>
      _query.isNotEmpty || !_collapsed.contains(turn.startSeq);

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
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96), // 底部给 FAB 留空。
      itemCount: items.length + (hasLoadOlder ? 1 : 0),
      itemBuilder: (context, i) {
        if (hasLoadOlder) {
          if (i == 0) return _loadOlderButton(context);
          i -= 1;
        }
        final item = items[i];
        return switch (item) {
          TrajectoryBetweenItem() => _BetweenCard(
              rows: item.between.rows,
              onRowTap: (r) => _openInspector(context, r, turnNumber: null),
            ),
          TrajectoryTurnItem() => _TurnCard(
              index: turnNumbers[item.turn.startSeq] ?? 0,
              turn: item.turn,
              expanded: _turnExpanded(item.turn),
              onToggle: () => setState(() {
                if (!_collapsed.add(item.turn.startSeq)) {
                  _collapsed.remove(item.turn.startSeq);
                }
              }),
              onRowTap: (r) => _openInspector(
                context,
                r,
                turnNumber: turnNumbers[item.turn.startSeq],
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

  void _openInspector(BuildContext context, TrajectoryRow row, {int? turnNumber}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _InspectorSheet(row: row, turnNumber: turnNumber),
    );
  }
}

/// 轮次卡:分组头(可折叠) + 行卡列表。
class _TurnCard extends StatelessWidget {
  const _TurnCard({
    required this.index,
    required this.turn,
    required this.expanded,
    required this.onToggle,
    required this.onRowTap,
  });

  final int index;
  final TrajectoryTurn turn;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(TrajectoryRow row) onRowTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        InkWell(
          onTap: onToggle,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                index > 0 ? '第 $index 轮' : '轮次',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const SizedBox(width: 8),
              _chip(
                theme,
                turn.inProgress ? '进行中' : '已结束',
                turn.inProgress ? Colors.blue.shade700 : theme.colorScheme.outline,
              ),
              const Spacer(),
              if (turn.durationMs != null)
                Text(
                  _fmtDuration(turn.durationMs),
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              const SizedBox(width: 8),
              Text(
                '${turn.rows.length} 行',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
            ]),
          ),
        ),
        if (expanded)
          Column(children: [
            for (final row in turn.rows) _RowCard(row: row, onTap: () => onRowTap(row)),
          ]),
      ]),
    );
  }
}

/// 轮外区段卡:轮外事件(compaction/start|end 等)。
class _BetweenCard extends StatelessWidget {
  const _BetweenCard({required this.rows, required this.onRowTap});
  final List<TrajectoryRow> rows;
  final void Function(TrajectoryRow row) onRowTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.6)),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(children: [
            Icon(Icons.more_horiz, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              '轮外事件(${rows.length})',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            ),
          ]),
        ),
        for (final row in rows) _RowCard(row: row, onTap: () => onRowTap(row)),
      ]),
    );
  }
}

/// 行卡:移动单列(徽标/摘要/元信息纵排),宽屏两列(左摘要,右元信息)。
class _RowCard extends StatelessWidget {
  const _RowCard({required this.row, required this.onTap});
  final TrajectoryRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 宽屏(≥900,页面级断点)行内两列:左摘要,右元信息;窄屏单列纵排。
    final wide = MediaQuery.sizeOf(context).width >= TrajectoryPage.kWideBreakpoint;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4)),
          ),
        ),
        child: wide
            ? Row(children: [
                Expanded(child: _summary(context)),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [_badge(context), _meta(context)],
                ),
              ])
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
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
    ]);
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
      style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

/// 检查器(底部 sheet):完整摘要 + 原始 JSON 折叠视图(等宽横滚)。
class _InspectorSheet extends StatelessWidget {
  const _InspectorSheet({required this.row, this.turnNumber});
  final TrajectoryRow row;
  final int? turnNumber;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, label, icon) = _roleStyle(context, row.role);
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 14, color: color, fontWeight: FontWeight.w600)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                row.type,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 14, runSpacing: 4, children: [
            _kv('seq', '${row.seq}'),
            _kv('时间', _fmtClock(row.time)),
            _kv('耗时', _fmtDuration(row.durationMs)),
            if (turnNumber != null) _kv('轮次', '第 $turnNumber 轮'),
          ]),
          const SizedBox(height: 14),
          Text('摘要', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
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
              Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal, // 等宽横滚(宽内容不挤爆)。
                  child: SelectableText(
                    _jsonOf(row.event),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.4),
                  ),
                ),
              ),
            ],
          ),
        ]),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Text(
      '$k: $v',
      style: const TextStyle(fontSize: 12),
    );
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

(Color, String, IconData) _roleStyle(BuildContext context, TrajectoryRole role) {
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
