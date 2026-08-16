// SessionStore — M2 会话领域状态。
//
// 职责(PLAN M2 / DSH-PROTOCOL §5):
// - 代际 ready → 全量重取 session.list(无 since 续传,重连=重开流+重取)
// - session.history 尾页(beforeSeq 缺席)装载事件日志 + projections 水位
// - mux session/event 增量按 seq 去重追加(重连重放安全)
// - session/projection 高 seq 覆盖低 seq;host/session-status 折叠 running
// - 多客户端折叠(2026-08-15 bug 修复,对齐 web recordMutation 语义):
//   host/session-added → 新会话即时入列(web 端新建的手机可见);
//   host/session-removed → 普通会话移出、subagent 只折 running;
//   user/message 事件 → 摘要 updatedAt 推进(终止会话被 web 端重启后
//   手机侧栏时间/运行态随之刷新 —— 此前完全不更新,即本修复的 bug)
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

  /// 从 atSeq 锚点分叉子会话,返回子会话 id(web 消息操作区「分叉」)。
  Future<String> fork(String sessionId, {int? atSeq});
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

  // 会话投影 overlay(复刻 rc.6 web ProjectionValueStore):
  // host 是唯一计算点(title 的 fallback=首条用户消息前 N 词、LLM 摘要
  // 均在 host 侧落成 session/title 事件),客户端只收整值 ——
  // session/list 行内基线、session/history 尾页块、session/projection 推送
  // 帧、rename 回执四路汇入,单一规则「高 seq 覆盖低 seq」。
  // 侧栏读摘要流,不读懒注册的日志 —— 没有这层 overlay,标题永远停在
  // list 快照(回落 cwd 目录名),fallback→LLM 摘要的演进不可见。
  final Map<String, Map<String, dynamic>> _projectionValues =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, int>> _projectionSeqs =
      <String, Map<String, int>>{};
  StreamSubscription<ConnectionSnapshot>? _snapshotsSub;
  StreamSubscription<MuxFrame>? _muxSub;
  StreamSubscription<HostFrame>? _hostSub;
  int _lastReadyGeneration = 0;
  bool _started = false;
  int listCalls = 0;

  /// 会话列表快照流。
  Stream<List<SessionSummary>> get summaries => _summariesController.stream;

  /// 当前快照。
  /// 当前快照(已合并投影 overlay;title 等键为最新值)。
  List<SessionSummary> get currentSummaries =>
      List<SessionSummary>.unmodifiable(_projectedSummaries(_summaries));

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

  /// 投影单键落地(高 seq 覆盖低 seq;低/等 seq 丢弃,重放帧零副作用)。
  /// 返回是否有键值更新(调用方据此决定是否重发摘要流)。
  bool _applyProjectionValue(String sessionId, String key, dynamic value, int seq) {
    final seqs = _projectionSeqs.putIfAbsent(sessionId, () => <String, int>{});
    if ((seqs[key] ?? -1) >= seq) return false;
    seqs[key] = seq;
    _projectionValues.putIfAbsent(sessionId, () => <String, dynamic>{})[key] = value;
    return true;
  }

  /// 把 overlay 合并进摘要列表(仅重建有新键值的行;无 overlay 原样返回)。
  List<SessionSummary> _projectedSummaries(List<SessionSummary> items) {
    if (_projectionValues.isEmpty) return items;
    return [
      for (final s in items) _mergeOne(s),
    ];
  }

  SessionSummary _mergeOne(SessionSummary s) {
    final overlay = _projectionValues[s.sessionId];
    if (overlay == null || overlay.isEmpty) return s;
    final seqs = _projectionSeqs[s.sessionId] ?? const <String, int>{};
    final base = s.projections?.values ?? const <String, dynamic>{};
    // overlay 即读路径(web ProjectionValueStore 语义):refresh 已把行内
    // 块 per-key 应用进 overlay(此后 overlay seq >= 块水位),推送帧只在
    // 更高 seq 时改写 —— 因此 overlay 键无条件胜出行块值。列表块是
    // 「部分基线」(冷缓存只带 version-matching 键;活体实测 rc.6 host
    // 的 list 行可带 6+ 键但唯独缺 title,且 asOfSeq 很高),缺席的键
    // 不能凭块级水位清掉已收到的 title —— 那正是「标题变回目录名」
    // 的根因:块 asOfSeq(= 各键最低水位或日志尾)高于 overlay title
    // seq 时,旧门槛判据把 title 丢掉,显示回落 cwd 目录名。
    final merged = <String, dynamic>{...base, ...overlay};
    var asOf = s.projections?.asOfSeq ?? -1;
    for (final entry in overlay.entries) {
      final seq = seqs[entry.key] ?? -1;
      if (seq > asOf) asOf = seq;
    }
    return SessionSummary(
      sessionId: s.sessionId,
      updatedAt: s.updatedAt,
      running: s.running,
      blank: s.blank,
      parentSessionId: s.parentSessionId,
      origin: s.origin,
      cwd: s.cwd,
      agentPreset: s.agentPreset,
      projections: SessionProjectionsBlock(asOfSeq: asOf, values: merged),
    );
  }

  /// 重发摘要流(投影/状态帧后调用,侧栏即时更新)。
  void _emitSummaries() {
    if (_summariesController.isClosed) return;
    _summariesController.add(
      List<SessionSummary>.unmodifiable(_projectedSummaries(_summaries)),
    );
  }

  /// 全量重取会话列表。
  ///
  /// 并发合并(web manager listInflight 同构):同一时刻只允许一个
  /// session.list 在飞,后续调用共享同一次往返 —— 两个并发响应乱序
  /// 落地时,陈旧快照会把已应用的新状态整体盖回去。
  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    return _refreshInFlight ??= _doRefresh();
  }

  Future<void>? _refreshInFlight;

  /// 拉取期间到达的变更帧缓存(响应落地后按序重放;web listMutations)。
  List<void Function()> _pendingMutations = <void Function()>[];

  /// 变更帧在拉取在飞时登记重放(HTTP 响应慢于 WS 帧时,快照里是旧值;
  /// 不重放会把已折叠的变更覆盖回去 —— running=false 已到却被快照里的
  /// true 盖回,侧栏 loading 永久卡死,即用户实报 bug)。
  void _recordMutation(void Function() replay) {
    if (_refreshInFlight != null) _pendingMutations.add(replay);
  }

  Future<void> _doRefresh() async {
    try {
      final value = await api.call(
        RpcMethods.sessionList,
        <String, dynamic>{},
        parse: SessionListValue.fromJson,
      );
      if (_disposed) return;
      _summaries = value.items;
      // 行内投影基线 seed 进 overlay(冷会话的持久化缓存行,可能滞后但不错;
      // asOfSeq 标明多旧),再由 overlay 统一投影回摘要。
      final alive = <String>{};
      for (final s in _summaries) {
        alive.add(s.sessionId);
        final block = s.projections;
        if (block == null) continue;
        for (final key in block.values.keys) {
          _applyProjectionValue(s.sessionId, key, block.values[key], block.asOfSeq);
        }
      }
      // 已消失会话的 overlay 行回收(防长期增长)。
      _projectionValues.removeWhere((id, _) => !alive.contains(id));
      _projectionSeqs.removeWhere((id, _) => !alive.contains(id));
      // 基线落地 → 重放拉取期间到达的变更。先清在飞标记:重放的折叠
      // 会再过 _recordMutation,不得二次登记(否则自增殖)。
      _refreshInFlight = null;
      final pending = _pendingMutations;
      _pendingMutations = <void Function()>[];
      for (final replay in pending) {
        replay();
      }
      _emitSummaries();
      listCalls += 1;
      // 懒注册:不预建日志 —— 会话在 UI 打开(logFor/loadHistory)时才登记;
      // 已存在日志靠 seq 去重天然保留(重连重取安全)。
    } catch (_) {
      // 失败的拉取不落地基线:本轮登记的变更无需重放 —— 帧到达时的直接
      // 折叠已生效,下一次拉取的快照比它们新(web:失败拉取的
      // listMutations 作废;跨拉取重放反而会用陈旧值覆盖新快照)。
      _pendingMutations = <void Function()>[];
      rethrow;
    } finally {
      _refreshInFlight = null;
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

  /// session.history 单次尝试的时限。历史装载走主机事件日志回放,大日志/
  /// 冷启动时可能超过 30s 默认 unary 超时(实测 ApiTimeout 即此因),放宽到 45s。
  static const Duration _kHistoryTimeout = Duration(seconds: 45);

  /// 瞬时故障(超时/载波)自动重试次数(含首次共 3 次)与退避间隔。
  /// 业务错误(RpcBusinessError,如 session-not-found)不重试,直接上抛。
  static const int _kHistoryAttempts = 3;
  static const List<Duration> _kHistoryBackoff = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 1500),
  ];

  /// 拉单页并落地;返回服务端 hasMore(空页视作无更多)。
  /// 超时/载波故障自动退避重试,重试耗尽抛最后错误(调用方决定提示与
  /// 手动重试入口 —— 见 ChatViewModel.retryHistory)。
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
    Object? lastError;
    for (var attempt = 0; attempt < _kHistoryAttempts; attempt++) {
      try {
        final value = await api.call(
          RpcMethods.sessionHistory,
          payload,
          parse: SessionHistoryValue.fromJson,
          timeout: _kHistoryTimeout,
        );
        log.appendAll([for (final entry in value.events) entry.event]);
        final block = value.projections;
        var overlayChanged = false;
        if (block != null) {
          for (final key in block.values.keys) {
            log.projections[key] = block.values[key];
            // 尾页投影块同样 seed overlay(web installWindow → store.seed):
            // 打开一个冷会话,其侧栏行标题随即对齐持久化缓存值。
            if (_applyProjectionValue(
              sessionId,
              key,
              block.values[key],
              block.asOfSeq,
            )) {
              overlayChanged = true;
            }
          }
          // 尾页块是「全量基线」(host 侧所有已注册投影键的一致切面,
          // 与 list 行的部分基线不同):块中缺席且 seq 不高于切面的
          // overlay 键 = 该能力在切面处已缺席,清除防幻影键
          // (web seed 的 clear 分支);更新的推送帧(seq > 切面)保留。
          final valuesMap = _projectionValues[sessionId];
          final seqsMap = _projectionSeqs[sessionId];
          if (valuesMap != null && seqsMap != null) {
            final dead = <String>[
              for (final key in valuesMap.keys)
                if (!block.values.containsKey(key) &&
                    (seqsMap[key] ?? -1) <= block.asOfSeq)
                  key,
            ];
            for (final key in dead) {
              valuesMap.remove(key);
              seqsMap.remove(key);
              overlayChanged = true;
            }
          }
          if (block.asOfSeq > log.projectionWatermark) {
            log.projectionWatermark = block.asOfSeq;
          }
        }
        if (overlayChanged) _emitSummaries();
        log.hasOlder = value.hasMore && value.events.isNotEmpty;
        return log.hasOlder;
      } on ApiTimeout catch (e) {
        lastError = e;
      } on CarrierError catch (e) {
        lastError = e;
      }
      if (attempt < _kHistoryAttempts - 1) {
        await Future<void>.delayed(_kHistoryBackoff[attempt]);
      }
    }
    throw lastError!;
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
    // 合成 upsert 登记(web create 后 recordMutation 同构):refresh 已并
    // 发合并,若共享的在飞拉取快照早于本次创建,响应里没有新会话 ——
    // 基线落地后重放此记录保证新行可见。
    _recordMutation(() => _mergeAddedFields(
          sessionId: value.sessionId,
          blank: true,
          cwd: cwd,
          agentPreset: value.agentPreset,
        ));
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

  /// 窄视图适配:返回子会话 id(VM 直接切换到子会话,对齐 web open(childId))。
  @override
  Future<String> fork(String sessionId, {int? atSeq}) async =>
      (await forkSession(sessionId, atSeq: atSeq)).sessionId;

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
    _recordMutation(() => _mergeAddedFields(sessionId: value.sessionId, blank: true));
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
    // 显式用户动作 → 登记日志(懒注册的例外:受用户操作次数约束,不受帧流量约束);
    // 登记后服务端投影回声帧才能落地。title 投影值是**纯字符串**
    // (rc.6 wire:SessionProjectionMap['title']: string | null),非嵌套 map。
    final log = logFor(sessionId);
    log.applyProjection('title', value.title, value.seq);
    if (_applyProjectionValue(sessionId, 'title', value.title, value.seq)) {
      _emitSummaries();
    }
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
    // 懒注册:只向「已打开」的日志投递(UI 经 logFor/loadHistory 打开后才存在)。
    // 无差别 logFor 会让每个活跃会话(含全部 subagent)都在本地长出一份日志,
    // 长连接下内存无界增长;未打开会话的历史在打开时按页拉取即可。
    if (frame is MuxFrameSessionEvent) {
      _logs[frame.sessionId]?.append(frame.event);
      // 活动折叠(复刻 web recordMutation 'activity'):任何客户端(含 web 端)
      // 直发的用户消息都推进摘要 updatedAt —— 侧栏「最后会话时间」的数据源。
      // 不做这步,终止会话被 web 端重启后,手机侧该行永远停在旧时间。
      if (frame.event.type == 'user/message' && frame.event.data is Map) {
        final source = (frame.event.data as Map)['source'];
        if (source is Map && source['kind'] == 'user') {
          _bumpActivity(frame.sessionId, frame.event.time);
        }
      }
    } else if (frame is MuxFrameSessionProjection) {
      _logs[frame.sessionId]
          ?.applyProjection(frame.key, frame.value, frame.seq);
      // overlay 无条件落地(不限已打开会话 —— web 语义:标题投影对整个
      // 列表生效,侧栏未打开的会话也要随 fallback→LLM 摘要演进刷新)。
      if (_applyProjectionValue(
        frame.sessionId,
        frame.key,
        frame.value,
        frame.seq,
      )) {
        _emitSummaries();
      }
    }
    // session/subscribed 水位、queue/jobs 快照收敛:M3 再折叠。
  }

  void _onHostFrame(HostFrame frame) {
    if (frame is HostFrameHostSessionStatus) {
      _applyStatusFlip(frame.sessionId, frame.running);
    } else if (frame is HostFrameHostSessionAdded) {
      _mergeAddedSession(frame);
    } else if (frame is HostFrameHostSessionRemoved) {
      _removeSummary(frame.sessionId);
    }
  }

  /// running 翻转(复刻 web applyMutation 'status'):running=true 清 blank
  /// (首 turn 开跑即非空会话);同值重放(重连重放帧)零副作用。
  void _applyStatusFlip(String sessionId, bool running) {
    _recordMutation(() => _applyStatusFlip(sessionId, running));
    final idx = _summaries.indexWhere((s) => s.sessionId == sessionId);
    if (idx < 0) return;
    final old = _summaries[idx];
    if (old.running == running && !(running && old.blank)) return;
    // SessionSummary 是不可变 wire 模型;重建列表项(running/blank 翻转)。
    final updated = SessionSummary(
      sessionId: old.sessionId,
      updatedAt: old.updatedAt,
      running: running,
      blank: old.blank && !running,
      parentSessionId: old.parentSessionId,
      origin: old.origin,
      cwd: old.cwd,
      agentPreset: old.agentPreset,
      projections: old.projections,
    );
    final next = List<SessionSummary>.of(_summaries);
    next[idx] = updated;
    _summaries = next;
    _emitSummaries();
  }

  /// host/session-added 并入(复刻 web mergeSummary upsert):任何客户端新建
  /// 的会话(含 web 端)即时入列 —— 不做这步,web 端新开的会话在手机侧栏
  /// 要等到下次重连 refresh 才出现。已存在的行(与 refresh 竞态)只补缺失
  /// 字段,绝不覆盖列表刷新带来的数据。
  void _mergeAddedSession(HostFrameHostSessionAdded frame) {
    _recordMutation(() => _mergeAddedSession(frame));
    _mergeAddedFields(
      sessionId: frame.sessionId,
      blank: frame.blank,
      parentSessionId: frame.parentSessionId,
      origin: frame.origin,
      cwd: frame.cwd,
      agentPreset: frame.agentPreset,
    );
  }

  /// added/upsert 折叠本体(host/session-added 帧、create/fork 合成记录共用)。
  void _mergeAddedFields({
    required String sessionId,
    required bool blank,
    String? parentSessionId,
    String? origin,
    String? cwd,
    String? agentPreset,
  }) {
    final idx = _summaries.indexWhere((s) => s.sessionId == sessionId);
    if (idx < 0) {
      _summaries = <SessionSummary>[
        SessionSummary(
          sessionId: sessionId,
          updatedAt: DateTime.now().millisecondsSinceEpoch.toDouble(),
          running: false,
          blank: blank,
          parentSessionId: parentSessionId,
          origin: origin,
          cwd: cwd,
          agentPreset: agentPreset,
        ),
        ..._summaries,
      ];
      _emitSummaries();
      return;
    }
    final old = _summaries[idx];
    final mergedBlank = old.blank && blank;
    final mergedParent = old.parentSessionId ?? parentSessionId;
    final mergedOrigin = old.origin ?? origin;
    final mergedCwd = old.cwd ?? cwd;
    final mergedPreset = old.agentPreset ?? agentPreset;
    if (old.blank == mergedBlank &&
        old.parentSessionId == mergedParent &&
        old.origin == mergedOrigin &&
        old.cwd == mergedCwd &&
        old.agentPreset == mergedPreset) {
      return; // 竞态后到帧无新信息:零副作用
    }
    final next = List<SessionSummary>.of(_summaries);
    next[idx] = SessionSummary(
      sessionId: old.sessionId,
      updatedAt: old.updatedAt,
      running: old.running,
      blank: mergedBlank,
      parentSessionId: mergedParent,
      origin: mergedOrigin,
      cwd: mergedCwd,
      agentPreset: mergedPreset,
      projections: old.projections,
    );
    _summaries = next;
    _emitSummaries();
  }

  /// host/session-removed(复刻 web durableSubagent 语义):subagent 会话在
  /// host 侧 dispose 后仍可从磁盘 resume,只折叠 running 不删行;普通会话
  /// 即时移出并回收投影 overlay(防幽灵行 + 防长期增长)。
  void _removeSummary(String sessionId) {
    _recordMutation(() => _removeSummary(sessionId));
    final idx = _summaries.indexWhere((s) => s.sessionId == sessionId);
    if (idx < 0) return;
    if (_summaries[idx].origin == 'subagent') {
      _applyStatusFlip(sessionId, false);
      return;
    }
    _summaries = <SessionSummary>[
      for (var i = 0; i < _summaries.length; i++)
        if (i != idx) _summaries[i],
    ];
    _projectionValues.remove(sessionId);
    _projectionSeqs.remove(sessionId);
    _emitSummaries();
  }

  /// 活动时间推进(复刻 web applyMutation 'activity'):只前进不回退,
  /// 重连重放的同事件(同 time)天然零副作用。
  void _bumpActivity(String sessionId, double time) {
    _recordMutation(() => _bumpActivity(sessionId, time));
    final idx = _summaries.indexWhere((s) => s.sessionId == sessionId);
    if (idx < 0) return;
    final old = _summaries[idx];
    if (time <= old.updatedAt) return;
    final updated = SessionSummary(
      sessionId: old.sessionId,
      updatedAt: time,
      running: old.running,
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
    _emitSummaries();
  }
}
