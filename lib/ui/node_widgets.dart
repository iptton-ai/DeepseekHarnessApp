// ChatNodeList — 会话流节点渲染(web 同款节点流的 Flutter 版)。
// 输入来自 sessions/event_nodes.dart 的 List[ChatNode],纯展示无业务逻辑。
// 移动纪律(硬性):触控行 ≥44dp、工具详情横向滚动 + 点击全屏 dialog、
// 气泡全文不截断;hover 语义全部改为常显按钮/常显触发行。
// 展示增强:
// - 自动跟底:新节点到达时,若用户本来就停在列表底部则平滑跟随(翻历史不拽回)。
// - 流式节点:assistant 直播气泡尾部呼吸光标;think 直播时自动展开、定稿收起。
// - 工具卡:状态左缘色条 + 运行中旋转指示 + 常用工具图标词表 + 复制按钮。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:singleman/sessions/attachment_fetch.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/sessions/feedback_store.dart';
import 'package:singleman/ui/attachment_views.dart';
import 'package:singleman/ui/feedback_row.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 常显触控高度下限(移动可用性硬性要求)。
const double kNodeTapHeight = 44;

/// 会话流节点列表:输入 [nodes],渲染整条消息流。
/// 折叠状态由各节点自持,节点以 seq 稳定 key 挂载 —— 列表前插/重排
/// (加载更早历史)不会张冠李戴;重放/重建时按 key 保持展开态。
class ChatNodeList extends StatefulWidget {
  const ChatNodeList({
    super.key,
    required this.nodes,
    this.padding,
    this.sessionId,
    this.attachmentFetcher,
    this.feedbackStore,
  });
  final List<ChatNode> nodes;

  /// 图片附件渲染(W2-C):会话 id + 共享 fetcher;缺席时图片引用不渲染。
  final String? sessionId;
  final AttachmentFetchView? attachmentFetcher;

  /// 消息反馈(W3-B):注入时助手消息下缘挂 FeedbackActions;缺席不渲染。
  final FeedbackStoreView? feedbackStore;
  final EdgeInsetsGeometry? padding;

  @override
  State<ChatNodeList> createState() => _ChatNodeListState();
}

class _ChatNodeListState extends State<ChatNodeList> {
  final _controller = ScrollController();
  int _lastCount = 0;
  int _lastBottomSeq = 0;
  bool _follow = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (!_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      // 距底 < 120dp 视为「停在底部」,新内容可跟随;否则用户在翻历史,不打扰。
      _follow = max - _controller.offset < 120;
    });
    _lastCount = widget.nodes.length;
    _lastBottomSeq = widget.nodes.isEmpty ? 0 : widget.nodes.last.seq;
    WidgetsBinding.instance.addPostFrameCallback((_) => _snapToEnd());
  }

  @override
  void didUpdateWidget(ChatNodeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodes.isEmpty) {
      _lastCount = 0;
      return;
    }
    if (identical(widget.nodes, oldWidget.nodes)) return;
    final grew = widget.nodes.length > _lastCount ||
        widget.nodes.last.seq != _lastBottomSeq;
    _lastCount = widget.nodes.length;
    _lastBottomSeq = widget.nodes.last.seq;
    if (grew && _follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _snapToEnd());
    }
  }

  void _snapToEnd() {
    if (!mounted || !_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    _controller.jumpTo(max);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nodes.isEmpty) return const SizedBox.shrink();
    return ListView.builder(
      controller: _controller,
      padding: widget.padding ?? const EdgeInsets.fromLTRB(12, 12, 12, 18),
      itemCount: widget.nodes.length,
      itemBuilder: (context, i) {
        final node = widget.nodes[i];
        return KeyedSubtree(
          key: ValueKey('node-${node.seq}-${node.type}-${i == widget.nodes.length - 1 ? 'tail' : 'body'}'),
          child: _nodeWidget(context, node),
        );
      },
    );
  }

  Widget _nodeWidget(BuildContext context, ChatNode node) {
    final sid = widget.sessionId;
    final fetcher = (sid != null) ? widget.attachmentFetcher : null;
    return switch (node) {
      ChatNodeUser() => _UserBubble(
        text: node.text,
        images: node.images,
        sessionId: sid,
        fetcher: fetcher,
      ),
      ChatNodeAssistant() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AssistantBubble(
            text: node.text,
            images: node.images,
            sessionId: sid,
            fetcher: fetcher,
            streaming: node.streaming,
          ),
          // W3-B:助手消息反馈(👍/👎/备注;messageId 用事件 seq 字符串)。
          if (sid != null && widget.feedbackStore != null && !node.streaming)
            FeedbackActions(
              store: widget.feedbackStore!,
              sessionId: sid,
              messageId: node.seq.toString(),
            ),
        ],
      ),
      ChatNodeThink() => _ThinkBlock(text: node.text, streaming: node.streaming),
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
      ChatNodeNotice() => _NoticeRow(node: node),
      ChatNodeUnknown() => _UnknownRow(node: node),
    };
  }
}

