// JobStore — W1-B jobs 后台任务域:会话头部的任务列表复刻。
//
// 契约(DSH-PROTOCOL §4 + docs/audit/conversation.md §8):
// - session/jobs 是完整快照帧:整帧收敛,直接替换该会话的任务列表
// - 排序照抄 web:活跃(running/stopping)在前按 startedAt 升序,
//   终态在后按 finishedAt 降序;毫秒并列按帧内顺序(稳定排序保序)
// - 角标计数 = running+stopping,为 0 则无角标
// - 耗时:活跃 = now-startedAt(clock 可注入),终态 = finishedAt-startedAt
//   (缺 finishedAt 读 0);>1h 停在小时(不再显示分秒)
// - 终态行保留(失败 detail 是唯一可读处),直到该会话下一帧不再含它
//   —— 整帧替换语义天然满足,不做额外过滤
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 是否活跃状态(running/stopping);非字符串一律按终态处理(防御 wire 变化)。
bool isJobActive(Object? status) => status == 'running' || status == 'stopping';

/// 耗时格式化:>1h 停在小时("2h"),否则 "m:ss"(活跃行每秒走表刷新)。
String formatJobDuration(int ms) {
  if (ms < 0) ms = 0;
  final hours = ms ~/ Duration.millisecondsPerHour;
  if (hours >= 1) return '${hours}h';
  final minutes =
      (ms % Duration.millisecondsPerHour) ~/ Duration.millisecondsPerMinute;
  final seconds =
      (ms % Duration.millisecondsPerMinute) ~/ Duration.millisecondsPerSecond;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// 排序+耗时折叠后的任务行(UI 只消费这个,不碰 wire)。
class JobEntry {
  const JobEntry({
    required this.task,
    required this.active,
    required this.elapsedMs,
  });
  final TaskView task;

  /// running/stopping 判定(排序与角标的共同依据)。
  final bool active;

  /// 已计算耗时:活跃=now-startedAt(快照时刻),终态=finishedAt-startedAt。
  final int elapsedMs;
}

/// UI 依赖的窄视图(便于 widget 测试注入假实现,不碰 socket)。
abstract class JobStoreView {
  /// 全会话任务快照流(广播;每次 session/jobs 帧后推整表)。
  Stream<Map<String, List<JobEntry>>> get jobs;

  /// 某会话当前排序后的任务列表(空会话返回空表)。
  List<JobEntry> jobsFor(String sessionId);

  /// 角标计数 = running+stopping,为 0 无角标。
  int badgeFor(String sessionId);
}

class JobStore implements JobStoreView {
  JobStore({required this.api, required this.connection, int Function()? clock})
      : _clock = clock ?? _defaultClock {
    _jobsController = StreamController<Map<String, List<JobEntry>>>.broadcast();
    _muxSub = connection.muxFrames.listen(_onMuxFrame);
  }

  /// 默认时钟:真实墙上时间。
  static int _defaultClock() => DateTime.now().millisecondsSinceEpoch;

  final ApiClient api;
  final ConnectionController connection;
  final int Function() _clock;
  late final StreamController<Map<String, List<JobEntry>>> _jobsController;
  StreamSubscription<MuxFrame>? _muxSub;
  final Map<String, List<JobEntry>> _bySession = <String, List<JobEntry>>{};

  @override
  Stream<Map<String, List<JobEntry>>> get jobs => _jobsController.stream;

  /// 当前快照。
  Map<String, List<JobEntry>> get currentJobs =>
      Map<String, List<JobEntry>>.unmodifiable(_bySession);

  @override
  List<JobEntry> jobsFor(String sessionId) =>
      List<JobEntry>.unmodifiable(_bySession[sessionId] ?? const <JobEntry>[]);

  @override
  int badgeFor(String sessionId) =>
      jobsFor(sessionId).where((e) => e.active).length;

  /// session/jobs 帧:整帧替换该会话列表(收敛语义),重算排序与耗时后广播。
  void _onMuxFrame(MuxFrame frame) {
    if (frame is! MuxFrameSessionJobs) return;
    final now = _clock();
    final entries = <JobEntry>[
      for (final t in frame.jobs)
        JobEntry(
          task: t,
          active: isJobActive(t.status),
          elapsedMs: _elapsed(t, now),
        ),
    ];
    _bySession[frame.sessionId] = _stableSort(entries, _compareJobs);
    if (!_jobsController.isClosed) {
      _jobsController.add(currentJobs);
    }
  }

  /// 耗时:活跃 = now-startedAt;终态 = finishedAt-startedAt(缺 finishedAt 读 0)。
  /// 负值(时钟回拨/畸形数据)钳到 0。
  int _elapsed(TaskView t, int now) {
    final active = isJobActive(t.status);
    final ms = active ? now - t.startedAt : (t.finishedAt ?? 0) - t.startedAt;
    return ms < 0 ? 0 : ms;
  }

  /// 排序比较:活跃优先;活跃按 startedAt 升序,终态按 finishedAt 降序
  /// (缺 finishedAt 按 0);完全并列返回 0 → 稳定排序保留帧内顺序。
  static int _compareJobs(JobEntry a, JobEntry b) {
    if (a.active != b.active) return a.active ? -1 : 1;
    if (a.active) {
      return a.task.startedAt.compareTo(b.task.startedAt);
    }
    final af = a.task.finishedAt ?? 0;
    final bf = b.task.finishedAt ?? 0;
    return bf.compareTo(af);
  }

  /// 稳定归并排序(List.sort 不保证稳定;毫秒并列需保留帧内顺序)。
  static List<T> _stableSort<T>(List<T> items, int Function(T, T) compare) {
    if (items.length < 2) return List<T>.of(items);
    final mid = items.length ~/ 2;
    final left = _stableSort(items.sublist(0, mid), compare);
    final right = _stableSort(items.sublist(mid), compare);
    final out = <T>[];
    var i = 0, j = 0;
    while (i < left.length && j < right.length) {
      if (compare(left[i], right[j]) <= 0) {
        out.add(left[i++]);
      } else {
        out.add(right[j++]);
      }
    }
    while (i < left.length) {
      out.add(left[i++]);
    }
    while (j < right.length) {
      out.add(right[j++]);
    }
    return out;
  }

  Future<void> dispose() async {
    await _muxSub?.cancel();
    await _jobsController.close();
  }
}
