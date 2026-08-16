// M3 交互卡片:审批卡、问答表单、队列 Dock。
// 纪律:question 表单的 label 选择严格来自帧的 options(精确字符串回传),
// 批次完整性由 InteractorStore.validateQuestionAnswers 预校验兜底。
// 刷新安全(硬性):卡片以 rpcId 稳定 key 挂载 —— 列表增删/父级重建
// 不会丢失已选选项与已输入文本;种子态来自 store.current* 快照,
// 错过流事件的渲染也能自愈(重连重放场景)。
import 'package:flutter/material.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 审批卡:列出待审批,allow/deny 二键。
/// [sessionLabel] 非空时显示归属会话徽标(多会话并行的审批面)。
class ApprovalCards extends StatelessWidget {
  const ApprovalCards({
    super.key,
    required this.approvals,
    required this.onRespond,
    this.sessionLabel,
  });
  final List<PendingApproval> approvals;
  final void Function(PendingApproval approval, bool allow) onRespond;

  /// rpcId → 会话短标签(归属非当前会话时展示;空表 = 当前会话)。
  final Map<String, String>? sessionLabel;

  @override
  Widget build(BuildContext context) {
    if (approvals.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final a in approvals)
          Container(
            key: ValueKey('approval-${a.rpcId}'),
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            decoration: BoxDecoration(
              color: colors.tertiaryContainer.withValues(alpha: .9),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.tertiary.withValues(alpha: .45)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: colors.tertiary.withValues(alpha: .16),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.gavel_outlined,
                          size: 17,
                          color: colors.tertiary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '审批请求',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: colors.onTertiaryContainer.withValues(alpha: .8),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              a.toolName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                          ],
                        ),
                      ),
                      if (_labelOf(a) != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: colors.surface.withValues(alpha: .6),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            _labelOf(a)!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (a.reason != null && a.reason!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colors.surface.withValues(alpha: .5),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          a.reason!,
                          style: const TextStyle(fontSize: 12.5, height: 1.4),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Spacer(),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(88, 44),
                        ),
                        onPressed: () => onRespond(a, false),
                        child: const Text('拒绝'),
                      ),
                      const SizedBox(width: 10),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(104, 44),
                        ),
                        onPressed: () => onRespond(a, true),
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('允许一次'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  String? _labelOf(PendingApproval a) {
    final label = sessionLabel?[a.rpcId];
    if (label == null || label.isEmpty) return null;
    return label;
  }
}

/// 问答表单:批次内每题渲染(header/question/detail/options/multiSelect);
/// 提交前走预校验,校验失败内联显示(不清空已填内容);
/// custom 文本框只在 multiSelect 题出现(协议语义:custom 仅多选题可带)。
/// onSubmitted 异步回执:not-pending / bad-response 内联提示。
class QuestionForm extends StatefulWidget {
  const QuestionForm({
    super.key,
    required this.question,
    required this.onSubmit,
    this.onDismiss,
    this.sessionLabel,
  });
  final PendingQuestion question;

  /// 提交:返回 null = 通过(帧已被主机收走);否则为回执错误文案。
  final Future<String?> Function(List<QuestionAnswerDraft> drafts) onSubmit;
  final VoidCallback? onDismiss;

  /// 归属会话短标签(跨会话问题时显示;null = 当前会话)。
  final String? sessionLabel;

  @override
  State<QuestionForm> createState() => _QuestionFormState();
}

