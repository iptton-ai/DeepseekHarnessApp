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
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/sessions/attachments.dart';
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

  /// 批量追加(历史页装载用):seq 去重后**只发一次**广播。
  /// 逐条 append 会造成 O(n²) 的全列表复制 + 每条一次全屏 rebuild
  /// (启动装载风暴的根因之一,见 PROGRESS 性能回写)。
  int appendAll(Iterable<SessionEvent> events) {
    var added = 0;
    for (final event in events) {
      if (_seenSeqs.contains(event.seq)) continue;
      _seenSeqs.add(event.seq);
      var insertAt = _events.length;
      while (insertAt > 0 && _events[insertAt - 1].seq > event.seq) {
        insertAt -= 1;
      }
      _events.insert(insertAt, event);
      added += 1;
    }
    if (added > 0 && !_eventsController.isClosed) {
      _eventsController.add(List<SessionEvent>.unmodifiable(_events));
    }
    return added;
  }

  /// 已装载的最早 seq(loadOlder 的 beforeSeq 锚点)。
  int? get earliestLoadedSeq =>
      _events.isEmpty ? null : _events.first.seq;

  /// 服务端还有更早的历史(loadHistory 尾页 hasMore 回填;loadOlder 消费)。
  bool hasOlder = false;

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

  /// 拉取某会话的历史尾页(默认 50 条;性能契约见实现)。
  /// 实现必须幂等安全(重复调用靠 seq 去重)。
  Future<void> loadHistory(String sessionId);

  /// 向前补一页更早历史(无更早时 no-op)。
  Future<void> loadOlder(String sessionId);
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

  /// 装载历史尾页(beforeSeq 缺席 = 最新 50 条,附带 projections 水位快照)。
  ///
  /// 性能契约(2026-08-15 回写):默认只拉一页 —— 启动/切会话必须首屏快;
  /// 更早历史走 [loadOlder](轨迹页「加载更早」/未来聊天窗向上翻页)。
  /// full: true 保留取全量语义(无 lib 内调用方,冒烟/调试用)。
  @override
  Future<void> loadHistory(String sessionId,
      {int? maxMessages, bool full = false}) async {
    maxMessages ??= 50;
    final log = logFor(sessionId);
    var hasMore = await _fetchPage(sessionId, log, maxMessages: maxMessages);
    while (full && hasMore) {
      final earliest = log.earliestLoadedSeq;
      if (earliest == null) break;
      hasMore = await _fetchPage(sessionId, log,
          maxMessages: maxMessages, beforeSeq: earliest);
    }
  }

  /// 向前补一页(轨迹「加载更早」;幂等:无更早时 no-op)。
  @override
  Future<void> loadOlder(String sessionId, {int? maxMessages}) async {
    final log = logFor(sessionId);
    final earliest = log.earliestLoadedSeq;
    if (!log.hasOlder || earliest == null) return;
    await _fetchPage(sessionId, log,
        maxMessages: maxMessages ?? 50, beforeSeq: earliest);
  }

  /// 拉单页并落地;返回服务端 hasMore(空页视作无更多)。
  Future<bool> _fetchPage(
    String sessionId,
    SessionLog log, {
    required int maxMessages,
    int? beforeSeq,
  }) async {
    final payload = <String, dynamic>{
      'sessionId': sessionId,
      'maxMessages': maxMessages,
      if (beforeSeq != null) 'beforeSeq': beforeSeq,
    };
    final value = await api.call(
      RpcMethods.sessionHistory,
      payload,
      parse: SessionHistoryValue.fromJson,
    );
    log.appendAll([for (final entry in value.events) entry.event]);
    final block = value.projections;
    if (block != null) {
      for (final key in block.values.keys) {
        log.projections[key] = block.values[key];
      }
      if (block.asOfSeq > log.projectionWatermark) {
        log.projectionWatermark = block.asOfSeq;
      }
    }
    log.hasOlder = value.hasMore && value.events.isNotEmpty;
    return log.hasOlder;
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

  /// session.models:目录 + 当前选择 + routable(prompt 前不可路由 → model-unavailable)。
  Future<SessionModelsValue> sessionModels(String sessionId) => api.call(
        RpcMethods.sessionModels,
        <String, dynamic>{'sessionId': sessionId},
        parse: SessionModelsValue.fromJson,
      );

  /// session.selectModel:选择可与目录成员无关(服务端语义)。
  Future<SessionSelectModelValue> selectModel(
    String sessionId, {
    required String provider,
    required String model,
    String? reasoningEffort,
  }) =>
      api.call(
        RpcMethods.sessionSelectModel,
        <String, dynamic>{
          'sessionId': sessionId,
          'provider': provider,
          'model': model,
          if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        },
        parse: SessionSelectModelValue.fromJson,
      );

  /// session.search:侧栏搜索(query ≤500 字符,分页 hasMore)。
  Future<SessionSearchValue> sessionSearch(String query) => api.call(
        RpcMethods.sessionSearch,
        <String, dynamic>{'query': query},
        parse: SessionSearchValue.fromJson,
      );

  /// session.fork:atSeq 锚点须映射到已闭合 turn(turn 未闭合 → fork-unavailable)。
  /// fork 后 refresh(新会话入列)。
  Future<SessionForkValue> forkSession(String sessionId, {int? atSeq}) async {
    final value = await api.call(
      RpcMethods.sessionFork,
      <String, dynamic>{
        'sessionId': sessionId,
        if (atSeq != null) 'atSeq': atSeq,
      },
      parse: SessionForkValue.fromJson,
    );
    logFor(value.sessionId);
    unawaited(refresh().catchError((Object _) {}));
    return value;
  }

  /// session.rename:响应回带的规范化 title+seq 先落本地格,
  /// 推送 session/projection 帧高 seq 覆盖(乱序安全,见 DSH-PROTOCOL §5)。
  Future<SessionRenameValue> renameSession(String sessionId, String title) async {
    final value = await api.call(
      RpcMethods.sessionRename,
      <String, dynamic>{'sessionId': sessionId, 'title': title},
      parse: SessionRenameValue.fromJson,
    );
    final log = _logs[sessionId];
    log?.applyProjection('title', <String, dynamic>{'title': value.title}, value.seq);
    unawaited(refresh().catchError((Object _) {}));
    return value;
  }

  /// 会话导出:GET /api/session.export 流式 ZIP(非 RPC 面)到本地文件。
  Future<void> exportSessionZip(String sessionId, String filePath,
      {bool includeDescendants = true}) async {
    final sink = File(filePath).openWrite();
    try {
      await api.download(
        '/api/session.export',
        queryParameters: <String, String>{
          'sessionId': sessionId,
          'includeDescendants': includeDescendants.toString(),
        },
        consume: (c) async => sink.add(c),
      );
    } finally {
      await sink.close();
    }
  }

  /// 从投影水位取 imageLimits(未装载历史时为 null —— 预拒退化为服务端权威)。
  AttachmentLimits? attachmentLimitsFor(String sessionId) {
    final values = _logs[sessionId]?.projections;
    if (values == null) return null;
    final raw = values['imageLimits'];
    if (raw is! Map<String, dynamic>) return null;
    return AttachmentLimits.fromProjection(raw);
  }

  /// 带图 prompt:本地预拒(imageLimits 缺失时跳过预检,服务端权威)。
  Future<SessionPromptValue> promptWithImages(
    String sessionId,
    String text,
    List<PendingImage> images, {
    String mode = 'queue',
    String? clientTimeZone,
  }) async {
    final limits = attachmentLimitsFor(sessionId);
    if (limits != null) {
      final err = validateImages(images, limits);
      if (err != null) {
        throw ArgumentError('图片被本地预拒: ' + err);
      }
    }
    final request = <String, dynamic>{
      'sessionId': sessionId,
      'mode': mode,
      'content': buildPromptContent(text, images),
    };
    if (clientTimeZone != null) request['clientTimeZone'] = clientTimeZone;
    return api.call(
      RpcMethods.sessionPrompt,
      request,
      parse: SessionPromptValue.fromJson,
    );
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