/// 用户气泡:右对齐,全文不截断,文本可选中复制。
class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.text,
    this.images,
    this.sessionId,
    this.fetcher,
  });
  final String text;
  final List<ImageAttachmentRef>? images;
  final String? sessionId;
  final AttachmentFetchView? fetcher;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.of(context).size.width;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(40, 6, 4, 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(maxWidth: width > 900 ? 720 : width * 0.86),
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(5),
          ),
          boxShadow: [
            BoxShadow(
              color: colors.primary.withValues(alpha: .08),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (text.isNotEmpty)
              SelectableText(
                text,
                style: TextStyle(color: colors.onPrimaryContainer, height: 1.4),
              ),
            if (images != null &&
                images!.isNotEmpty &&
                sessionId != null &&
                fetcher != null)
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
/// [streaming] 时尾部渲染呼吸光标(直播中),反馈行挂起。
class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({
    required this.text,
    this.images,
    this.sessionId,
    this.fetcher,
    this.streaming = false,
  });
  final String text;
  final List<ImageAttachmentRef>? images;
  final String? sessionId;
  final AttachmentFetchView? fetcher;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.of(context).size.width;
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 6, 40, 6),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      constraints: BoxConstraints(maxWidth: width > 900 ? 760 : width * .9),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(5),
          topRight: Radius.circular(18),
          bottomLeft: Radius.circular(18),
          bottomRight: Radius.circular(18),
        ),
        border: Border.all(
          color: streaming
              ? colors.primary.withValues(alpha: .55)
              : colors.outlineVariant.withValues(alpha: .5),
          width: streaming ? 1.2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: .05),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 16, color: colors.primary),
              const SizedBox(width: 6),
              Text(
                'singleman',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: colors.primary,
                ),
              ),
              const Spacer(),
              if (streaming)
                const _LiveBadge(label: '生成中'),
            ],
          ),
          const SizedBox(height: 4),
          if (text.isNotEmpty)
            MarkdownBody(
              data: streaming ? text + ' ▍' : text,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    p: const TextStyle(fontSize: 14, height: 1.5),
                    codeblockDecoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
            )
          else if (streaming)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: _TypingDots(),
            ),
          if (images != null &&
              images!.isNotEmpty &&
              sessionId != null &&
              fetcher != null)
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

/// 「生成中」呼吸徽标(有限脉冲,避免常驻动画拖垮 pumpAndSettle)。
class _LiveBadge extends StatefulWidget {
  const _LiveBadge({required this.label});
  final String label;

  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FadeTransition(
      opacity: Tween(begin: 1.0, end: .3).animate(_c),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt_rounded, size: 11, color: colors.primary),
            const SizedBox(width: 3),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: colors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 三点打字指示(纯文本未到时占位)。
class _TypingDots extends StatelessWidget {
  const _TypingDots();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .7),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }
}

/// think 折叠块:默认收起,整行 ≥44dp 可点,展开显示全文。
/// streaming 时自动展开并标记「思考中」;定稿(或用户手动)恢复常规折叠态。
class _ThinkBlock extends StatefulWidget {
  const _ThinkBlock({required this.text, this.streaming = false});
  final String text;
  final bool streaming;

