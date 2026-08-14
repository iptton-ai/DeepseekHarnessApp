// ChatScreen — M2 最小 UI:会话侧栏 + 纯文本消息流 + 输入框。
// 只消费 ChatViewModel(ChangeNotifier),不含任何 socket/HTTP 逻辑。
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/wire/generated/wire_generated.dart';
import 'package:singleman/ui/interactor_widgets.dart';
import 'package:singleman/ui/interactor_widgets.dart';

/// 会话操作回调束(M4:模型/搜索/fork/导出/重命名;main 注入)。
class SessionActions {
  const SessionActions({
    this.onPickModel,
    this.onRename,
    this.onFork,
    this.onExport,
  });
  final VoidCallback? onPickModel;
  final void Function(String sessionId, String title)? onRename;
  final void Function(String sessionId)? onFork;
  final void Function(String sessionId)? onExport;
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.vm, this.onNewSession, this.actions});
  final ChatViewModel vm;
  final VoidCallback? onNewSession;
  final SessionActions? actions;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: vm,
      builder: (context, _) {
        return Scaffold(
          body: Row(
            children: [
              _Sidebar(vm: vm, onNewSession: onNewSession, actions: actions),
              const VerticalDivider(width: 1),
              Expanded(
                child: _MessagePane(
                  vm: vm,
                  onApproval: (a, allow) => vm.interactor?.respondApproval(
                      a.rpcId, a.sessionId, a.approvalId,
                      allow: allow),
                  onQuestion: (q, drafts) {
                    final it = vm.interactor;
                    if (it == null) return;
                    final err = it.validateQuestionAnswers(q, drafts);
                    if (err != null) {
                      vm.lastError = '应答被本地预校验拒绝: ' + err;
                      vm.notifyListeners();
                      return;
                    }
                    final payload = drafts
                        .map((d) => <String, dynamic>{
                              'id': d.questionId,
                              'selected': d.selected,
                              if (d.custom != null && d.custom!.isNotEmpty) 'custom': d.custom,
                            })
                        .toList();
                    it.respondQuestions(q.rpcId, q.sessionId, payload);
                  },
                  onQueueRemove: null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Sidebar extends StatefulWidget {
  const _Sidebar({required this.vm, this.onNewSession, this.actions});
  final ChatViewModel vm;
  final VoidCallback? onNewSession;
  final SessionActions? actions;

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
        .where((s) =>
            s.sessionId.toLowerCase().contains(q) ||
            (s.cwd ?? '').toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return SizedBox(
      width: 260,
      child: Column(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(child: _PhaseBadge(vm: widget.vm)),
                  const SizedBox(width: 8),
                  if (widget.actions?.onPickModel != null)
                    IconButton(
                      tooltip: '选择模型',
                      onPressed: widget.actions!.onPickModel,
                      icon: const Icon(Icons.tune),
                    ),
                  IconButton(
                    tooltip: '新建会话',
                    onPressed: widget.onNewSession,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: '搜索会话',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: visible.isEmpty
                ? const Center(child: Text('无匹配会话', style: TextStyle(fontSize: 12)))
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final s = visible[i];
                      final selected = s.sessionId == widget.vm.selectedId;
                      return ListTile(
                        dense: true,
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
                              : (s.sessionId.split('-')..removeWhere((p) => p.isEmpty)).reversed.take(2).toList().reversed.join('-'),
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
                                    const PopupMenuItem(value: 'rename', child: Text('重命名')),
                                  if (widget.actions?.onFork != null)
                                    const PopupMenuItem(value: 'fork', child: Text('在此分叉')),
                                  if (widget.actions?.onExport != null)
                                    const PopupMenuItem(value: 'export', child: Text('导出 ZIP')),
                                ],
                                onSelected: (v) => _onMenu(v, s.sessionId),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
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
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('确定')),
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

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.vm});
  final ChatViewModel vm;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    switch (vm.phase) {
      case ConnectionPhase.ready:
        color = Colors.green;
        label = 'gen ' + vm.generation.toString();
      case ConnectionPhase.connecting:
        color = Colors.orange;
        label = '连接中';
      case ConnectionPhase.down:
        color = Colors.red;
        label = '已断开,重试中';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.9)),
            ),
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
  });
  final ChatViewModel vm;
  final void Function(PendingApproval a, bool allow)? onApproval;
  final void Function(PendingQuestion q, List<QuestionAnswerDraft> drafts)? onQuestion;
  final void Function(Map<String, dynamic> item)? onQueueRemove;

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController();
    return Column(
      children: [
        Expanded(
          child: vm.bubbles.isEmpty
              ? const Center(child: Text('选择或创建一个会话开始对话'))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: vm.bubbles.length,
                  itemBuilder: (context, i) {
                    final b = vm.bubbles[i];
                    final isUser = b.role == 'user';
                    return Align(
                      alignment:
                          isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        constraints: BoxConstraints(
                          maxWidth:
                              MediaQuery.of(context).size.width * 0.62 - 260,
                        ),
                        decoration: BoxDecoration(
                          color: isUser
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: b.role == 'assistant'
                            ? MarkdownBody(
                                data: b.text,
                                styleSheet: MarkdownStyleSheet.fromTheme(
                                        Theme.of(context))
                                    .copyWith(
                                  p: const TextStyle(fontSize: 14),
                                  codeblockDecoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(6),
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
                ),
        ),
        _InteractorPane(vm: vm, onApproval: onApproval, onQuestion: onQuestion, onQueueRemove: onQueueRemove),
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
            child: _Composer(vm: vm, controller: controller),
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

/// 交互帧面板:审批卡 + 问答表单 + 队列 Dock,自订阅 interactor 流。
class _InteractorPane extends StatefulWidget {
  const _InteractorPane({
    required this.vm,
    this.onApproval,
    this.onQuestion,
    this.onQueueRemove,
  });
  final ChatViewModel vm;
  final void Function(PendingApproval a, bool allow)? onApproval;
  final void Function(PendingQuestion q, List<QuestionAnswerDraft> drafts)? onQuestion;
  final void Function(Map<String, dynamic> item)? onQueueRemove;

  @override
  State<_InteractorPane> createState() => _InteractorPaneState();
}

class _InteractorPaneState extends State<_InteractorPane> {
  List<PendingApproval> _approvals = const [];
  List<PendingQuestion> _questions = const [];
  List<Map<String, dynamic>> _queue = const [];

  @override
  void initState() {
    super.initState();
    final it = widget.vm.interactor;
    if (it == null) return;
    it.approvals.listen((l) {
      if (mounted) setState(() => _approvals = l);
    });
    it.questions.listen((l) {
      if (mounted) setState(() => _questions = l);
    });
    it.queues.listen((m) {
      final sid = widget.vm.selectedId;
      if (mounted && sid != null) {
        setState(() => _queue = m[sid] ?? const []);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ApprovalCards(approvals: _approvals, onRespond: (a, allow) => widget.onApproval?.call(a, allow)),
        for (final q in _questions)
          QuestionForm(question: q, onSubmit: (drafts) => widget.onQuestion?.call(q, drafts)),
        QueueDock(items: _queue, onRemove: widget.onQueueRemove),
      ],
    );
  }
}

/// 发送器绑定:把 UI 与 SessionStore 解耦(main 注入,测试可覆盖)。
class ChatSenderBinding extends InheritedWidget {
  const ChatSenderBinding({
    super.key,
    required this.sender,
    required super.child,
  });
  final Future<void> Function(String sessionId, String text) sender;

  static Future<void> Function(String, String) of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<ChatSenderBinding>();
    assert(w != null, 'ChatSenderBinding missing in tree');
    return w!.sender;
  }

  @override
  bool updateShouldNotify(ChatSenderBinding oldWidget) =>
      oldWidget.sender != sender;
}
