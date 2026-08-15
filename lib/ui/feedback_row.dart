// FeedbackActions — W3-B 消息反馈(web dsh-client-ui-message-feedback 复刻)。
//
// 语义(docs/audit/settings-system.md §4 + DSH-PROTOCOL §9):
// - 渲染在已定稿助手消息的操作区(集成方放置;本 widget 只消费 FeedbackStoreView)
// - 👍/👎/备注 常显按钮(桌面 hover-only → 触屏常显,移动硬性;触控目标 ≥44dp)
// - 已评高亮(filled + 主题色);再点同一侧 = 撤回(delete);切换另一侧保留已有 note
// - 备注 → 底部 sheet:note 编辑;8192 上限本地预拒(maxLength)+ note-too-large
//   文案(服务端拒绝路径);备注是评分条目的属性(put 必须带 rating),未评分保存
//   → 内联提示先评分
// - 无实时推送:重连 resync 语义 = [resyncTick](代际翻转计数)变化 → 重拉;
//   主会话接线:FeedbackStore.onInvalidated → ValueNotifier<int> 自增
// - 请求在途禁用(防误触,audit §4.4)
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:singleman/sessions/feedback_store.dart';

/// 打开备注编辑底部 sheet;返回编辑后的 note 文本,取消返回 null。
/// 8192 上限本地预拒 + note-too-large 文案;键盘弹起时 sheet 整体上移。
Future<String?> showFeedbackNoteSheet(
  BuildContext context, {
  required String initialNote,
  required FeedbackRating? currentRating,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _FeedbackNoteSheet(
      initialNote: initialNote,
      currentRating: currentRating,
    ),
  );
}

/// 助手消息反馈操作区(👍/👎/备注)。
class FeedbackActions extends StatefulWidget {
  const FeedbackActions({
    super.key,
    required this.store,
    required this.sessionId,
    required this.messageId,
    this.resyncTick,
  });

  /// 反馈域窄视图(真实现 FeedbackStore / 测试假实现)。
  final FeedbackStoreView store;
  final String sessionId;
  final String messageId;

  /// 重连 resync 触发器:值变化(代际翻转)时重拉 list。
  /// 主会话接线:FeedbackStore.onInvalidated → `ValueNotifier<int>` 自增。
  final ValueListenable<int>? resyncTick;

  @override
  State<FeedbackActions> createState() => _FeedbackActionsState();
}

class _FeedbackActionsState extends State<FeedbackActions> {
  FeedbackItem? _item;
  bool _busy = false;
  String? _error;
  StreamSubscription<void>? _changedSub;

  @override
  void initState() {
    super.initState();
    _item = _findItem();
    _changedSub = widget.store.changed.listen((_) {
      if (!mounted) return;
      setState(() => _item = _findItem());
    });
    widget.resyncTick?.addListener(_onResync);
    _load();
  }

  @override
  void dispose() {
    widget.resyncTick?.removeListener(_onResync);
    _changedSub?.cancel();
    super.dispose();
  }

  FeedbackItem? _findItem() {
    for (final e in widget.store.itemsFor(widget.sessionId)) {
      if (e.messageId == widget.messageId) return e;
    }
    return null;
  }

  void _onResync() {
    if (!mounted) return;
    _load(force: true);
  }

  Future<void> _load({bool force = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final items = await widget.store.list(widget.sessionId, force: force);
      if (!mounted) return;
      setState(() {
        _item = _byMessageId(items);
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '反馈加载失败';
        _busy = false;
      });
    }
  }

  FeedbackItem? _byMessageId(List<FeedbackItem> items) {
    for (final e in items) {
      if (e.messageId == widget.messageId) return e;
    }
    return null;
  }

  void _rate(FeedbackRating rating) {
    if (_busy) return;
    final current = _item;
    if (current != null && current.rating == rating) {
      // 已评再点同一侧 = 撤回(delete)。
      _runDelete();
      return;
    }
    // 切换另一侧保留已有 note。
    _runPut(rating, note: current?.note);
  }

