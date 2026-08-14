// M3 交互卡片:审批卡、问答表单、队列 Dock。
// 纪律:question 表单的 label 选择严格来自帧的 options(精确字符串回传),
// 批次完整性由 InteractorStore.validateQuestionAnswers 预校验兜底。
import 'package:flutter/material.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 审批卡:列出待审批,allow/deny 二键。
class ApprovalCards extends StatelessWidget {
  const ApprovalCards({
    super.key,
    required this.approvals,
    required this.onRespond,
  });
  final List<PendingApproval> approvals;
  final void Function(PendingApproval approval, bool allow) onRespond;

  @override
  Widget build(BuildContext context) {
    if (approvals.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final a in approvals)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.gavel, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '审批请求:' + a.toolName + (a.callId != null ? ' (' + a.callId! + ')' : ''),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ]),
                  if (a.reason != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(a.reason!, style: const TextStyle(fontSize: 12)),
                    ),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    OutlinedButton(
                      onPressed: () => onRespond(a, false),
                      child: const Text('拒绝'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => onRespond(a, true),
                      child: const Text('允许一次'),
                    ),
                  ]),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 问答表单:批次内每题渲染(header/question/detail/options/multiSelect);
/// 提交前走预校验;custom 文本框只在有 options 的题出现(multiSelect 语义)。
class QuestionForm extends StatefulWidget {
  const QuestionForm({
    super.key,
    required this.question,
    required this.onSubmit,
    this.onDismiss,
  });
  final PendingQuestion question;
  final void Function(List<QuestionAnswerDraft> drafts) onSubmit;
  final VoidCallback? onDismiss;

  @override
  State<QuestionForm> createState() => _QuestionFormState();
}

class _QuestionFormState extends State<QuestionForm> {
  final _selections = <String, Set<String>>{};
  final _customs = <String, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _customs.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final qs = widget.question.questions;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.help_outline, size: 16),
              SizedBox(width: 6),
              Text('代理提问', style: TextStyle(fontWeight: FontWeight.w600)),
            ]),
            for (final q in qs) ..._questionBlock(q),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (widget.onDismiss != null)
                TextButton(onPressed: widget.onDismiss, child: const Text('稍后')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _submit, child: const Text('提交')),
            ]),
          ],
        ),
      ),
    );
  }

  List<Widget> _questionBlock(AskUserQuestionItem q) {
    final multi = q.multiSelect == true;
    final options = q.options ?? const <Map<String, dynamic>>[];
    return [
      const SizedBox(height: 10),
      if (q.header != null)
        Text(q.header!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      Text(q.question!, style: const TextStyle(fontSize: 13)),
      if (q.detail != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(q.detail!, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        ),
      for (final o in options)
        _optionTile(q, o, multi),
    ];
  }

  Widget _optionTile(AskUserQuestionItem q, Map<String, dynamic> option, bool multi) {
    final label = option['label'] as String;
    final desc = option['description'] as String?;
    final selected = _selections[q.id]?.contains(label) ?? false;
    return CheckboxListTile(
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected,
      title: Text(label),
      subtitle: desc != null ? Text(desc, style: const TextStyle(fontSize: 12)) : null,
      onChanged: (v) {
        setState(() {
          final set = _selections.putIfAbsent(q.id, () => <String>{});
          if (multi) {
            v == true ? set.add(label) : set.remove(label);
          } else {
            set
              ..clear()
              ..add(label);
            _customs.remove(q.id)?.dispose();
          }
        });
      },
    );
  }

  void _submit() {
    final drafts = <QuestionAnswerDraft>[];
    for (final q in widget.question.questions) {
      final sel = (_selections[q.id] ?? const <String>{}).toList();
      final controller = _customs[q.id];
      final custom = controller == null ? null : controller.text;
      drafts.add(QuestionAnswerDraft(questionId: q.id, selected: sel, custom: custom));
    }
    widget.onSubmit(drafts);
  }
}

/// 队列 Dock:某会话的待处理收件箱快照(session/queue 整帧收敛语义)。
class QueueDock extends StatelessWidget {
  const QueueDock({
    super.key,
    required this.items,
    required this.onRemove,
  });
  final List<Map<String, dynamic>> items;
  final void Function(Map<String, dynamic> item)? onRemove;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('排队消息(' + items.length.toString() + ')',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            for (final item in items)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  item['placement'] == 'steering'
                      ? Icons.call_split
                      : item['placement'] == 'context'
                          ? Icons.library_books
                          : Icons.schedule,
                  size: 18,
                ),
                title: Text(
                  _preview(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (onRemove != null)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => onRemove!(item),
                    ),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  String _preview(Map<String, dynamic> item) {
    final message = item['message'];
    if (message is! Map) return '(无消息体)';
    final content = message['content'];
    if (content is! List) return '(非文本消息)';
    for (final block in content) {
      if (block is Map && block['type'] == 'text') {
        final t = block['text'];
        if (t is String && t.isNotEmpty) return t;
      }
    }
    return '(非文本消息)';
  }
}
