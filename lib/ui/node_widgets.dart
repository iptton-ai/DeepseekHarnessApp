// ChatNodeList — 会话流节点渲染(web 同款节点流的 Flutter 版)。
// 输入来自 sessions/event_nodes.dart 的 List[ChatNode],纯展示无业务逻辑。
// 移动纪律(硬性):触控行 ≥44dp、工具详情横向滚动 + 点击全屏 dialog、
// 气泡全文不截断;hover 语义全部改为常显按钮/常显触发行。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:singleman/sessions/attachment_fetch.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/sessions/feedback_store.dart';
import 'package:singleman/ui/attachment_views.dart';
import 'package:singleman/ui/feedback_row.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 常显触控高度下限(移动可用性硬性要求)。
const double kNodeTapHeight = 44;

/// 会话流节点列表:输入 [nodes],渲染整条消息流。
/// 折叠状态由各节点自持(重放/重建时按位置稳定),本层不做外部记忆。
class ChatNodeList extends StatelessWidget {
  const ChatNodeList({super.key, required this.nodes, this.padding, this.sessionId, this.attachmentFetcher, this.feedbackStore});
  final List<ChatNode> nodes;

  /// 图片附件渲染(W2-C):会话 id + 共享 fetcher;缺席时图片引用不渲染。
  final String? sessionId;
  final AttachmentFetchView? attachmentFetcher;

  /// 消息反馈(W3-B):注入时助手消息下缘挂 FeedbackActions;缺席不渲染。
  final FeedbackStoreView? feedbackStore;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) return const SizedBox.shrink();
    return ListView.builder(
      padding: padding ?? const EdgeInsets.all(12),
      itemCount: nodes.length,
      itemBuilder: (context, i) => _nodeWidget(context, nodes[i]),
    );
  }

  Widget _nodeWidget(BuildContext context, ChatNode node) {
    final sid = sessionId;
    final fetcher = (sid != null) ? attachmentFetcher : null;
    return switch (node) {
      ChatNodeUser() => _UserBubble(text: node.text, images: node.images, sessionId: sid, fetcher: fetcher),
      ChatNodeAssistant() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AssistantBubble(text: node.text, images: node.images, sessionId: sid, fetcher: fetcher),
          // W3-B:助手消息反馈(👍/👎/备注;messageId 用事件 seq 字符串)。
          if (sid != null && feedbackStore != null)
            FeedbackActions(
              store: feedbackStore!,
              sessionId: sid,
              messageId: node.seq.toString(),
            ),
        ],
      ),
      ChatNodeThink() => _ThinkBlock(text: node.text),
      ChatNodeTool() => _ToolCard(node: node),
      ChatNodeTodo() => _TodoCard(node: node),
      ChatNodeCompaction() => _CompactionRow(node: node),
      ChatNodeRetry() => _InlineNotice(
          icon: Icons.refresh,
          text: _retryText(node),
          color: Theme.of(context).colorScheme.outline,
        ),
      ChatNodeError() => _InlineNotice(
          icon: Icons.error_outline,
          text: node.message,
          color: Theme.of(context).colorScheme.error,
        ),
      ChatNodeUnknown() => _UnknownRow(node: node),
    };
  }
}

/// 用户气泡:右对齐,全文不截断。
class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, this.images, this.sessionId, this.fetcher});
  final String text;
  final List<ImageAttachmentRef>? images;
  final String? sessionId;
  final AttachmentFetchView? fetcher;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.62,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (text.isNotEmpty) Text(text),
            if (images != null && images!.isNotEmpty && sessionId != null && fetcher != null)
              MessageImages(
                sessionId: sessionId!,
                refs: images!,
                fetcher: fetcher!,
                alignment: WrapAlignment.end,
              ),
          ],
        ),
      ),
    );
  }
}

/// 助手气泡:markdown 渲染(flutter_markdown),全文不截断。
class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.text, this.images, this.sessionId, this.fetcher});
  final String text;
  final List<ImageAttachmentRef>? images;
  final String? sessionId;
  final AttachmentFetchView? fetcher;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (text.isNotEmpty)
            MarkdownBody(
              data: text,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                p: const TextStyle(fontSize: 14),
                codeblockDecoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
          if (images != null && images!.isNotEmpty && sessionId != null && fetcher != null)
            MessageImages(
              sessionId: sessionId!,
              refs: images!,
              fetcher: fetcher!,
            ),
        ],
      ),
    );
  }
}

/// think 折叠块:默认收起,整行 ≥44dp 可点,展开显示全文。
class _ThinkBlock extends StatefulWidget {
  const _ThinkBlock({required this.text});
  final String text;

  @override
  State<_ThinkBlock> createState() => _ThinkBlockState();
}

class _ThinkBlockState extends State<_ThinkBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kNodeTapHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.psychology_outlined,
                      size: 18,
                      color: theme.colorScheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('思考过程',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: SelectableText(
                widget.text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 工具卡:图标 + 名称 + 摘要行;点击展开输入/输出详情(等宽横向滚动),
/// 详情内常显「全屏查看」按钮 → 全屏 dialog。状态色:运行/成功/失败/中断。
class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.node});
  final ChatNodeTool node;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final color = _statusColor(context, node.status);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kNodeTapHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(_toolIcon(node.toolName), size: 18, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            node.toolName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                          if (node.summary != null && node.summary!.isNotEmpty)
                            Text(
                              node.summary!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusBadge(status: node.status),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            _ToolDetail(node: node),
          ],
        ],
      ),
    );
  }
}

