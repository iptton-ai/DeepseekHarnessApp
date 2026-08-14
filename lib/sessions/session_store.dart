// SessionStore — M2 会话领域状态。
//
// 职责(PLAN M2 / DSH-PROTOCOL §5):
// - 代际 ready → 全量重取 session.list(无 since 续传,重连=重开流+重取)
// - session.history 尾页(beforeSeq 缺席)装载事件日志 + projections 水位
// - mux session/event 增量按 seq 去重追加(重连重放安全)
// - session/projection 高 seq 覆盖低 seq;host/session-status 折叠 running
// - session.prompt(mode:queue)上行
//
// 上层(UI)只消费广播流,不碰 wire。
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 单个会话的事件日志与投影。
class SessionLog {
  SessionLog(this.sessionId);

  final String sessionId;
  final List<SessionEvent> _events = <SessionEvent>[];
  final Set<int> _seenSeqs = <int>{};
  final Map<String, dynamic> projections = <String, dynamic>{};
  int projectionWatermark = -1;
  final StreamController<List<SessionEvent>> _eventsController =
      StreamController<List<SessionEvent>>.broadcast();

  /// 当前日志快照(seq 升序)。
  List<SessionEvent> get events => List<SessionEvent>.unmodifiable(_events);

  /// 日志变更流(追加/去重后)。
  Stream<List<SessionEvent>> get eventStream => _eventsController.stream;

  int get lastSeq => _events.isEmpty ? -1 : _events.last.seq;

  /// 按 seq 去重追加;重连后的重放帧天然安全。返回是否真的追加。
  bool append(SessionEvent event) {
    if (_seenSeqs.contains(event.seq)) return false;
    _seenSeqs.add(event.seq);
    var insertAt = _events.length;
    while (insertAt > 0 && _events[insertAt - 1].seq > event.seq) {
      insertAt -= 1;
    }
    _events.insert(insertAt, event);
    if (!_eventsController.isClosed) {
      _eventsController.add(List<SessionEvent>.unmodifiable(_events));
    }
    return true;
  }

  /// 投影单元覆盖:高 seq 赢,低 seq/同 seq 丢弃。
  void applyProjection(String key, dynamic value, int seq) {
    if (seq < projectionWatermark) return;
    projectionWatermark = seq;
    projections[key] = value;
  }

  Future<void> dispose() => _eventsController.close();
}

/// UI 依赖的窄视图(便于 widget 测试用假实现注入,不碰 socket)。
abstract class SessionStoreView {
  Stream<List<SessionSummary>> get summaries;
  List<SessionSummary> get currentSummaries;
  SessionLog logFor(String sessionId);
}

class SessionStore implements SessionStoreView {
  SessionStore({required this.api, required this.connection}) {
    _summariesController = StreamController<List<SessionSummary>>.broadcast();
  }

  final ApiClient api;
  final ConnectionController connection;

  late final StreamController<List<SessionSummary>> _summariesController;
  final Map<String, SessionLog> _logs = <String, SessionLog>{};
  List<SessionSummary> _summaries = <SessionSummary>[];
  StreamSubscription<ConnectionSnapshot>? _snapshotsSub;
  StreamSubscription<MuxFrame>? _muxSub;
  StreamSubscription<HostFrame>? _hostSub;
  int _lastReadyGeneration = 0;
  bool _started = false;
  int listCalls = 0;

  /// 会话列表快照流。
  Stream<List<SessionSummary>> get summaries => _summariesController.stream;

  /// 当前快照。
  List<SessionSummary> get currentSummaries => List<SessionSummary>.unmodifiable(_summaries);

  /// 取(或建)某会话的日志。
  SessionLog logFor(String sessionId) => _logs.putIfAbsent(sessionId, () => SessionLog(sessionId));

