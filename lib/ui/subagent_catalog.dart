// SubagentCatalog UI(W1-C):会话页头入口按钮 + 子代理目录页 + 子会话 transcript 页。
// 移动可用性:列表行/按钮触控区 ≥44dp(整行可点,尾部按钮常显,无 hover);
// 错误一律内联/snackBar 呈现(subagentErrorMessage),不许静默吞。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/sessions/event_text.dart';
import 'package:singleman/sessions/subagent_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 会话页头入口按钮:角标 = running child 数;无 child(或未就绪)不渲染。
/// 由集成方摆放到会话页头(见 chat_screen/main),点击推入 SubagentCatalogPage。
class SubagentEntryButton extends StatefulWidget {
  const SubagentEntryButton({
    super.key,
    required this.store,
    required this.parentSessionId,
  });

  final SubagentStore store;
  final String parentSessionId;

  @override
  State<SubagentEntryButton> createState() => _SubagentEntryButtonState();
}

class _SubagentEntryButtonState extends State<SubagentEntryButton> {
  SubagentListValue? _catalog;
  StreamSubscription<Map<String, SubagentListValue>>? _sub;

  @override
  void initState() {
    super.initState();
    _catalog = widget.store.catalogFor(widget.parentSessionId);
    _sub = widget.store.catalogs.listen(_onCatalogs);
    _load();
  }

  void _onCatalogs(Map<String, SubagentListValue> map) {
    final v = map[widget.parentSessionId];
    if (!mounted) return;
    if (v != null && !identical(v, _catalog)) {
      setState(() => _catalog = v);
    }
  }

  Future<void> _load() async {
    try {
      final v = await widget.store.listChildren(widget.parentSessionId);
      if (mounted && !identical(v, _catalog)) {
        setState(() => _catalog = v);
      }
    } on Object catch (e) {
      // 入口按钮失败不阻塞页头:仅记录,用户仍可点开目录页看错误与重试。
      debugPrint('subagent list failed: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    if (catalog == null || catalog.entries.isEmpty) {
      return const SizedBox.shrink();
    }
    final running = catalog.entries
        .where((e) => e is SubagentListEntryChild && e.activity == 'running')
        .length;
    return IconButton(
      tooltip: '子代理目录',
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SubagentCatalogPage(
          store: widget.store,
          parentSessionId: widget.parentSessionId,
        ),
      )),
      icon: Badge(
        isLabelVisible: running > 0,
        label: Text('$running'),
        child: const Icon(Icons.account_tree_outlined),
      ),
    );
  }
}

/// 子代理目录页(整页推入,移动友好):parent 的直接 child 列表。
/// 行 = 状态点 + mode 标签 + title(无 label 回退 sessionId)+ 尾部「查看/续聊」;
/// diagnostic 行可读但禁用。错误态带重试。
class SubagentCatalogPage extends StatefulWidget {
  const SubagentCatalogPage({
    super.key,
    required this.store,
    required this.parentSessionId,
  });

  final SubagentStore store;
  final String parentSessionId;

  @override
  State<SubagentCatalogPage> createState() => _SubagentCatalogPageState();
}

class _SubagentCatalogPageState extends State<SubagentCatalogPage> {
  SubagentListValue? _catalog;
  String? _error;
  StreamSubscription<Map<String, SubagentListValue>>? _sub;

  @override
  void initState() {
    super.initState();
    _catalog = widget.store.catalogFor(widget.parentSessionId);
    _sub = widget.store.catalogs.listen(_onCatalogs);
    _load();
  }

  void _onCatalogs(Map<String, SubagentListValue> map) {
    final v = map[widget.parentSessionId];
    if (!mounted) return;
    if (v != null && !identical(v, _catalog)) {
      setState(() => _catalog = v);
    }
  }

  Future<void> _load() async {
    // 进页强制刷新目录(目录行 activity 随 list 重取,运行中→已完成翻转可见)。
    try {
      final v = await widget.store.listChildren(widget.parentSessionId,
          force: true);
      if (mounted) {
        setState(() {
          _catalog = v;
          _error = null;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = subagentErrorMessage(e));
    }
  }

  void _open(SubagentListEntryChild child, {bool autoFocusInput = false}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SubagentTranscriptPage(
        store: widget.store,
        parentSessionId: widget.parentSessionId,
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

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    return Scaffold(
      appBar: AppBar(title: const Text('子代理')),
      body: _error != null && catalog == null
          ? _ErrorRetry(message: _error!, onRetry: _load)
          : catalog == null
              ? const Center(child: CircularProgressIndicator())
              : _buildList(context, catalog),
    );
  }

  Widget _buildList(BuildContext context, SubagentListValue catalog) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 父会话可用性横幅(影响续聊入口;不可用时说明恢复路径)。
        if (!catalog.parentAvailable)
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
        Expanded(
          child: ListView(
            children: [
              for (final entry in catalog.entries) _entryRow(context, entry),
            ],
          ),
        ),
      ],
    );
  }

