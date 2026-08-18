// ChatNodeList — 会话流节点渲染(web 同款节点流的 Flutter 版)。
// 输入来自 sessions/event_nodes.dart 的 List[ChatNode],纯展示无业务逻辑。
// 移动纪律(硬性):触控行 ≥44dp、工具详情横向滚动 + 点击全屏 dialog、
// 气泡全文不截断;hover 语义全部改为常显按钮/常显触发行。
// 展示增强:
// - 自动跟底:新节点到达时,若用户本来就停在列表底部则平滑跟随;用户主动
//   滚离底部即停跟随(不打扰翻历史),右下角常显「回到底部」按钮。
// - 流式节点:assistant 直播气泡尾部呼吸光标;think 始终默认收起,直播中
//   标题行显示思考最后一行:先打字效果,满行后窗口锚定行尾向左滑动
//   (最右字符永远是最新字符)。
// - 工具卡:状态左缘色条 + 运行中旋转指示 + 常用工具图标词表 + 复制按钮。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:singleman/sessions/attachment_fetch.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/ui/attachment_views.dart';
import 'package:singleman/ui/deliverables_row.dart';
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
    this.onFork,
    this.onOpenSubagent,
  });
  final List<ChatNode> nodes;

  /// 图片附件渲染(W2-C):会话 id + 共享 fetcher;缺席时图片引用不渲染。
  final String? sessionId;
  final AttachmentFetchView? attachmentFetcher;

  /// 消息操作区「分叉」回调(对齐 web MessageIconActions 的 branch):
  /// 参数 = 锚定消息 seq;缺席时分叉按钮不渲染(复制按钮始终可用)。
  final void Function(int seq)? onFork;

  /// workflow 运行卡成员行点击 → 打开对应子会话 transcript(A7/A10 联动)。
  final void Function(String childSessionId)? onOpenSubagent;
  final EdgeInsetsGeometry? padding;

  @override
  State<ChatNodeList> createState() => _ChatNodeListState();
}

class _ChatNodeListState extends State<ChatNodeList> {
  final _controller = ScrollController();
  int _lastCount = 0;
  int _lastBottomSeq = 0;

  /// 是否自动跟随底部。**只有真正贴底才保持 true**:
  /// 用户做过任何离开底部的滚动(拖拽或 fling)即置 false,并且
  /// **滚回最底端(≈0 误差)才恢复** —— 不再有「底部附近 120dp 就算
  /// 跟随」的宽判(旧版用户短 fling 惯性停在底部附近 → 跟随悄悄恢复
  /// → 下一个流式 delta 把用户拽回底部,表现为 fling 被「抢滚动」)。
  bool _follow = true;

  /// 用户拖拽进行中(此间绝不程序性抢滚动)。
  bool _userDrag = false;

  /// 是否越过「回到底部」按钮的出现阈值:离底部超过**半屏**
  /// (viewportDimension/2;用户诉求 —— 轻微上翻不弹按钮,翻远了才出现)。
  /// 与 [_follow] 独立:_follow 管「贴底自动跟随」(epsilon 级严判),
  /// 本阈值只管按钮可见性。
  bool _pastThreshold = false;

  /// 是否显示「回到底部」按钮:停跟随**且**已越过半屏阈值。
  bool get _showJumpButton => !_follow && _pastThreshold;

