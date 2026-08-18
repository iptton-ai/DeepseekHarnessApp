// SubagentCatalog UI(W1-C + 对齐 web ui-subagent):会话页头入口按钮 +
// 子代理目录页(树形懒展开)+ 子会话 transcript 页(实时 activity/parentAvailable)。
// 移动可用性:列表行/按钮触控区 ≥44dp(整行可点,展开箭头常显,无 hover);
// 错误一律内联/snackBar 呈现(subagentErrorMessage),不许静默吞。
//
// web 语义对齐(packages/client/ui-subagent/SubagentCatalogAction.tsx):
// - 入口可见性 = 证据驱动(目录 error / 有行 / 后代聚合>0),bare loading 不算;
// - 计数 = max(目录健康行数, 后代聚合 count);running>0 时徽标显 running 数;
// - 树形懒展开:hasChildren 行展开时才拉该 child 的目录(一次一请求);
// - 行内指标:tokenUsage 四桶和(投影键缺席即降级隐藏)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/sessions/event_text.dart';
import 'package:singleman/sessions/subagent_store.dart';
import 'package:singleman/ui/node_widgets.dart';
import 'package:singleman/ui/stream_rebuild_throttle.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 会话页头入口按钮:计数 = max(目录健康行,后代聚合);徽标 = running 数;
/// 无证据(目录未装且后代 0)不渲染。由集成方摆放到会话页头(见 chat_screen/main)。
class SubagentEntryButton extends StatefulWidget {
  const SubagentEntryButton({
    super.key,
    required this.store,
    required this.parentSessionId,
  });

  final SubagentStoreView store;
  final String parentSessionId;

  @override
  State<SubagentEntryButton> createState() => _SubagentEntryButtonState();
}

class _SubagentEntryButtonState extends State<SubagentEntryButton> {
  SubagentCatalogState? _catalog;
  SubagentDescendants _descendants =
      const SubagentDescendants(count: 0, runningCount: 0);
  StreamSubscription<Map<String, SubagentCatalogState>>? _catalogSub;
  StreamSubscription<Map<String, SubagentDescendants>>? _descSub;

  @override
  void initState() {
    super.initState();
    _catalog = widget.store.catalogFor(widget.parentSessionId);
    _descendants = widget.store.currentDescendants[widget.parentSessionId] ??
        const SubagentDescendants(count: 0, runningCount: 0);
    _catalogSub = widget.store.catalogs.listen((map) {
      final v = map[widget.parentSessionId];
      if (mounted && v != null && !identical(v, _catalog)) {
        setState(() => _catalog = v);
      }
    });
    _descSub = widget.store.descendants.listen((map) {
      if (mounted) {
        setState(() => _descendants = map[widget.parentSessionId] ??
            const SubagentDescendants(count: 0, runningCount: 0));
      }
    });
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.store.listChildren(widget.parentSessionId);
    } on Object catch (e) {
      // 入口按钮失败不阻塞页头:目录页里仍有错误与重试。
      debugPrint('subagent list failed: $e');
    }
  }

  @override
  void dispose() {
    _catalogSub?.cancel();
    _descSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final desc = _descendants;
    final healthyRows = catalog == null
        ? 0
        : catalog.entries.whereType<SubagentListEntryChild>().length;
    final count = healthyRows > desc.count ? healthyRows : desc.count;
    // 证据驱动可见性:error / 有行 / 后代>0(loading 空表不算证据;
    // 后代聚合来自摘要流,可先于目录到达 —— catalog 未装也渲染)。
    final visible = desc.count > 0 ||
        (catalog != null &&
            (catalog.phase == SubagentCatalogPhase.error ||
                catalog.entries.isNotEmpty));
    if (!visible) return const SizedBox.shrink();
    return IconButton(
      tooltip: desc.runningCount > 0
          ? '$count 个子代理,${desc.runningCount} 个运行中'
          : '$count 个子代理',
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SubagentCatalogPage(
          store: widget.store,
          parentSessionId: widget.parentSessionId,
        ),
      )),
      icon: Badge(
        isLabelVisible: desc.runningCount > 0,
        label: Text('${desc.runningCount}'),
        child: const Icon(Icons.account_tree_outlined),
      ),
    );
  }
}

/// 扁平化后的目录行(UI 渲染单元)。
class _CatalogRow {
  const _CatalogRow({
    required this.entry,
    required this.level,
    required this.childCatalog,
    required this.expanded,
  });

  final SubagentListEntry entry;
  final int level;
  final SubagentCatalogState? childCatalog;
  final bool expanded;
}