  @override
  State<_ThinkBlock> createState() => _ThinkBlockState();
}

class _ThinkBlockState extends State<_ThinkBlock> {
  bool _userExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expanded = _userExpanded || widget.streaming;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: widget.streaming
              ? theme.colorScheme.tertiary.withValues(alpha: .5)
              : theme.colorScheme.outlineVariant.withValues(alpha: .4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _userExpanded = !_userExpanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kNodeTapHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      widget.streaming
                          ? Icons.psychology
                          : Icons.psychology_outlined,
                      size: 18,
                      color: theme.colorScheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.streaming ? '思考中…' : '思考过程',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: widget.streaming
                              ? theme.colorScheme.tertiary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: SelectableText(
                widget.text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 工具卡:状态色左缘条 + 图标 + 名称 + 摘要行;点击展开输入/输出详情
/// (等宽横向滚动),详情内常显「全屏查看」与「复制」按钮 → 全屏 dialog。
/// 状态色:运行/成功/失败/中断;运行中标题带旋转指示。
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
    final theme = Theme.of(context);
    final color = _statusColor(context, node.status);
    final running = node.status == ToolStatus.running;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3.5, color: color.withValues(alpha: .85)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: kNodeTapHeight),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            if (running)
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  valueColor: AlwaysStoppedAnimation(color),
                                ),
                              )
                            else
                              Icon(_toolIcon(node.toolName), size: 18, color: color),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _toolLabel(node.toolName),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (node.summary != null &&
                                      node.summary!.isNotEmpty)
                                    Text(
                                      node.summary!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: theme.colorScheme.onSurfaceVariant
                                            .withValues(alpha: .85),
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
                              color: theme.colorScheme.outline,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_expanded) ...[
                    Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: .35)),
                    _ToolDetail(node: node),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 工具详情:输入/输出(等宽、横向滚动)+ 复制/全屏查看按钮。
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
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '错误: ${node.error!}',
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                ),
              ),
            ),
          if (inputText.isNotEmpty) ...[
            _detailLabel(context, '输入'),
            _MonoScroll(text: inputText),
          ],
          if (outputText.isNotEmpty) ...[
            const SizedBox(height: 8),
            _detailLabel(context, '输出'),
            _MonoScroll(text: outputText),
          ],
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: node.output?.toString() ?? outputText));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(
                      duration: Duration(milliseconds: 1200),
                      content: Text('已复制到剪贴板'),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制'),
              ),
              TextButton.icon(
                // hover 语义改常显按钮:全屏 dialog(移动友好)。
                onPressed: () => _openFullscreen(context),
                icon: const Icon(Icons.fullscreen, size: 16),
                label: const Text('全屏查看'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _detailLabel(BuildContext context, String text) => Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ],
      );

  void _openFullscreen(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(node.toolName),
            actions: [
              IconButton(
                tooltip: '复制全部',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _fullscreenText()));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      duration: Duration(milliseconds: 1200),
                      content: Text('已复制到剪贴板'),
                    ),
                  );
                },
                icon: const Icon(Icons.copy),
              ),
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
    ToolStatus.running => scheme.primary,
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

/// 常用工具 → 人类可读名称。
String _toolLabel(String toolName) {
  final n = toolName.toLowerCase();
  final mapped = switch (n) {
    'bash' || 'shell' => '终端命令',
    'read' => '读取文件',
    'write' => '写入文件',
    'edit' => '编辑文件',
    'glob' => '查找文件',
    'grep' => '搜索内容',
    'todo_write' || 'todo' => '更新计划',
    'web_search' || 'websearch' => '联网搜索',
    'run_code' => '运行代码',
    'ask_user_question' || 'ask' => '向你提问',
    _ when n.contains('goal') => '目标管理',
    _ when n.contains('skill') => '技能调用',
    _ when n.contains('workflow') => '工作流',
    _ when n.contains('subagent') || n.contains('agent') => '子代理',
    _ => toolName,
  };
  return mapped == toolName ? toolName : '$mapped · $toolName';
}