  void start() {
    if (_started) return;
    _started = true;
    _snapshotsSub = connection.snapshots.listen((snap) {
      if (!_disposed &&
          snap.phase == ConnectionPhase.ready &&
          snap.generation > _lastReadyGeneration) {
        _lastReadyGeneration = snap.generation;
        // 重连=全量重取(无 since);已积累的事件日志靠 seq 去重保留。
        unawaited(refresh().catchError((Object e) {
          // dispose 竞态下的连接取消不外泄(refresh 由下一次代际重试)。
        }));
      }
    });
    _muxSub = connection.muxFrames.listen(_onMuxFrame);
    _hostSub = connection.hostFrames.listen(_onHostFrame);
    final current = connection.current;
    if (current != null &&
        current.phase == ConnectionPhase.ready &&
        current.generation > _lastReadyGeneration) {
      _lastReadyGeneration = current.generation;
      unawaited(refresh());
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _snapshotsSub?.cancel();
    await _muxSub?.cancel();
    await _hostSub?.cancel();
    for (final log in _logs.values) {
      await log.dispose();
    }
    await _summariesController.close();
  }

  bool _disposed = false;

  /// 全量重取会话列表。
  Future<void> refresh() async {
    if (_disposed) return;
    final value = await api.call(
      RpcMethods.sessionList,
      <String, dynamic>{},
      parse: SessionListValue.fromJson,
    );
    _summaries = value.items;
    if (!_summariesController.isClosed) {
      _summariesController.add(List<SessionSummary>.unmodifiable(_summaries));
    }
    listCalls += 1;
    // 预热日志(保住已存在日志的同时登记新会话)。
    for (final s in value.items) {
      logFor(s.sessionId);
    }
  }

  /// 装载历史尾页(beforeSeq 缺席 = 尾页,附带 projections 水位快照)。
  /// hasMore=true 时继续向前翻页直至取完。
  Future<void> loadHistory(String sessionId, {int? maxMessages}) async {
    var hasMore = true;
    int? beforeSeq;
    while (hasMore) {
      final payload = <String, dynamic>{'sessionId': sessionId};
      if (beforeSeq != null) payload['beforeSeq'] = beforeSeq;
      if (maxMessages != null) payload['maxMessages'] = maxMessages;
      final value = await api.call(
        RpcMethods.sessionHistory,
        payload,
        parse: SessionHistoryValue.fromJson,
      );
      final log = logFor(sessionId);
      for (final entry in value.events) {
        log.append(entry.event);
      }
      final block = value.projections;
      if (block != null) {
        for (final key in block.values.keys) {
          log.projections[key] = block.values[key];
        }
        if (block.asOfSeq > log.projectionWatermark) {
          log.projectionWatermark = block.asOfSeq;
        }
      }
      hasMore = value.hasMore;
      if (hasMore && value.events.isNotEmpty) {
        beforeSeq = value.events.first.event.seq;
      } else {
        hasMore = false;
      }
    }
  }

  /// workspace.list(只读;M2 UI 的会话创建入口之一)。
  Future<WorkspaceListValue> workspaceList() => api.call(
        RpcMethods.workspaceList,
        <String, dynamic>{},
        parse: WorkspaceListValue.fromJson,
      );

  /// session.create:workspaceId 与 cwd 至多一个(服务端 refine,双侧都发必被拒)。
  /// 创建后立刻 refresh 列表并把新会话登记进日志表。
  Future<SessionCreateValue> createSession({String? workspaceId, String? cwd, String? agentPreset}) async {
    final payload = <String, dynamic>{};
    if (workspaceId != null) payload['workspaceId'] = workspaceId;
    if (cwd != null) payload['cwd'] = cwd;
    if (agentPreset != null) payload['agentPreset'] = agentPreset;
    final value = await api.call(
      RpcMethods.sessionCreate,
      payload,
      parse: SessionCreateValue.fromJson,
    );
    logFor(value.sessionId);
    unawaited(refresh());
    return value;
  }

  /// 发送纯文本 prompt(mode:queue)。
  Future<SessionPromptValue> promptText(String sessionId, String text,
      {String mode = 'queue', String? clientTimeZone}) async {
    final request = <String, dynamic>{
      'sessionId': sessionId,
      'mode': mode,
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': text},
      ],
    };
    if (clientTimeZone != null) request['clientTimeZone'] = clientTimeZone;
    return api.call(
      RpcMethods.sessionPrompt,
      request,
      parse: SessionPromptValue.fromJson,
    );
  }

  void _onMuxFrame(MuxFrame frame) {
    if (frame is MuxFrameSessionEvent) {
      logFor(frame.sessionId).append(frame.event);
    } else if (frame is MuxFrameSessionProjection) {
      logFor(frame.sessionId)
          .applyProjection(frame.key, frame.value, frame.seq);
    }
    // session/subscribed 水位、queue/jobs 快照收敛:M3 再折叠。
  }

  void _onHostFrame(HostFrame frame) {
    if (frame is HostFrameHostSessionStatus) {
      final idx = _summaries.indexWhere((s) => s.sessionId == frame.sessionId);
      if (idx >= 0) {
        // SessionSummary 是不可变 wire 模型;重建列表项(running 翻转)。
        final old = _summaries[idx];
        final updated = SessionSummary(
          sessionId: old.sessionId,
          updatedAt: old.updatedAt,
          running: frame.running,
          blank: old.blank,
          parentSessionId: old.parentSessionId,
          origin: old.origin,
          cwd: old.cwd,
          agentPreset: old.agentPreset,
          projections: old.projections,
        );
        final next = List<SessionSummary>.of(_summaries);
        next[idx] = updated;
        _summaries = next;
        if (!_summariesController.isClosed) {
          _summariesController.add(List<SessionSummary>.unmodifiable(_summaries));
        }
      }
    }
  }
}
