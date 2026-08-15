// JobsTrigger + JobsSheet(W1-B UI):会话头部的后台任务触发器与底部弹层。
// 语义(docs/audit/conversation.md §8):
// - 无任务完全不渲染(避免手机屏幕被无意义控件占用)
// - 角标 = running+stopping,为 0 无角标
// - 弹层用 showModalBottomSheet(移动可用性;宽屏居中 modal 可后调)
// - 行:上= label+状态徽章,下= kind+耗时(窄屏两行);活跃行耗时每秒走表,
//   Timer 只活在弹层内,弹层关闭即停;detail 有则取代状态词
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/sessions/job_store.dart';

/// 会话头部后台任务触发器:带角标按钮;无任务完全不渲染。
class JobsTrigger extends StatefulWidget {
  const JobsTrigger({
    super.key,
    required this.store,
    required this.sessionId,
    this.clock,
    this.tooltip = '后台任务',
  });

  final JobStoreView store;
  final String sessionId;

  /// 耗时钟注入(默认墙上时间;widget 测试传固定值)。
  final int Function()? clock;
  final String tooltip;

  @override
  State<JobsTrigger> createState() => _JobsTriggerState();
}

class _JobsTriggerState extends State<JobsTrigger> {
  StreamSubscription<Map<String, List<JobEntry>>>? _sub;
  List<JobEntry> _jobs = const <JobEntry>[];

  @override
  void initState() {
    super.initState();
    _jobs = widget.store.jobsFor(widget.sessionId);
    _sub = widget.store.jobs.listen((_) {
      if (!mounted) return;
      setState(() => _jobs = widget.store.jobsFor(widget.sessionId));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_jobs.isEmpty) return const SizedBox.shrink();
    final badge = widget.store.badgeFor(widget.sessionId);
    return IconButton(
      tooltip: widget.tooltip,
      onPressed: _open,
      icon: badge > 0
          ? Badge(label: Text(badge.toString()), child: const Icon(Icons.work_outline))
          : const Icon(Icons.work_outline),
    );
  }

  void _open() {
    showJobsSheet(
      context,
      store: widget.store,
      sessionId: widget.sessionId,
      clock: widget.clock,
    );
  }
}

/// 打开任务弹层(showModalBottomSheet;宽屏居中行为可后调)。
Future<void> showJobsSheet(
  BuildContext context, {
  required JobStoreView store,
  required String sessionId,
  int Function()? clock,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => _JobsSheetBody(
      store: store,
      sessionId: sessionId,
      clock: clock ?? _wallClock,
    ),
  );
}

int _wallClock() => DateTime.now().millisecondsSinceEpoch;

/// 弹层主体:订阅 store + 每秒走表;dispose(弹层关闭)即停表。
class _JobsSheetBody extends StatefulWidget {
  const _JobsSheetBody({
    required this.store,
    required this.sessionId,
    required this.clock,
  });
  final JobStoreView store;
  final String sessionId;
  final int Function() clock;

  @override
  State<_JobsSheetBody> createState() => _JobsSheetBodyState();
}

class _JobsSheetBodyState extends State<_JobsSheetBody> {
  List<JobEntry> _jobs = const <JobEntry>[];
  late int _now;
  Timer? _timer;
  StreamSubscription<Map<String, List<JobEntry>>>? _sub;

  @override
  void initState() {
    super.initState();
    _jobs = widget.store.jobsFor(widget.sessionId);
    _now = widget.clock();
    _sub = widget.store.jobs.listen((_) {
      if (!mounted) return;
      setState(() => _jobs = widget.store.jobsFor(widget.sessionId));
    });
    // 活跃行耗时每秒走表;弹层关闭(dispose)即停。
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = widget.clock());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_jobs.isEmpty) {
      return const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('无后台任务')),
        ),
      );
    }
    return SafeArea(
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _jobs.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(children: [
                const Icon(Icons.work_outline, size: 18),
                const SizedBox(width: 8),
                Text('后台任务(${_jobs.length})',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            );
          }
          final entry = _jobs[i - 1];
          return _JobRow(
            key: ValueKey<String>('job-row-${entry.task.id}'),
            entry: entry,
            now: _now,
          );
        },
      ),
    );
  }
}

/// 单行任务:上= label+状态徽章,下= kind+耗时(窄屏两行);
/// 宽屏单行 + 横向滚动(宽内容横向滚动纪律)。
class _JobRow extends StatelessWidget {
  const _JobRow({super.key, required this.entry, required this.now});
  final JobEntry entry;
  final int now;

  @override
  Widget build(BuildContext context) {
    final task = entry.task;
    // detail 有则取代状态词(失败 detail 是唯一可读处)。
    final statusWord = task.detail ?? task.status.toString();
    final duration = entry.active
        ? formatJobDuration(now - task.startedAt)
        : formatJobDuration(entry.elapsedMs);
    if (MediaQuery.sizeOf(context).width < 600) {
      return Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  task.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              const SizedBox(width: 8),
              _StatusBadge(text: statusWord, color: _statusColor(context)),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Text(
                  task.kind,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
                ),
              ),
              const SizedBox(width: 8),
              Text(duration, style: const TextStyle(fontSize: 12)),
            ]),
          ],
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          Text(
            task.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(width: 8),
          _StatusBadge(text: statusWord, color: _statusColor(context)),
          const SizedBox(width: 12),
          Text(task.kind,
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          const SizedBox(width: 8),
          Text(duration, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  /// 徽章色:活跃 running=主色/stopping=橙;终态 success=绿/error 系=红/其余灰。
  Color _statusColor(BuildContext context) {
    final status = entry.task.status;
    if (entry.active) {
      return status == 'stopping'
          ? Colors.orange
          : Theme.of(context).colorScheme.primary;
    }
    if (status == 'success') return Colors.green;
    if (status == 'error' || status == 'failed' || status == 'cancelled') {
      return Theme.of(context).colorScheme.error;
    }
    return Colors.grey;
  }
}

/// 状态徽章:小圆角底色 + 状态词(或 detail)。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}