IconData _toolIcon(String toolName) {
  final n = toolName.toLowerCase();
  if (n.contains('bash') ||
      n.contains('shell') ||
      n.contains('exec') ||
      n.contains('sh')) {
    return Icons.terminal;
  }
  if (n.contains('todo') || n.contains('plan')) {
    return Icons.checklist;
  }
  if (n.contains('ask') || n.contains('question')) {
    return Icons.contact_support_outlined;
  }
  if (n.contains('goal')) {
    return Icons.flag_outlined;
  }
  if (n.contains('workflow')) {
    return Icons.account_tree_outlined;
  }
  if (n.contains('subagent') || n.contains('agent')) {
    return Icons.smart_toy_outlined;
  }
  if (n.contains('write') ||
      n.contains('edit') ||
      n.contains('file') ||
      n.contains('patch')) {
    return Icons.edit_document;
  }
  if (n.contains('search') ||
      n.contains('web') ||
      n.contains('browse') ||
      n.contains('fetch')) {
    return Icons.travel_explore;
  }
  if (n.contains('read') || n.contains('view') || n.contains('ls')) {
    return Icons.menu_book;
  }
  return Icons.construction;
}

/// todo 计划快照:进度条 + 状态计数 + 明细折叠。
class _TodoCard extends StatelessWidget {
  const _TodoCard({required this.node});
  final ChatNodeTodo node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allDone = node.total > 0 && node.done == node.total;
    final progress = node.total == 0 ? 0.0 : node.done / node.total;
    final color = allDone ? Colors.green.shade700 : theme.colorScheme.primary;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  allDone ? Icons.check_circle : Icons.checklist,
                  size: 18,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    allDone ? '计划已全部完成(${node.total} 项)' : '计划 ${node.total} 项 · 完成 ${node.done} 项',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(color),
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
      'prune' => '压缩清理',
      _ => '压缩',
    };
    final detail =
        node.summary ??
        (node.messages != null ? '压缩 ${node.messages} 条消息' : null);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: .35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.compress,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        detail == null ? kindLabel : '$kindLabel · $detail',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
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
          if (_expanded && node.summary != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: SelectableText(
                node.summary!,
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

/// 重试/错误的内联细行(非卡片,不占触控目标——纯信息)。
class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.text,
    required this.color,
  });
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
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: color, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

String _retryText(ChatNodeRetry node) {
  final attempt = node.attempt == null
      ? ''
      : (node.maxRetries != null
          ? '(第 ${node.attempt}/${node.maxRetries} 次)'
          : '(第 ${node.attempt} 次)');
  final head = '重试$attempt';
  final reason = node.reason;
  return reason == null || reason.isEmpty ? head : '$head: $reason';
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.node});
  final ChatNodeNotice node;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Container(
        constraints: const BoxConstraints(minHeight: kNodeTapHeight),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: .58),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .38),
          ),
        ),
        child: Row(
          children: [
            Icon(_noticeIcon(node.icon), size: 17, color: colors.primary),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                node.detail == null || node.detail!.isEmpty
                    ? node.title
                    : '${node.title} · ${node.detail}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.check_circle_outline, size: 15, color: colors.tertiary),
          ],
        ),
      ),
    );
  }
}

IconData _noticeIcon(String icon) => switch (icon) {
  'shield' => Icons.shield_outlined,
  'lock' => Icons.lock_outline,
  'approval' => Icons.verified_outlined,
  'sparkle' => Icons.auto_awesome_outlined,
  'terminal' => Icons.terminal,
  'check' => Icons.check_circle_outline,
  'inbox' => Icons.inbox_outlined,
  'target' => Icons.track_changes_outlined,
  'plan' => Icons.edit_note_outlined,
  'schedule' => Icons.schedule_outlined,
  'workflow' => Icons.account_tree_outlined,
  'agents' => Icons.smart_toy_outlined,
  _ => Icons.info_outline,
};

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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: .4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kNodeTapHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.help_outline,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '未知事件: ${widget.node.type}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
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