class _QuestionFormState extends State<QuestionForm> {
  final _selections = <String, Set<String>>{};
  final _customs = <String, TextEditingController>{};
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    for (final c in _customs.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _error = null);
    final drafts = <QuestionAnswerDraft>[];
    for (final q in widget.question.questions) {
      final sel = (_selections[q.id] ?? const <String>{}).toList();
      final controller = _customs[q.id];
      final custom = controller == null ? null : controller.text;
      drafts.add(QuestionAnswerDraft(questionId: q.id, selected: sel, custom: custom));
    }
    setState(() => _submitting = true);
    try {
      final err = await widget.onSubmit(drafts);
      if (mounted && err != null) setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final qs = widget.question.questions;
    return Container(
      key: ValueKey('question-${widget.question.rpcId}'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.secondary.withValues(alpha: .5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colors.secondary.withValues(alpha: .16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.contact_support_outlined,
                    size: 17,
                    color: colors.secondary,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('代理提问', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                ),
                if (widget.sessionLabel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: colors.surface.withValues(alpha: .6),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      widget.sessionLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            for (final q in qs) ..._questionBlock(q, colors),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colors.errorContainer.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 12, color: colors.error),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onDismiss != null)
                  TextButton(onPressed: widget.onDismiss, child: const Text('稍后')),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(88, 44)),
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('提交'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _questionBlock(AskUserQuestionItem q, ColorScheme colors) {
    final multi = q.multiSelect == true;
    final options = q.options ?? const <Map<String, dynamic>>[];
    return [
      const SizedBox(height: 12),
      if (q.header != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: colors.secondary.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            q.header!,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ),
      const SizedBox(height: 6),
      Text(
        q.question,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.4),
      ),
      if (q.detail != null)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            q.detail!,
            style: TextStyle(fontSize: 12, height: 1.4, color: colors.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 4),
      for (final o in options) _optionTile(q, o, multi, colors),
      if (multi) ..._customField(q, colors),
    ];
  }

  Widget _optionTile(
    AskUserQuestionItem q,
    Map<String, dynamic> option,
    bool multi,
    ColorScheme colors,
  ) {
    final label = option['label'] as String;
    final desc = option['description'] as String?;
    final selected = _selections[q.id]?.contains(label) ?? false;
    final tile = ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      minVerticalPadding: 4,
      leading: _ChoiceMarker(
        multi: multi,
        selected: selected,
        color: colors.secondary,
      ),
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      subtitle: desc != null
          ? Text(desc, style: const TextStyle(fontSize: 11.5, height: 1.3))
          : null,
      onTap: () {
        setState(() {
          final set = _selections.putIfAbsent(q.id, () => <String>{});
          if (multi) {
            selected ? set.remove(label) : set.add(label);
          } else {
            set
              ..clear()
              ..add(label);
          }
        });
      },
    );
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: selected ? colors.secondary.withValues(alpha: .1) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? colors.secondary.withValues(alpha: .5) : Colors.transparent,
        ),
      ),
      child: tile,
    );
  }

  /// custom 输入(multiSelect 专属;协议:custom 仅多选可带、空串拒)。
  List<Widget> _customField(AskUserQuestionItem q, ColorScheme colors) {
    final controller = _customs.putIfAbsent(q.id, TextEditingController.new);
    return [
      const SizedBox(height: 4),
      TextField(
        controller: controller,
        onChanged: (_) => setState(() {}),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: '补充自定义内容(可选)',
          prefixIcon: const Icon(Icons.edit_note, size: 18),
          filled: true,
          fillColor: colors.surface.withValues(alpha: .75),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
    ];
  }
}

/// 选项标记:单选圆点 / 多选方勾(语义区分,纯视觉)。
class _ChoiceMarker extends StatelessWidget {
  const _ChoiceMarker({required this.multi, required this.selected, required this.color});
  final bool multi;
  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (multi) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: selected ? color : Theme.of(context).colorScheme.outline, width: 1.8),
          color: selected ? color : Colors.transparent,
        ),
        child: selected
            ? const Icon(Icons.check, size: 14, color: Colors.white)
            : null,
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? color : Theme.of(context).colorScheme.outline, width: 1.8),
        color: selected ? color : Colors.transparent,
      ),
      child: selected
          ? Center(
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            )
          : null,
    );
  }
}

/// 队列 Dock:某会话的待处理收件箱快照(session/queue 整帧收敛语义)。
/// 仅显示 placement == 'queued' 的项(web QueueDock 同款;steering/context
/// 项不是待处理输入)。每项提供 移除 / 插话(仅 running 可用)动作。
class QueueDock extends StatelessWidget {
  const QueueDock({
    super.key,
    required this.items,
    required this.running,
    this.onRemove,
    this.onSteer,
  });

  /// 会话队列快照(原始 map:{id, placement, message})。
  final List<Map<String, dynamic>> items;

  /// 当前会话 running(插话仅运行中可用 —— host 窗口语义)。
  final bool running;

  final void Function(Map<String, dynamic> item)? onRemove;

  /// 插话:把该排队项提升为 steering(session.updateQueue kind:'steer')。
  final void Function(Map<String, dynamic> item)? onSteer;

  /// 排队项(placement == 'queued')。
  List<Map<String, dynamic>> get _queued => [
        for (final item in items)
          if (item['placement'] == 'queued') item,
      ];

  /// 队列项 id(host schema:id: MessageId;防御缺失)。
  static String? itemIdOf(Map<String, dynamic> item) =>
      item['id'] is String ? item['id'] as String : null;

  @override
  Widget build(BuildContext context) {
    final queued = _queued;
    if (queued.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .4)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule_send_outlined, size: 15, color: colors.primary),
              const SizedBox(width: 6),
              Text(
                '排队消息(' + queued.length.toString() + ')',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
              ),
            ],
          ),
          for (final item in queued)
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(
                Icons.schedule,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              title: Text(
                _preview(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (onRemove != null && itemIdOf(item) != null)
                  IconButton(
                    tooltip: '移除',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => onRemove!(item),
                  ),
                if (onSteer != null && itemIdOf(item) != null)
                  IconButton(
                    // web locale queue.steer / queue.steer.unavailable。
                    tooltip: running ? '插话发送' : '仅运行中可插话发送',
                    icon: Icon(
                      Icons.send_outlined,
                      size: 18,
                      color: running ? colors.primary : colors.onSurfaceVariant,
                    ),
                    onPressed: running ? () => onSteer!(item) : null,
                  ),
              ]),
            ),
        ],
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