/// 工具详情:输入/输出(等宽、横向滚动)+ 全屏查看按钮。
class _ToolDetail extends StatelessWidget {
  const _ToolDetail({required this.node});
  final ChatNodeTool node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inputText = _formatValue(node.input);
    final outputText = _formatValue(node.output);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (node.error != null && node.error!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '错误: ${node.error!}',
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),
          if (inputText.isNotEmpty) ...[
            const Text('输入',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            _MonoScroll(text: inputText),
          ],
          if (outputText.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('输出',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            _MonoScroll(text: outputText),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              // hover 语义改常显按钮:全屏 dialog(移动友好)。
              onPressed: () => _openFullscreen(context),
              icon: const Icon(Icons.fullscreen, size: 16),
              label: const Text('全屏查看'),
            ),
          ),
        ],
      ),
    );
  }

  void _openFullscreen(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(node.toolName),
            actions: [
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              _fullscreenText(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ),
      ),
    );
  }

  String _fullscreenText() {
    final parts = <String>['工具: ${node.toolName}'];
    if (node.callId != null) {
      parts.add('调用号: ${node.callId!}');
    }
    final input = _formatValue(node.input);
    if (input.isNotEmpty) {
      parts.add('\n输入:\n$input');
    }
    final output = _formatValue(node.output);
    if (output.isNotEmpty) {
      parts.add('\n输出:\n$output');
    }
    if (node.error != null && node.error!.isNotEmpty) {
      parts.add('\n错误:\n${node.error!}');
    }
    return parts.join('\n');
  }
}

/// 等宽 + 横向滚动块(宽内容不挤爆行)。
class _MonoScroll extends StatelessWidget {
  const _MonoScroll({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}

/// 状态徽标:色点 + 状态词(运行中/成功/失败/中断)。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final ToolStatus status;

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            _statusLabel(status),
            style: TextStyle(fontSize: 11, color: color),
          ),
        ],
      ),
    );
  }
}

Color _statusColor(BuildContext context, ToolStatus status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    ToolStatus.running => Colors.blue.shade600,
    ToolStatus.success => Colors.green.shade700,
    ToolStatus.failed => scheme.error,
    ToolStatus.interrupted => Colors.orange.shade800,
  };
}

String _statusLabel(ToolStatus status) => switch (status) {
      ToolStatus.running => '运行中',
      ToolStatus.success => '成功',
      ToolStatus.failed => '失败',
      ToolStatus.interrupted => '中断',
    };

IconData _toolIcon(String toolName) {
  final n = toolName.toLowerCase();
  if (n.contains('bash') || n.contains('shell') || n.contains('exec') || n.contains('sh')) {
    return Icons.terminal;
  }
  if (n.contains('write') || n.contains('edit') || n.contains('file') || n.contains('patch')) {
    return Icons.edit_document;
  }
  if (n.contains('search') || n.contains('web') || n.contains('browse') || n.contains('fetch')) {
    return Icons.travel_explore;
  }
  if (n.contains('read') || n.contains('view') || n.contains('ls')) {
    return Icons.menu_book;
  }
  return Icons.construction;
}

/// todo 计划快照:紧凑状态计数卡。
class _TodoCard extends StatelessWidget {
  const _TodoCard({required this.node});
  final ChatNodeTodo node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allDone = node.total > 0 && node.done == node.total;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              allDone ? Icons.check_circle : Icons.checklist,
              size: 18,
              color: allDone ? Colors.green.shade700 : theme.colorScheme.tertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '计划 ${node.total} 项 · 完成 ${node.done} 项',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 压缩检查点:可展开行(默认收起),展开显示摘要/消息数。
class _CompactionRow extends StatefulWidget {
  const _CompactionRow({required this.node});
  final ChatNodeCompaction node;

  @override
  State<_CompactionRow> createState() => _CompactionRowState();
}

class _CompactionRowState extends State<_CompactionRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = widget.node;
    final kindLabel = switch (node.kind) {
      'start' => '压缩开始',
      'end' => '压缩结束',
      'summary' => '压缩摘要',
      _ => '压缩',
    };
    final detail = node.summary ??
        (node.messages != null ? '压缩 ${node.messages} 条消息' : null);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kNodeTapHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.compress, size: 18, color: theme.colorScheme.outline),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(kindLabel,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded && detail != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: SelectableText(detail, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}

/// 重试/错误的内联细行(非卡片,不占触控目标——纯信息)。
class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color, height: 1.3)),
          ),
        ],
      ),
    );
  }
}

String _retryText(ChatNodeRetry node) {
  final head = '重试${node.attempt != null ? '(第 ${node.attempt} 次)' : ''}';
  final reason = node.reason;
  return reason == null || reason.isEmpty ? head : '$head: $reason';
}

/// 未知类型兜底:类型名 + 原始 data 折叠展示。
class _UnknownRow extends StatefulWidget {
  const _UnknownRow({required this.node});
  final ChatNodeUnknown node;

  @override
  State<_UnknownRow> createState() => _UnknownRowState();
}

class _UnknownRowState extends State<_UnknownRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kNodeTapHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.help_outline, size: 18, color: theme.colorScheme.outline),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '未知事件: ${widget.node.type}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: _MonoScroll(text: _formatValue(widget.node.data)),
            ),
        ],
      ),
    );
  }
}

/// 值 → 可读文本(Map/List 走缩进 JSON,标量直出)。
String _formatValue(dynamic v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  try {
    return const JsonEncoder.withIndent('  ').convert(v);
  } catch (_) {
    return v.toString();
  }
}