  /// 判定「真正贴底」的容差(px):浮点 + 内容增长时序上的极小空隙。
  static const double _kAtBottomEpsilon = 0.5;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScrollTick);
    _lastCount = widget.nodes.length;
    _lastBottomSeq = widget.nodes.isEmpty ? 0 : widget.nodes.last.seq;
    WidgetsBinding.instance.addPostFrameCallback((_) => _snapToEnd());
  }

  void _onScrollTick() {
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    final max = pos.maxScrollExtent;
    // 滚回**真正最底端** → 恢复跟随并撤按钮。仅此一处恢复入口;
    // 底部附近不算 —— 流式期间惯性停在阈值内也不许自动跟随复活。
    if (max - pos.pixels <= _kAtBottomEpsilon) {
      if (!_follow || _pastThreshold) {
        _follow = true;
        _pastThreshold = false;
        _refreshJumpButton();
      }
    }
    // 半屏阈值跨越:只在跨界时 setState(每 tick 重算但不重复刷新)。
    final viewport = pos.viewportDimension;
    final past =
        viewport > 0 && (max - pos.pixels) > viewport / 2;
    if (past != _pastThreshold) {
      _pastThreshold = past;
      _refreshJumpButton();
    }
  }

  void _refreshJumpButton() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ChatNodeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nodes.isEmpty) {
      _lastCount = 0;
      _lastBottomSeq = 0;
      if (!_follow || _pastThreshold) {
        _follow = true;
        _pastThreshold = false;
        _refreshJumpButton();
      }
      return;
    }
    if (identical(widget.nodes, oldWidget.nodes) &&
        widget.sessionId == oldWidget.sessionId) {
      return;
    }
    // 会话切换:滚动上下文整体作废,回到贴底跟随态。
    final sessionChanged = widget.sessionId != oldWidget.sessionId;
    if (sessionChanged && (!_follow || _pastThreshold)) {
      _follow = true;
      _pastThreshold = false;
      _refreshJumpButton();
    }
    final grew = widget.nodes.length > _lastCount ||
        widget.nodes.last.seq != _lastBottomSeq;
    _lastCount = widget.nodes.length;
    _lastBottomSeq = widget.nodes.last.seq;
    if ((grew || sessionChanged) && _follow && !_userDrag) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _snapToEnd());
    }
  }

  /// 贴底收敛。ListView 惰性构建:一次 jumpTo 后新条目才物化,
  /// maxScrollExtent 会继续长(一次跳不到真底部),需要逐帧追到收敛;
  /// 有界(passes)防活内容下无限追。中止条件三选一:用户拖拽 /
  /// 用户已滚离底部(跟随关闭——收敛循环绝不能把用户拽回来) /
  /// pass 耗尽。
  void _convergeToBottom(int passes) {
    if (!mounted ||
        !_controller.hasClients ||
        passes <= 0 ||
        _userDrag ||
        !_follow) {
      return;
    }
    final pos = _controller.position;
    if (pos.maxScrollExtent - pos.pixels <= _kAtBottomEpsilon) return;
    _controller.jumpTo(pos.maxScrollExtent);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _convergeToBottom(passes - 1));
  }

  void _snapToEnd() => _convergeToBottom(48);

  Future<void> _animateToBottom() async {
    if (!mounted || !_controller.hasClients) return;
    _follow = true;
    _pastThreshold = false;
    _refreshJumpButton();
    await _controller.animateTo(
      _controller.position.maxScrollExtent,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
    // 动画落点后惰性物化可能又长出新空间,再收敛几帧。
    if (mounted) _convergeToBottom(12);
  }

  bool _onScrollNotification(ScrollNotification n) {
    // 拖拽起止:拖拽期间不程序性抢滚动。
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _userDrag = true;
    } else if (n is ScrollEndNotification) {
      _userDrag = false;
    }
    // 用户朝更早内容方向滚 → 立即停跟随并亮出「回到底部」。
    final userUp =
        (n is UserScrollNotification && n.direction == ScrollDirection.reverse) ||
            (n is ScrollUpdateNotification &&
                n.dragDetails != null &&
                (n.scrollDelta ?? 0) < 0);
    if (userUp && _follow) {
      _follow = false;
      _refreshJumpButton();
    }
    return false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.nodes.isEmpty) return const SizedBox.shrink();
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: ListView.builder(
            controller: _controller,
            padding: widget.padding ?? const EdgeInsets.fromLTRB(12, 12, 12, 18),
            // 拖动列表即收键盘(iOS 标准交互;键盘挡屏实报)。
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            itemCount: widget.nodes.length,
            itemBuilder: (context, i) {
              final node = widget.nodes[i];
              return KeyedSubtree(
                key: ValueKey('node-${node.seq}-${node.type}-${i == widget.nodes.length - 1 ? 'tail' : 'body'}'),
                child: _nodeWidget(context, node),
              );
            },
          ),
        ),
        // 回到底部:仅在用户滚离底部(停跟随)时常显;点击平滑回底并恢复跟随。
        Positioned(
          right: 14,
          bottom: 14,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: anim, child: child),
            ),
            child: _showJumpButton
                ? FloatingActionButton(
                    key: const ValueKey('scroll-to-bottom'),
                    tooltip: '滚动到底部',
                    onPressed: _animateToBottom,
                    elevation: 3,
                    child: const Icon(Icons.arrow_downward_rounded),
                  )
                : const SizedBox.shrink(key: ValueKey('scroll-to-bottom-hidden')),
          ),
        ),
      ],
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
        steering: node.steering,
        time: node.time,
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
          // 消息操作区(对齐 web MessageIconActions):定稿后常显
          // 复制 + 分叉 + 时间戳(A2:web clock 语义的移动常显版)。
          // 反馈(👍/👎)不渲染 —— 2026-08-17 活体复验:本机 rc.6 web
          // bundle 不含 ui-message-feedback(master 默认装配才有),按
          // 「web 用户看不到的 Flutter 不多显示」保持不接线(RENDER-
          // PARITY-PLAN Q1 结论;升级 rc.7+ 后重验再挂 FeedbackActions)。
          if (!node.streaming)
            _AssistantActions(
              text: node.text,
              seq: node.seq,
              onFork: widget.onFork,
              time: node.time,
              runMs: node.runMs,
              ttftMs: node.ttftMs,
              tokensPerSecond: node.tokensPerSecond,
            ),
        ],
      ),
      ChatNodeThink() => _ThinkBlock(text: node.text, streaming: node.streaming),
      ChatNodeTool() => _ToolCard(node: node),
      ChatNodeTodo() => _TodoCard(node: node),
      ChatNodeCompaction() => _CompactionRow(node: node),
      ChatNodeContextRow() => _ContextRow(node: node),
      ChatNodeCommand() => _CommandCard(node: node),
      ChatNodeWorkflowRun() => _WorkflowRunCard(
        node: node,
        onOpenChild: widget.onOpenSubagent,
      ),
      ChatNodeDeliverables() => Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
        child: ProducedFilesRow(paths: node.paths),
      ),
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
/// [steering] = 运行中被接纳的插话(A6):头部「插话」徽标。
class _UserBubble extends StatelessWidget {
  const _UserBubble({
    required this.text,
    this.images,
    this.sessionId,
    this.fetcher,
    this.steering = false,
    this.time,
  });
  final String text;
  final List<ImageAttachmentRef>? images;
  final String? sessionId;
  final AttachmentFetchView? fetcher;
  final bool steering;
  final double? time;

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
            if (steering)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.alt_route_rounded,
                      size: 12,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '插话',
                      key: const ValueKey('steering-badge'),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: colors.primary,
                      ),
                    ),
                  ],
                ),
              ),
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
            if (time != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  formatNodeTime(time!),
                  key: const ValueKey('user-time'),
                  style: TextStyle(
                    fontSize: 10,
                    color: colors.onPrimaryContainer.withValues(alpha: .6),
                  ),
                ),
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
                'DshAPP',
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