/// 子代理目录页(树形懒展开,移动友好):parent 的直接 child 列表,
/// hasChildren 行展开时拉取下级目录;行 = 状态点 + label + 副行(标题·模式·状态)
/// + 指标(token,投影键缺席即隐藏)。diagnostic 行可读但禁用。
class SubagentCatalogPage extends StatefulWidget {
  const SubagentCatalogPage({
    super.key,
    required this.store,
    required this.parentSessionId,
  });

  final SubagentStoreView store;
  final String parentSessionId;

  @override
  State<SubagentCatalogPage> createState() => _SubagentCatalogPageState();
}

class _SubagentCatalogPageState extends State<SubagentCatalogPage> {
  Map<String, SubagentCatalogState> _catalogs = const {};
  final Set<String> _expanded = <String>{};
  StreamSubscription<Map<String, SubagentCatalogState>>? _sub;
  bool _initialLoaded = false;

  @override
  void initState() {
    super.initState();
    final c = widget.store.catalogFor(widget.parentSessionId);
    _catalogs = c == null ? const {} : {widget.parentSessionId: c};
    _sub = widget.store.catalogs.listen((map) {
      if (mounted) setState(() => _catalogs = map);
    });
    _load();
  }

  Future<void> _load() async {
    // listChildren 不抛(错误折叠进 state);force 刷新目录行 activity。
    await widget.store.listChildren(widget.parentSessionId, force: true);
    if (mounted) setState(() => _initialLoaded = true);
  }

  void _toggleBranch(SubagentListEntryChild child) {
    setState(() {
      if (!_expanded.remove(child.id)) {
        _expanded.add(child.id);
      }
    });
    // 懒展开:该 child 的目录未装/在错误态 → 展开即拉取。
    final state = widget.store.catalogFor(child.id);
    if (state == null || state.phase == SubagentCatalogPhase.error) {
      widget.store.listChildren(child.id).ignore();
    }
  }