  Widget _entryRow(BuildContext context, SubagentListEntry entry) {
    if (entry is SubagentListEntryChild) {
      final running = entry.activity == 'running';
      final continuable =
          entry.mode == 'continuable' && _catalog?.parentAvailable == true;
      final title = subagentEntryTitle(entry);
      return ListTile(
        onTap: () => _open(entry),
        leading: _StatusDot(running: running),
        title: Text(title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          (entry.mode == 'continuable' ? '可续聊' : '一次性') +
              (running ? ' · 运行中' : ''),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: () => _open(entry), child: const Text('查看')),
            if (continuable)
              TextButton(
                onPressed: () => _open(entry, autoFocusInput: true),
                child: const Text('续聊'),
              ),
          ],
        ),
      );
    }
    // diagnostic:保留可读但禁用(corrupt/unsupported/unavailable)。
    final reason = entry is SubagentListEntryDiagnostic
        ? entry.reason.toString()
        : 'unknown';
    return ListTile(
      enabled: false,
      leading: const Icon(Icons.error_outline, color: Colors.grey),
      title: Text('诊断($reason)',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: const Text('该子代理不可用',
          style: TextStyle(fontSize: 12)),
    );
  }
}

/// 子会话 transcript 页:只读文本事件流 + 条件 composer。
/// - 运行中:输入禁用,保留 Stop(subagent.interrupt)
/// - 一次性 / 父会话不可用:只读说明,无输入
/// - 可续聊(parent 存活且 child inactive):输入框走 promptChild
class SubagentTranscriptPage extends StatefulWidget {
  const SubagentTranscriptPage({
    super.key,
    required this.store,
    required this.parentSessionId,
    required this.child,
    this.autoFocusInput = false,
  });

  final SubagentStore store;
  final String parentSessionId;
  final SubagentListEntryChild child;
  final bool autoFocusInput;

  @override
  State<SubagentTranscriptPage> createState() => _SubagentTranscriptPageState();
}

class _SubagentTranscriptPageState extends State<SubagentTranscriptPage> {
  late final SubagentTranscript _transcript;
  final TextEditingController _input = TextEditingController();
  SubagentListValue? _catalog;
  String? _error;
  bool _sending = false;
  bool _interrupting = false;
  StreamSubscription<List<SessionEvent>>? _eventsSub;
  StreamSubscription<Map<String, SubagentListValue>>? _catalogSub;

  @override
  void initState() {
    super.initState();
    _transcript = widget.store.transcriptFor(widget.child.id);
    _catalog = widget.store.catalogFor(widget.parentSessionId);
    _eventsSub = _transcript.eventStream.listen((_) {
      if (mounted) setState(() {});
    });
    _catalogSub = widget.store.catalogs.listen((map) {
      final v = map[widget.parentSessionId];
      if (mounted && v != null && !identical(v, _catalog)) {
        setState(() => _catalog = v);
      }
    });
    _load();
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
      // prompt 后 activity 应翻转为 running:失效目录让下次拉取更新。
      widget.store.invalidateChildren(widget.parentSessionId);
      await widget.store.listChildren(widget.parentSessionId);
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
      widget.store.invalidateChildren(widget.parentSessionId);
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
    _eventsSub?.cancel();
    _catalogSub?.cancel();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    return Scaffold(
      appBar: AppBar(title: Text(subagentEntryTitle(child), overflow: TextOverflow.ellipsis)),
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

  /// 事件列表:前导条目(加载更早/错误提示)+ 事件本体,全部走 ListView.builder
  /// 虚拟化 —— 单页 transcript 可达上千事件,一次性 children 全构建会卡 UI。
  Widget _buildEventList() {
    final events = _transcript.events;
    final leading = <Widget>[
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
    ];
    final trailingCount =
        events.isEmpty && _error == null ? 1 : 0; // 空态占位。
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: leading.length + events.length + trailingCount,
      itemBuilder: (context, i) {
        if (i < leading.length) return leading[i];
        final eventIndex = i - leading.length;
        if (eventIndex < events.length) {
          return _eventTile(context, events[eventIndex]);
        }
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Center(
              child: Text('该子代理暂无事件',
                  style: TextStyle(color: Colors.grey))),
        );
      },
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
  /// 可续聊→输入+发送。
  Widget _composer(BuildContext context) {
    final child = widget.child;
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