/// 定稿助手消息的操作行(对齐 web MessageIconActions):复制(全文进
/// 剪贴板,点击后图标短暂变 ✓ 反馈)+ 分叉(fork atSeq=消息 seq,
/// 缺回调时不渲染分叉)。常显(移动纪律:hover-only 改常显);
/// 触控目标 ≥44dp 由 IconButton visualDensity 补足。
class _AssistantActions extends StatefulWidget {
  const _AssistantActions({
    required this.text,
    required this.seq,
    this.onFork,
    this.time,
    this.runMs,
    this.ttftMs,
    this.tokensPerSecond,
  });

  final String text;
  final int seq;
  final void Function(int seq)? onFork;

  /// 消息时间戳(A2:web MessageIconActions 的 clock 常显化)。
  final double? time;

  /// 轮末指标(A2:web「Ran for/TTFT/tok-s」;仅完成轮的最后一条消息携带)。
  final double? runMs;
  final double? ttftMs;
  final double? tokensPerSecond;

  @override
  State<_AssistantActions> createState() => _AssistantActionsState();
}

class _AssistantActionsState extends State<_AssistantActions> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    // 800ms 后图标复原(足够看到反馈,不停留成永久状态)。
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  /// 轮末指标文本:Ran for 45.2s · TTFT 800ms · 12.3 tok/s
  ///(任一缺席即省略对应段;全缺席不渲染本行)。
  String _metricsText() {
    final parts = <String>[
      if (widget.runMs != null) formatDurationMs(widget.runMs!),
      if (widget.ttftMs != null)
        'TTFT ${widget.ttftMs!.round()}ms',
      if (widget.tokensPerSecond != null)
        widget.tokensPerSecond! >= 100
            ? '${widget.tokensPerSecond!.round()}/s'
            : '${(widget.tokensPerSecond! * 10).round() / 10} tok/s',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onFork = widget.onFork;
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.runMs != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                _metricsText(),
                key: const ValueKey('assistant-metrics'),
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ] else if (widget.time != null) ...[
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                formatNodeTime(widget.time!),
                key: const ValueKey('assistant-time'),
                style: TextStyle(
                  fontSize: 10,
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
          IconButton(
            tooltip: _copied ? '已复制' : '复制全文',
            visualDensity: VisualDensity.compact,
            onPressed: _copy,
            icon: Icon(
              _copied ? Icons.check : Icons.copy,
              size: 16,
              color: _copied
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
          ),
          if (onFork != null)
            IconButton(
              tooltip: '从此处分叉新会话',
              visualDensity: VisualDensity.compact,
              onPressed: () => onFork(widget.seq),
              icon: Icon(
                Icons.call_split,
                size: 16,
                color: theme.colorScheme.outline,
              ),
            ),
        ],
      ),
    );
  }
}