  void _open(SubagentListEntryChild child, String parentSessionId,
      {bool autoFocusInput = false}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SubagentTranscriptPage(
        store: widget.store,
        parentSessionId: parentSessionId,
        child: child,
        autoFocusInput: autoFocusInput,
      ),
    ));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// 树 → 扁平行序列(仅展开的分支递归下钻;下级目录未装/为空各占一行提示)。
  List<_CatalogRow> _flatten(String parentSessionId, int level) {
    final rows = <_CatalogRow>[];
    final catalog = _catalogs[parentSessionId];
    if (catalog == null) {
      rows.add(_CatalogRow(
        entry: const SubagentListEntryDiagnostic(id: '', reason: 'loading'),
        level: level,
        childCatalog: null,
        expanded: false,
      ));
      return rows;
    }
    for (final entry in catalog.entries) {
      if (entry is! SubagentListEntryChild) {
        rows.add(_CatalogRow(
            entry: entry, level: level, childCatalog: null, expanded: false));
        continue;
      }
      final expanded = _expanded.contains(entry.id);
      final childCatalog = _catalogs[entry.id];
      rows.add(_CatalogRow(
        entry: entry,
        level: level,
        childCatalog: entry.hasChildren ? childCatalog : null,
        expanded: expanded,
      ));
      if (expanded && entry.hasChildren) {
        rows.addAll(_flatten(entry.id, level + 1));
      }
    }
    if (catalog.entries.isEmpty) {
      rows.add(_CatalogRow(
        entry: const SubagentListEntryDiagnostic(id: '', reason: 'empty'),
        level: level,
        childCatalog: null,
        expanded: false,
      ));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final root = _catalogs[widget.parentSessionId];
    return Scaffold(
      appBar: AppBar(title: const Text('子代理')),
      body: !_initialLoaded || root == null
          ? const Center(child: CircularProgressIndicator())
          : _buildTree(context, root),
    );
  }

  Widget _buildTree(BuildContext context, SubagentCatalogState root) {
    final rows = _flatten(widget.parentSessionId, 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!root.parentAvailable)
          Container(
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '父会话已结束,子代理仅可查看,无法续聊',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontSize: 13),
            ),
          ),
        if (root.phase == SubagentCatalogPhase.error && root.entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text('目录刷新失败,以下为上次内容',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error, fontSize: 12)),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) => _row(context, rows[i]),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, _CatalogRow row) {
    final entry = row.entry;
    // 占位行(loading/empty)。
    if (entry is SubagentListEntryDiagnostic && entry.id.isEmpty) {
      return Padding(
        padding:
            EdgeInsets.only(left: 12.0 + row.level * 16, top: 8, bottom: 8),
        child: Text(
          entry.reason == 'loading' ? '正在加载子代理…' : '暂无子代理',
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }
    if (entry is SubagentListEntryDiagnostic) {
      return Padding(
        padding: EdgeInsets.only(left: row.level * 16.0),
        child: ListTile(
          enabled: false,
          leading: const Icon(Icons.error_outline, color: Colors.grey),
          title: Text('诊断(${entry.reason})',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle:
              const Text('该子代理不可用', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    final child = entry as SubagentListEntryChild;
    final running = child.activity == 'running';
    final summary = widget.store.summaryFor(child.id);
    final parentSessionId = _parentOf(child.id);
    final subtitle = [
      if (summary != null) _summaryTitle(summary),
      child.mode == 'continuable' ? '可续聊' : '一次性',
      if (running) '运行中',
    ].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: EdgeInsets.only(left: row.level * 16.0),
      child: ListTile(
        onTap: parentSessionId == null
            ? null
            : () => _open(child, parentSessionId),
        leading: _StatusDot(running: running),
        title: Text(subagentEntryTitle(child),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle,
            style: const TextStyle(fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_tokenMetric(summary) case final metric?)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(metric,
                    style:
                        const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            if (child.hasChildren)
              IconButton(
                tooltip: row.expanded ? '收起' : '展开下级',
                onPressed: () => _toggleBranch(child),
                icon: Icon(
                    row.expanded ? Icons.expand_less : Icons.expand_more),
              ),
          ],
        ),
      ),
    );
  }

  /// 该 child 行所在目录的 owner(树内父目录 id;根层 = 页 parent)。
  String? _parentOf(String childId) {
    for (final e in _catalogs.entries) {
      final has = e.value.entries.any(
          (row) => row is SubagentListEntryChild && row.id == childId);
      if (has) return e.key;
    }
    return null;
  }

  String _summaryTitle(SessionSummary summary) {
    final title = summary.projections?.values['title'];
    if (title is String && title.isNotEmpty) return title;
    final cwd = summary.cwd;
    if (cwd != null && cwd.isNotEmpty) {
      final parts =
          cwd.split('/').where((s) => s.isNotEmpty).toList(growable: false);
      if (parts.isNotEmpty) return parts.last;
    }
    return '';
  }

  String? _tokenMetric(SessionSummary? summary) {
    final usage = summary?.projections?.values['tokenUsage'];
    if (usage is! Map) return null;
    int readInt(Object? v) => v is num ? v.toInt() : 0;
    final total = readInt(usage['uncachedInputTokens']) +
        readInt(usage['outputTokens']) +
        readInt(usage['cacheReadTokens']) +
        readInt(usage['cacheWriteTokens']);
    if (total <= 0) return null;
    if (total < 1000) return '$total tok';
    if (total < 1000000) {
      final k = total / 1000;
      return '${k >= 100 ? k.round() : (k * 10).round() / 10}K tok';
    }
    final m = total / 1000000;
    return '${m >= 100 ? m.round() : (m * 10).round() / 10}M tok';
  }
}

/// 子会话 transcript 页:只读事件流 + 条件 composer。
/// - 运行中:输入禁用,保留 Stop(subagent.interrupt)
/// - 一次性 / 父会话不可用:只读说明,无输入
/// - 可续聊(parent 存活且 child inactive):输入框走 promptChild
/// activity/parentAvailable 订阅目录流实时更新(host 帧行内翻转零延迟)。
class SubagentTranscriptPage extends StatefulWidget {
  const SubagentTranscriptPage({
    super.key,
    required this.store,
    required this.parentSessionId,
    required this.child,
    this.autoFocusInput = false,
  });

  final SubagentStoreView store;
  final String parentSessionId;
  final SubagentListEntryChild child;
  final bool autoFocusInput;

  @override
  State<SubagentTranscriptPage> createState() => _SubagentTranscriptPageState();
}

class _SubagentTranscriptPageState extends State<SubagentTranscriptPage> {
  late final SubagentTranscript _transcript;
  final TextEditingController _input = TextEditingController();
  SubagentCatalogState? _catalog;
  String? _error;
  bool _sending = false;
  bool _interrupting = false;
  StreamSubscription<List<SessionEvent>>? _eventsSub;
  StreamSubscription<Map<String, SubagentCatalogState>>? _catalogSub;

  /// 节点缓存:build 不再全量重算 extractNodes(O(n) 只随节流落地)。
  List<ChatNode> _nodes = const <ChatNode>[];
  int _lastEventCount = 0;

  /// 重建节流:与主 agent 消息列表(ChatViewModel)同一节拍器 —— 运行中
  /// 子代理的实时流(几十~上百 chunk/s)不再逐帧 O(n) 重算 + 整屏 rebuild;
  /// 纯 assistant/chunk 追加走 250ms 慢档,结构变化一帧不等待。
  late final StreamRebuildThrottle _rebuild = StreamRebuildThrottle(
    onFlush: (_) => _flushNodes(),
  );

  @override
  void initState() {
    super.initState();
    _transcript = widget.store.transcriptFor(widget.child.id);
    _catalog = widget.store.catalogFor(widget.parentSessionId);
    _eventsSub = _transcript.eventStream.listen(_onEvents);
    _catalogSub = widget.store.catalogs.listen((map) {
      final v = map[widget.parentSessionId];
      if (mounted && v != null && !identical(v, _catalog)) {
        setState(() => _catalog = v);
      }
    });
    _load();
  }

  /// 与 ChatViewModel._onLogEvents 同款分档:纯 chunk 追加 → 慢档;
  /// 其余(历史页/定界/工具卡)→ 立即档。
  void _onEvents(List<SessionEvent> events) {
    final fresh = events.length > _lastEventCount
        ? events.sublist(_lastEventCount)
        : const <SessionEvent>[];
    _lastEventCount = events.length;
    final slow =
        fresh.isNotEmpty && fresh.every((e) => e.type == 'assistant/chunk');
    _rebuild.schedule(null, slow: slow);
  }

  void _flushNodes() {
    if (!mounted) return;
    setState(() {
      _nodes = extractNodes(
          [for (final e in _transcript.events) EventNodeInput(e)]);
    });
  }

  /// 目录行实时视图:优先从已装目录找该 child 行(activity/label 随 host 帧
  /// 行内翻转);目录缺席时回退打开时的快照。
  SubagentListEntryChild get _liveChild {
    final rows = _catalog?.entries ?? const <SubagentListEntry>[];
    for (final e in rows) {
      if (e is SubagentListEntryChild && e.id == widget.child.id) return e;
    }
    return widget.child;
  }

  Future<void> _load() async {
    try {
      // 目录(拿 parentAvailable)+ transcript(分页装载)并行拉取。
      await Future.wait([
        widget.store.listChildren(widget.parentSessionId),
        widget.store.readTranscript(widget.parentSessionId, widget.child.id,
            mode: widget.child.mode as String),
      ]);
      if (mounted) setState(() => _error = null);
      // 缓存命中(seq 全去重)时事件流不会发广播 → 节点缓存无来源。
      // 装载完成后统一对齐基准并强制落地一次,保证打开即有内容。
      _rebuild.reset();
      _lastEventCount = _transcript.events.length;
      if (mounted) _flushNodes();
    } on Object catch (e) {
      if (mounted) setState(() => _error = subagentErrorMessage(e));
    }
  }

  Future<void> _loadOlder() async {
    try {
      await widget.store.loadOlderTranscript(
        widget.parentSessionId,
        widget.child.id,
        mode: widget.child.mode as String,
      );
      if (mounted) setState(() => _error = null);
    } on Object catch (e) {
      if (mounted) setState(() => _error = subagentErrorMessage(e));
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.store.promptChild(
          widget.parentSessionId, widget.child.id, text,
          clientTimeZone: 'UTC');
      _input.clear();
      // prompt 后 activity 应翻 running:host/session-status 帧行内翻转;
      // 这里再主动刷新一次目录兜底(帧丢失/竞态)。
      await widget.store.invalidateChildren(widget.parentSessionId);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已发送')));
      }
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(subagentErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _interrupt() async {
    if (_interrupting) return;
    setState(() => _interrupting = true);
    try {
      await widget.store
          .interruptChild(widget.parentSessionId, widget.child.id);
      await widget.store.invalidateChildren(widget.parentSessionId);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已请求中断')));
      }
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(subagentErrorMessage(e))));
    } finally {
      if (mounted) setState(() => _interrupting = false);
    }
  }

  @override
  void dispose() {
    _rebuild.dispose();
    _eventsSub?.cancel();
    _catalogSub?.cancel();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = _liveChild;
    return Scaffold(
      appBar: AppBar(
          title:
              Text(subagentEntryTitle(child), overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          Expanded(
            child: _error != null && _transcript.events.isEmpty
                ? _ErrorRetry(message: _error!, onRetry: _load)
                : _buildEventList(),
          ),
          _composer(context),
        ],
      ),
    );
  }

  /// A10 transcript 完整渲染:与主聊天同能力的节点流(extractNodes +
  /// ChatNodeList:think/工具卡/markdown 全量)且**同节拍**(节点缓存随
  /// StreamRebuildThrottle 落地,build 零重算;250ms 慢档/结构快档与
  /// ChatViewModel 完全一致)。前导条目(加载更早/错误)置顶;
  /// _eventTile 保留为纯文本降级兜底(有事件但无可渲染节点时经
  /// 「查看原始事件」弹层可达)。
  Widget _buildEventList() {
    final events = _transcript.events;
    final nodes = _nodes;
    return Column(
      children: [
        // 更早历史分页(性能契约:打开只拉尾页,这里按需向前补)。
        if (_transcript.hasOlder)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
              ),
              onPressed: _loadOlder,
              child: const Text('加载更早', style: TextStyle(fontSize: 13)),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('部分事件未加载: ${_error!}',
                style: const TextStyle(color: Colors.red, fontSize: 12)),
          ),
        Expanded(
          child: nodes.isNotEmpty
              ? ChatNodeList(
                  key: ValueKey('subagent-nodes-${widget.child.id}'),
                  nodes: nodes,
                )
              : (events.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                          child: Text('该子代理暂无事件',
                              style: TextStyle(color: Colors.grey))),
                    )
                  // 有事件但无可渲染节点(管道事件):提示可看原始事件。
                  : Padding(
                      padding: const EdgeInsets.all(16),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: TextButton.icon(
                          onPressed: () => _showRawEvents(context, events),
                          icon: const Icon(Icons.list_alt, size: 16),
                          label: const Text('查看原始事件', style: TextStyle(fontSize: 13)),
                        ),
                      ),
                    )),
        ),
      ],
    );
  }

  /// 降级兜底:无可渲染节点但存在事件时,弹层列原始事件文本(自绘 tile)。
  void _showRawEvents(BuildContext context, List<SessionEvent> events) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('原始事件'),
            actions: [
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          body: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: events.length,
            itemBuilder: (context, i) => _eventTile(context, events[i]),
          ),
        ),
      ),
    );
  }

  /// 事件文本展示上限(字符);超长截断并标注总长。
  static const int _kEventTextCap = 4000;

  String _cappedEventText(String text) {
    if (text.isEmpty) return '(无文本内容)';
    if (text.length <= _kEventTextCap) return text;
    return '${text.substring(0, _kEventTextCap)}\n…(共 ${text.length} 字符,已截断)';
  }

  Widget _eventTile(BuildContext context, SessionEvent e) {
    final text = extractText(e.data);
    final role = e.type == 'user/message'
        ? '用户'
        : (e.type == 'assistant/message' ? '助手' : e.type);
    return Padding(
      key: ValueKey('subagent-event-${e.seq}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(role,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey)),
          const SizedBox(height: 2),
          // 单条文本截断保护:超长事件(如整文件 read 结果)只显示首段,
          // 避免巨型 Text 布局卡 UI(截断在字符串层,不是 maxLines)。
          Text(_cappedEventText(text)),
        ],
      ),
    );
  }

  /// 条件 composer:运行中→禁用输入+Stop;一次性/父不可用→只读说明;
  /// 可续聊→输入+发送。activity/parentAvailable 均为实时值(目录流驱动)。
  Widget _composer(BuildContext context) {
    final child = _liveChild;
    final running = child.activity == 'running';
    final oneShot = child.mode == 'one-shot';
    final parentOk = _catalog?.parentAvailable ?? true;
    final canResume = !running && !oneShot && parentOk;

    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: running
              ? Row(children: [
                  const Expanded(
                    child: Text('子代理运行中,输入已禁用',
                        style: TextStyle(fontSize: 13)),
                  ),
                  FilledButton.tonal(
                    onPressed: _interrupting ? null : _interrupt,
                    child: Text(_interrupting ? '中断中…' : '停止'),
                  ),
                ])
              : !canResume
                  ? Row(children: [
                      Expanded(
                        child: Text(
                          oneShot
                              ? '一次性执行记录,已结束,不可续聊'
                              : '父会话不可用,无法续聊',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ])
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _input,
                            enabled: !_sending,
                            minLines: 1,
                            maxLines: 3,
                            autofocus: widget.autoFocusInput,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _send(),
                            decoration: const InputDecoration(
                              hintText: '续聊消息…',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 48,
                          child: FilledButton(
                            onPressed: _sending ? null : _send,
                            child: const Text('发送'),
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}

/// 运行/停止状态点(running→橙色,其余灰色)。
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.running});
  final bool running;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: running ? Colors.orange : Colors.grey,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 错误 + 重试(目录/transcript 拉取失败的兜底)。
class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