  Future<void> _runPut(FeedbackRating rating, {String? note}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final item = await widget.store.put(
        widget.sessionId,
        widget.messageId,
        rating,
        note: note,
        ifVersion: _item?.version,
      );
      if (!mounted) return;
      setState(() {
        _item = item;
        _busy = false;
      });
    } on FeedbackVersionConflictException catch (e) {
      if (!mounted) return;
      // 直接对账:权威条目覆盖本地(并发删除 → 未评)。
      setState(() {
        _item = e.authoritative;
        _busy = false;
      });
    } on FeedbackNoteTooLargeException {
      if (!mounted) return;
      setState(() {
        _error = '备注过长(上限 $kFeedbackNoteMaxBytes 字符,note-too-large)';
        _busy = false;
      });
    } on FeedbackStoreException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? '评分失败';
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '评分失败';
        _busy = false;
      });
    }
  }

  Future<void> _runDelete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.store
          .delete(widget.sessionId, widget.messageId, ifVersion: _item?.version);
      if (!mounted) return;
      setState(() {
        _item = null;
        _busy = false;
      });
    } on FeedbackStoreException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message ?? '撤回失败';
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '撤回失败';
        _busy = false;
      });
    }
  }

  Future<void> _openNoteSheet() async {
    if (_busy) return;
    final note = await showFeedbackNoteSheet(
      context,
      initialNote: _item?.note ?? '',
      currentRating: _item?.rating,
    );
    if (note == null || !mounted) return; // 取消。
    final rating = _item?.rating;
    if (rating == null) {
      setState(() => _error = '请先选择 👍/👎 评分再保存备注');
      return;
    }
    final trimmed = note.trim();
    await _runPut(rating, note: trimmed.isEmpty ? null : trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _item?.rating;
    final hasNote = (_item?.note ?? '').isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _actionButton(
              key: const ValueKey('feedback-thumb-up'),
              icon: selected == FeedbackRating.positive
                  ? Icons.thumb_up
                  : Icons.thumb_up_outlined,
              selected: selected == FeedbackRating.positive,
              tooltip: '有帮助',
              onTap: () => _rate(FeedbackRating.positive),
            ),
            _actionButton(
              key: const ValueKey('feedback-thumb-down'),
              icon: selected == FeedbackRating.negative
                  ? Icons.thumb_down
                  : Icons.thumb_down_outlined,
              selected: selected == FeedbackRating.negative,
              tooltip: '没帮助',
              onTap: () => _rate(FeedbackRating.negative),
            ),
            _actionButton(
              key: const ValueKey('feedback-note'),
              icon: Icons.notes,
              selected: hasNote,
              tooltip: '备注',
              onTap: _openNoteSheet,
            ),
          ],
        ),
        if (_error != null)
          Padding(
            key: const ValueKey('feedback-error'),
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _error!,
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _actionButton({
    required Key key,
    required IconData icon,
    required bool selected,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: _busy ? null : onTap,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      icon: Icon(
        icon,
        size: 20,
        color: selected
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 备注编辑 sheet 主体:TextField(8192 上限本地预拒)+ 保存/取消。
class _FeedbackNoteSheet extends StatefulWidget {
  const _FeedbackNoteSheet({
    required this.initialNote,
    required this.currentRating,
  });
  final String initialNote;
  final FeedbackRating? currentRating;

  @override
  State<_FeedbackNoteSheet> createState() => _FeedbackNoteSheetState();
}

class _FeedbackNoteSheetState extends State<_FeedbackNoteSheet> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialNote);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    if (_controller.text.length > kFeedbackNoteMaxBytes) {
      // 本地预拒(防御:maxLength 已硬限,此处防程序化注入)。
      setState(() {
        _error = '备注过长(上限 $kFeedbackNoteMaxBytes 字符,note-too-large)';
      });
      return;
    }
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rating = widget.currentRating;
    return Padding(
      // 键盘弹起时 sheet 整体上移(移动硬性:输入框始终可输入)。
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '消息反馈备注',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('feedback-note-close'),
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              if (rating != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    rating == FeedbackRating.positive
                        ? '当前评分: 👍 有帮助'
                        : '当前评分: 👎 没帮助',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              TextField(
                key: const ValueKey('feedback-note-field'),
                controller: _controller,
                minLines: 2,
                maxLines: 4,
                maxLength: kFeedbackNoteMaxBytes,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                decoration: const InputDecoration(
                  hintText: '补充备注(可选)',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _error!,
                    key: const ValueKey('feedback-note-error'),
                    style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey('feedback-note-cancel'),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('feedback-note-save'),
                    onPressed: _save,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