/// think 折叠块:**始终默认收起**(直播中也不抢占滚动),整行 ≥44dp 可点,
/// 展开显示全文。直播(streaming)时标题行显示思考正文的最后一行
/// (过滤空行与首尾空白):未超宽 = 逐字追加的打字效果;超宽后窗口锚定
/// 行尾向左滑动(最右字符永远是最新字符);定稿后恢复常规「思考过程」标题。
class _ThinkBlock extends StatefulWidget {
  const _ThinkBlock({required this.text, this.streaming = false});
  final String text;
  final bool streaming;

  @override
  State<_ThinkBlock> createState() => _ThinkBlockState();
}

class _ThinkBlockState extends State<_ThinkBlock> {
  bool _userExpanded = false;

  /// 展开态展示上限(字符);超长思考全文走分块查看器。
  static const int _kThinkCap = 6000;
  bool get _truncated => widget.text.length > _kThinkCap;
  String get _cappedText => _truncated
      ? '${widget.text.substring(0, _kThinkCap)}\n…(共 ${widget.text.length} 字符,已截断)'
      : widget.text;

  /// 收起态标题行文本:直播中 = 正文最后一个非空行(跑马灯滚动);
  /// 否则「思考过程」。只扫描末尾窗口:全文 split 是 O(n)/帧,
  /// 长思考(几十 KB)在高频重建下是明确的卡顿源。
  static const int _kHeadlineWindow = 800;
  String get _headline {
    if (!widget.streaming) return '思考过程';
    final t = widget.text;
    final window = t.length > _kHeadlineWindow
        ? t.substring(t.length - _kHeadlineWindow)
        : t;
    final lines = window.split('\n');
    for (var i = lines.length - 1; i >= 0; i--) {
      final s = lines[i].trim();
      if (s.isNotEmpty) return s;
    }
    return '思考中…';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expanded = _userExpanded;
    final headline = _headline;
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
                    if (widget.streaming && !expanded)
                      // 直播标记小点:与滚动末行并存,提示仍在思考。
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.tertiary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    Expanded(
                      child: widget.streaming
                          // 直播标题行:未超宽=打字效果;超宽=窗口锚定行尾
                          // 向左滑(最右字符永远是最新字符)。
                          ? RepaintBoundary(
                              child: _TailScrollText(
                                text: headline,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: theme.colorScheme.tertiary,
                                ),
                              ),
                            )
                          : Text(
                              headline,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                    ),
                    if (widget.streaming && !expanded) ...[
                      Text(
                        '思考中',
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.tertiary
                              .withValues(alpha: .9),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
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
          if (expanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              // 流式期间用 Text:SelectableText 的选择手势/布局代价高,
              // 250ms 一跳的全量重建下会拖垮滚动;定稿后恢复可选可复制。
              child: widget.streaming
                  ? Text(
                      _cappedText,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : SelectableText(
                      _cappedText,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
            if (_truncated)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => showChunkedTextDialog(
                      context,
                      title: '思考全文',
                      text: widget.text,
                    ),
                    icon: const Icon(Icons.fullscreen, size: 15),
                    label: const Text('全屏查看完整思考',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 尾随滚动标题行(打字 → 满行后向左滑的走马灯):
/// 行内容未超宽时静止 —— 流式追加新字符即天然的「打字效果」;
/// 一旦超出可视宽,窗口**始终锚定行尾** —— 最右字符永远是最新字符,
/// 后续新字符到达时整行向左平滑滑出(指数趋近,远快近缓),
/// 用户在任何时刻都看得到正在生成的字符(终端式跟随,不是从头到尾
/// 的循环滚动 —— 那种方式下新字符要等整轮滚完才可见)。
/// 行切换(新行开头不同)时立即回到行首,重新开始打字。
/// 动画只驱动 Transform(Ticker 每帧小步更新 + RepaintBoundary 隔离),
/// 作用域仅本组件,与 15Hz 节流的文本更新互不放大。
class _TailScrollText extends StatefulWidget {
  const _TailScrollText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_TailScrollText> createState() => _TailScrollTextState();
}

class _TailScrollTextState extends State<_TailScrollText>
    with SingleTickerProviderStateMixin {
  // initState 立即创建(late final 惰性求值会让「从未滑过」的实例在
  // dispose 时才首次初始化,于已反激活 element 上查 TickerMode 而炸)。
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  double _dx = 0; // 当前水平位移(≤0;0 = 显示行首)。
  double _targetDx = 0;
  Duration _lastElapsed = Duration.zero;
  double _viewportWidth = 0;
  double _textWidth = -1;
  String? _measuredText;
  TextScaler? _measuredScaler;

  /// 指数趋近速率(1/s):每帧靠近剩余距离的固定比例 → 远时快、近时缓
  /// 的自然滑动;12/s 约百毫秒级到位,与流式追加节奏匹配不堆积。
  static const double _kApproach = 12;
  static const double _kSnap = 0.25; // 收敛阈值(px):小于即贴齐停表。

  void _onTick(Duration elapsed) {
    final dt =
        ((elapsed - _lastElapsed).inMicroseconds / 1e6).clamp(0.001, 0.05);
    _lastElapsed = elapsed;
    final gap = _targetDx - _dx;
    if (gap.abs() <= _kSnap) {
      _dx = _targetDx;
      _ticker.stop();
    } else {
      _dx += gap * (dt * _kApproach).clamp(0.0, 1.0);
    }
    setState(() {});
  }

  void _measure(TextScaler scaler) {
    if (_measuredText == widget.text && _measuredScaler == scaler) return;
    _measuredText = widget.text;
    _measuredScaler = scaler;
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      textScaler: scaler,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _textWidth = painter.width;
    painter.dispose();
  }

  /// 重新计算锚点 = -(文本宽-视口宽)(下限 0);距离大则启动滑动。
  void _retarget() {
    final overflow = _textWidth - _viewportWidth;
    _targetDx = overflow > 0 ? -overflow : 0;
    if ((_targetDx - _dx).abs() > _kSnap) {
      if (!_ticker.isActive) {
        _lastElapsed = Duration.zero;
        _ticker.start();
      }
    } else {
      _dx = _targetDx;
      _ticker.stop();
    }
  }

  @override
  void didUpdateWidget(_TailScrollText old) {
    super.didUpdateWidget(old);
    _measure(_measuredScaler ?? TextScaler.noScaling);
    final grew = widget.text.startsWith(old.text);
    _retarget();
    if (!grew) {
      // 新行(开头不同):立刻静止在新锚点(通常行首 0)→ 重新「打字」。
      _dx = _targetDx;
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      _viewportWidth = constraints.maxWidth;
      _measure(scaler);
      _retarget(); // 幂等:文本/视口/缩放任一变化后重新锚定。
      return ClipRect(
        child: Transform.translate(
          offset: Offset(_dx, 0),
          child: Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: widget.style,
          ),
        ),
      );
    });
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
      key: ValueKey('tool-card-${node.seq}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        // 左缘色条改 Stack 覆盖:IntrinsicHeight 的高度取自 intrinsic 计算,
        // 而横向滚动的等宽文本在 intrinsic 阶段按卡宽折行、实际布局却横向
        // 延展不折行 —— 两套高度不一致,展开态就出现大半空白。
        child: Stack(
          children: [
            PositionedDirectional(
              start: 0,
              top: 0,
              bottom: 0,
              width: 3.5,
              child: Container(color: color.withValues(alpha: .85)),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 3.5),
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
                            if (toolDurationText(node) != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: Text(
                                  toolDurationText(node)!,
                                  key: const ValueKey('tool-duration'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.colorScheme.outline,
                                    fontFeatures: [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
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
    // 分块虚拟化:巨型输出(百 KB 级)单个 SelectableText 会卡布局。
    showChunkedTextDialog(context, title: node.toolName, text: _fullscreenText());
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
/// 展示截断:超过 [_kInlineCap] 字符只渲染首段(巨型工具输出的单个
/// SelectableText 布局会卡 UI);完整内容走全屏分块查看器。
class _MonoScroll extends StatelessWidget {
  const _MonoScroll({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final shown = _capForDisplay(text);
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
          shown,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
  }
}

/// 行内展示截断阈值(字符)。工具输出/原始 JSON 常见数十 KB,全量塞进
/// 单个 SelectableText 会同步布局卡帧;行内只给首段,全文走分块查看器。
const int _kInlineCap = 4000;

String _capForDisplay(String text) {
  if (text.length <= _kInlineCap) return text;
  return '${text.substring(0, _kInlineCap)}\n…(共 ${text.length} 字符,已截断 —— 「全屏查看」看完整内容)';
}

/// 分块文本查看器:按 [_kChunkChars] 切片进 ListView.builder,只构建可视块;
/// 巨型文本(百 KB 级工具输出/推理全文)也能流畅滚动。选择以块为单位。
class ChunkedTextViewer extends StatelessWidget {
  const ChunkedTextViewer({
    super.key,
    required this.text,
    this.mono = true,
    this.fontSize = 13,
  });
  final String text;
  final bool mono;
  final double fontSize;

  /// 单块字符数(块内单个 SelectableText,块间虚拟化)。
  static const int _kChunkChars = 6000;

  @override
  Widget build(BuildContext context) {
    final chunks = <String>[];
    for (var i = 0; i < text.length; i += _kChunkChars) {
      chunks.add(text.substring(
        i,
        (i + _kChunkChars) < text.length ? i + _kChunkChars : text.length,
      ));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: chunks.length,
      itemBuilder: (context, i) => SelectableText(
        chunks[i],
        style: TextStyle(
          fontFamily: mono ? 'monospace' : null,
          fontSize: fontSize,
          height: 1.4,
        ),
      ),
    );
  }
}

/// 打开全屏分块查看器(工具详情/思考全文共用)。
void showChunkedTextDialog(
  BuildContext context, {
  required String title,
  required String text,
  String? copyLabel,
}) {
  showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(title, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: '复制全部',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
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
        body: ChunkedTextViewer(text: text),
      ),
    ),
  );
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
    'todo_write' || 'todo' => '更新任务清单',
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

/// A2/A15 时间格式化:同日 HH:mm,跨日补日期(web use-calendar-day 语义)。
String formatNodeTime(double epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs.round());
  final now = DateTime.now();
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  final sameDay =
      dt.year == now.year && dt.month == now.month && dt.day == now.day;
  if (sameDay) return '$hh:$mm';
  return '${dt.month}/${dt.day} $hh:$mm';
}

/// A4 工具耗时:call→result 墙钟;web formatDuration 同款(45.2s / 2m42s)。
String? toolDurationText(ChatNodeTool node) {
  final call = node.callTime;
  final end = node.resultTime;
  if (call == null || end == null || end <= call) return null;
  return formatDurationMs(end - call);
}

/// web StatsLine.formatDuration 的 Dart 版。
String formatDurationMs(double ms) {
  final s = ms / 1000;
  if (s < 60) return '${(s * 10).round() / 10}s';
  final whole = s.round();
  return '${whole ~/ 60}m${whole % 60}s';
}

/// A5 注入上下文行:左侧低调折叠行(web ContextInjectionRow 对齐)。
/// 头部 = 「上下文注入/召回」 + 生产者标签;展开显示正文(截断保护)。
class _ContextRow extends StatefulWidget {
  const _ContextRow({required this.node});
  final ChatNodeContextRow node;

  @override
  State<_ContextRow> createState() => _ContextRowState();
}

class _ContextRowState extends State<_ContextRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = widget.node;
    final title = node.recall ? '上下文召回' : '上下文注入';
    final label = node.provenanceLabel;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kNodeTapHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.browse_gallery_outlined,
                      size: 15,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      title,
                      key: const ValueKey('context-row-title'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (label != null && label.isNotEmpty) ...[
                      Text(
                        ' · ',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    if (node.summary != null && node.summary!.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 120),
                        child: Text(
                          node.summary!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          key: const ValueKey('context-row-summary'),
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded && node.text != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
              child: _MonoScroll(text: _capForDisplay(node.text!)),
            ),
        ],
      ),
    );
  }
}

/// B1 命令卡(web CommandNode/GenericCommandCard 对齐):/cmd 执行痕迹。
class _CommandCard extends StatelessWidget {
  const _CommandCard({required this.node});
  final ChatNodeCommand node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = node.done && node.outcomeKind == 'success';
    final failed = node.done && node.outcomeKind != null && !ok;
    final color = failed
        ? theme.colorScheme.error
        : ok
             ? Colors.green.shade700
             : theme.colorScheme.primary;
    final title = node.name == null ? '命令' : '/${node.name!}';
    final detail = node.done
        ? (node.outcomeText ?? (node.outcomeKind ?? ''))
        : '执行中…';
    return Container(
      key: ValueKey('command-card-${node.seq}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: .6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: .35),
        ),
      ),
      child: Row(
        children: [
          Icon(
            node.done
                ? (ok ? Icons.check_circle_outline : Icons.error_outline)
                : Icons.terminal,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              detail.isEmpty ? title : '$title · $detail',
              key: const ValueKey('command-card-title'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A7 workflow 运行卡:阶段分组 + 成员状态(web WorkflowRunCard 对齐)。
/// [onOpenChild] = 点击成员行打开子会话 transcript(A10 联动)。
class _WorkflowRunCard extends StatelessWidget {
  const _WorkflowRunCard({required this.node, this.onOpenChild});
  final ChatNodeWorkflowRun node;
  final void Function(String childId)? onOpenChild;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (node.status) {
      'completed' => Colors.green.shade700,
      'failed' => theme.colorScheme.error,
      'cancelled' || 'interrupted' => Colors.orange.shade800,
      _ => theme.colorScheme.primary,
    };
    final statusLabel = switch (node.status) {
      'running' => '运行中',
      'completed' => '已完成',
      'failed' => '失败',
      'cancelled' => '已取消',
      _ => '已中断',
    };
    return Container(
      key: ValueKey('workflow-card-${node.seq}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: .4),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          children: [
            PositionedDirectional(
              start: 0,
              top: 0,
              bottom: 0,
              width: 3.5,
              child: Container(color: color.withValues(alpha: .85)),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 3.5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: kNodeTapHeight),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          if (node.status == 'running')
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                valueColor: AlwaysStoppedAnimation(color),
                              ),
                            )
                          else
                            Icon(
                              Icons.account_tree_outlined,
                              size: 16,
                              color: color,
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '工作流 · ${node.name}',
                              key: const ValueKey('workflow-card-title'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Text(
                            statusLabel,
                            style: TextStyle(fontSize: 11, color: color),
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (final phase in node.phases) ...[
                    Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: .3,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                      child: Text(
                        phase.phase == null ? '默认阶段' : '阶段 ${phase.phase}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                    for (final m in phase.members)
                      InkWell(
                        onTap: onOpenChild == null || m.childId.isEmpty
                            ? null
                            : () => onOpenChild!(m.childId),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _workflowMemberIcon(m.status),
                                size: 14,
                                color: _workflowMemberColor(
                                  context,
                                  m.status,
                                ),
                              ),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text(
                                  m.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              Text(
                                _workflowMemberLabel(m.status),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _workflowMemberColor(
                                    context,
                                    m.status,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _workflowMemberIcon(String status) => switch (status) {
      'completed' => Icons.check_circle_outline,
      'failed' => Icons.error_outline,
      'cancelled' || 'interrupted' => Icons.remove_circle_outline,
      _ => Icons.smart_toy_outlined,
    };

Color _workflowMemberColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'completed' => Colors.green.shade700,
    'failed' => scheme.error,
    'cancelled' || 'interrupted' => Colors.orange.shade800,
    _ => scheme.primary,
  };
}

String _workflowMemberLabel(String status) => switch (status) {
      'running' => '运行中',
      'completed' => '完成',
      'failed' => '失败',
      'cancelled' => '取消',
      _ => '中断',
    };

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
  'stop' => Icons.stop_circle_outlined,
  'warning' => Icons.warning_amber_outlined,
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
