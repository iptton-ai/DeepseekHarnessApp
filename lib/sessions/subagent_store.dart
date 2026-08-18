// SubagentStore — W1-C subagent 域:子代理目录 + 子会话 transcript 的装载与续聊/中断。
//
// 契约(DSH-PROTOCOL §3 subagent 组 + subagents.schema.js):
// - subagent.list({parentSessionId}) → {entries, parentAvailable};目录按 parent 缓存,
//   失效点 = 代际 ready(重连=全量重取);host 帧行内维护(见下)
// - subagent.history({parentSessionId, childSessionId, mode, beforeSeq?, maxMessages?})
//   → {events, hasMore};mode 取自目录行('one-shot'|'continuable'),store 不假设
// - subagent.prompt / subagent.interrupt 的 mode 恒为 'continuable';仅当目录行
//   parentAvailable==true 时 UI 才暴露续聊入口(store 不复查,服务端仍权威)
// - transcript 是只读事件日志(复用 SessionEvent):分页装载 + seq 去重,缓存跨代际
//   保留;mux session/event 帧到达已缓存 child 时增量追加(运行中子会话实时更新)
//
// 目录状态机(对齐 web dsh-client-runtime sessions/manager.refreshSubagents):
// - per-parent 三态 loading/ready/error;错误保留旧 entries(UI 旧数据可用 + 可重试);
// - 单飞复用(同一 parent 并发刷新共享一次往返);
// - host/session-status → child 行 activity **行内翻转**(零 RPC,不整目录失效);
// - host/session-added(origin=subagent)→ 子行 hasChildren 正提示 + 防抖重拉其父
//   目录(新孙行可见;对齐 web markCatalogParentExpandable + scheduleCatalogRefresh);
// - host/session-removed → 行内折 activity;该会话作为目录 owner 时 parentAvailable
//   即时置 false(web:removed 会话不再是任何 catalog 的投递属主)。
//
// 后代聚合(对齐 web indexSubagentDescendants):注入会话摘要流后,origin=='subagent'
// 的行沿 parentId 链向上累计 count/runningCount(普通 fork 断链 —— 每个可见会话只
// 拥有「不间断 subagent 血统」的后代);入口按钮计数与可见性以此为准。
//
// 不变式:transcript 事件 seq 严格去重;错误不吞,原样抛给 UI
// (subagentErrorMessage 提供可读文案)。
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 单个子会话的只读事件日志(seq 去重追加,与 SessionLog 同语义)。
class SubagentTranscript {
  SubagentTranscript(this.childSessionId);

  final String childSessionId;
  final List<SessionEvent> _events = <SessionEvent>[];
  final Set<int> _seenSeqs = <int>{};
  final StreamController<List<SessionEvent>> _eventsController =
      StreamController<List<SessionEvent>>.broadcast();

  /// 当前事件快照(seq 升序)。
  List<SessionEvent> get events => List<SessionEvent>.unmodifiable(_events);

  /// 事件变更流(装载/增量追加后)。
  Stream<List<SessionEvent>> get eventStream => _eventsController.stream;

  int get lastSeq => _events.isEmpty ? -1 : _events.last.seq;

  /// 已装载的最早 seq(loadOlder 的 beforeSeq 锚点)。
  int? get earliestLoadedSeq => _events.isEmpty ? null : _events.first.seq;

  /// 服务端还有更早历史(readTranscript 尾页 hasMore 回填)。
  bool hasOlder = false;

  /// 按 seq 去重追加(翻页补齐 + mux 增量共用,重连重放安全)。
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

  /// 批量追加(历史页装载):去重后只发一次广播
  /// (对齐 SessionLog.appendAll 的性能契约)。
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

  Future<void> dispose() => _eventsController.close();
}

/// 目录行可用性:diagnostic 行可读但不可操作(UI 据此禁用查看/续聊)。
bool subagentEntryUsable(SubagentListEntry entry) => entry is SubagentListEntryChild;

/// 目录行标题:child 用 label(无则回退 id);diagnostic 行显示诊断原因。
String subagentEntryTitle(SubagentListEntry entry) => switch (entry) {
      SubagentListEntryChild c => c.label ?? c.id,
      SubagentListEntryDiagnostic d => '诊断(${d.reason})',
    };

/// subagent 业务错误 → 用户可读文案(UI 直接呈现,不许静默吞)。
String subagentErrorMessage(Object error) {
  if (error is RpcBusinessError) {
    return switch (error.error) {
      RpcErrorSubagentNotFound() => '子代理不存在或已失效',
      RpcErrorSubagentParentUnavailable() => '父会话不可用,无法操作该子代理',
      RpcErrorSubagentNotResumable() => '该子代理不可续聊(一次性执行或已结束)',
      RpcErrorSubagentUnauthorized() => '无权访问该子代理',
      RpcErrorSubagentDeliveryUnavailable() => '子代理消息投递暂不可用,请稍后重试',
      RpcErrorSubagentCatalogDiagnostic() => '子代理目录存在诊断异常,部分行不可用',
      _ => '操作失败(${error.error.runtimeType})',
    };
  }
  if (error is CarrierError) return '传输失败: $error';
  if (error is ApiTimeout) return '请求超时: $error';
  return '操作失败: $error';
}

/// 目录装载状态(对齐 web runtime refreshSubagents 三态)。
enum SubagentCatalogPhase { loading, ready, error }

/// 一个 parent 的子代理目录快照 + 装载状态。
///
/// error 态保留上次的 [entries](UI 旧数据仍可用,带重试);loading 态
/// 同样保留(展开分支时的既有行不闪烁)。
class SubagentCatalogState {
  const SubagentCatalogState({
    required this.entries,
    required this.parentAvailable,
    required this.phase,
    this.error,
  });

  final List<SubagentListEntry> entries;
  final bool parentAvailable;
  final SubagentCatalogPhase phase;
  final Object? error;
}

/// 某会话的「不间断 subagent 血统」后代计数(对齐 web SubagentDescendantSummary)。
class SubagentDescendants {
  const SubagentDescendants({required this.count, required this.runningCount});

  final int count;
  final int runningCount;
}

/// 纯聚合:每个 origin=='subagent' 的会话沿 parentId 链向上累计,直到链断
/// (父不是 subagent origin / 父不在列表 / 环)。普通 fork(无 origin)不传播
/// —— 每个可见会话只拥有不间断血统的后代。环容错(seen 集)。
Map<String, SubagentDescendants> indexSubagentDescendants(
    List<SessionSummary> summaries) {
  final byId = <String, SessionSummary>{
    for (final s in summaries) s.sessionId: s,
  };
  final indexed = <String, _MutableDescendants>{};
  for (final descendant in summaries) {
    if (descendant.origin != 'subagent') continue;
    final running = descendant.running;
    var current = descendant;
    final seen = <String>{};
    while (current.parentSessionId != null &&
        current.origin == 'subagent' &&
        !seen.contains(current.sessionId)) {
      seen.add(current.sessionId);
      final parent = byId[current.parentSessionId!];
      if (parent == null) break;
      final aggregate = indexed.putIfAbsent(
          current.parentSessionId!, () => _MutableDescendants());
      aggregate.count += 1;
      if (running) aggregate.runningCount += 1;
      current = parent;
    }
  }
  return {
    for (final e in indexed.entries)
      e.key: SubagentDescendants(
          count: e.value.count, runningCount: e.value.runningCount),
  };
}

class _MutableDescendants {
  int count = 0;
  int runningCount = 0;
}

/// UI 依赖的窄视图(便于 widget 测试用假实现注入,不碰 socket;
/// 与 SessionStoreView 同哲学)。UI 只消费广播流与方法,不碰 wire。
abstract class SubagentStoreView {
  Stream<Map<String, SubagentCatalogState>> get catalogs;
  Stream<Map<String, SubagentDescendants>> get descendants;
  Map<String, SubagentDescendants> get currentDescendants;
  SubagentCatalogState? catalogFor(String parentSessionId);
  SessionSummary? summaryFor(String sessionId);
  SubagentTranscript transcriptFor(String childSessionId);
  Future<SubagentCatalogState> listChildren(String parentSessionId,
      {bool force = false});
  Future<List<SessionEvent>> readTranscript(
    String parentSessionId,
    String childSessionId, {
    required String mode,
    int? maxMessages,
    bool full,
  });
  Future<List<SessionEvent>> loadOlderTranscript(
    String parentSessionId,
    String childSessionId, {
    required String mode,
    int? maxMessages,
  });
  Future<SubagentPromptValue> promptChild(
    String parentSessionId,
    String childSessionId,
    String text, {
    String? clientTimeZone,
  });
  Future<SubagentInterruptValue> interruptChild(
      String parentSessionId, String childSessionId);
  Future<void> invalidateChildren(String parentSessionId);
}

class SubagentStore implements SubagentStoreView {
  SubagentStore({required this.api, required this.connection,
      Stream<List<SessionSummary>>? summaries}) {
    _catalogsController =
        StreamController<Map<String, SubagentCatalogState>>.broadcast();
    _descendantsController =
        StreamController<Map<String, SubagentDescendants>>.broadcast();
    _snapshotsSub = connection.snapshots.listen(_onSnapshot);
    _muxSub = connection.muxFrames.listen(_onMuxFrame);
    _hostSub = connection.hostFrames.listen(_onHostFrame);
    _summariesSub = summaries?.listen(_onSummaries);
  }

  final ApiClient api;
  final ConnectionController connection;

  late final StreamController<Map<String, SubagentCatalogState>> _catalogsController;
  late final StreamController<Map<String, SubagentDescendants>>
      _descendantsController;
  final Map<String, SubagentCatalogState> _catalogs =
      <String, SubagentCatalogState>{};
  final Map<String, SubagentTranscript> _transcripts =
      <String, SubagentTranscript>{};
  final Map<String, SessionSummary> _summariesById = <String, SessionSummary>{};
  Map<String, SubagentDescendants> _descendants =
      <String, SubagentDescendants>{};
  final Map<String, Future<void>> _catalogInflight = <String, Future<void>>{};
  final Set<String> _catalogStale = <String>{};
  final Map<String, Timer> _catalogDebounce = <String, Timer>{};
  StreamSubscription<ConnectionSnapshot>? _snapshotsSub;
  StreamSubscription<MuxFrame>? _muxSub;
  StreamSubscription<HostFrame>? _hostSub;
  StreamSubscription<List<SessionSummary>>? _summariesSub;
  int _lastReadyGeneration = 0;
  bool _disposed = false;

  /// 目录快照广播流(parentSessionId -> 装载状态)。
  @override
  Stream<Map<String, SubagentCatalogState>> get catalogs =>
      _catalogsController.stream;

  /// 后代聚合广播流(注入摘要流后每快照一发)。
  @override
  Stream<Map<String, SubagentDescendants>> get descendants =>
      _descendantsController.stream;

  /// 当前后代聚合快照。
  @override
  Map<String, SubagentDescendants> get currentDescendants => _descendants;

  /// 会话摘要镜像(行内标题/指标读取用;未注入摘要流为空表)。
  @override
  SessionSummary? summaryFor(String sessionId) => _summariesById[sessionId];

  /// 当前目录快照(未装载为 null)。
  @override
  SubagentCatalogState? catalogFor(String parentSessionId) =>
      _catalogs[parentSessionId];

  /// 取(或建)某子会话的只读日志。
  @override
  SubagentTranscript transcriptFor(String childSessionId) =>
      _transcripts.putIfAbsent(
          childSessionId, () => SubagentTranscript(childSessionId));

  /// 拉取(或命中缓存)某 parent 的直接 child 目录。
  ///
  /// 缓存命中即返回 ready 快照([force] 跳过);未命中/force 走 RPC 并推进
  /// loading→ready/error 状态机。**单飞**:同一 parent 并发刷新共享一次往返
  /// (对齐 web catalogInflight)。错误保留旧 entries,由调用方决定重试。
  @override
  Future<SubagentCatalogState> listChildren(String parentSessionId,
      {bool force = false}) async {
    // 单飞检查先行:loading 态已写入缓存表,后到者必须共享在飞往返
    // 而不是把 loading 快照当命中结果返回。
    if (!force && _catalogInflight.containsKey(parentSessionId)) {
      await _catalogInflight[parentSessionId];
      return _catalogs[parentSessionId]!;
    }
    if (!force &&
        _catalogs.containsKey(parentSessionId) &&
        _catalogs[parentSessionId]!.phase != SubagentCatalogPhase.error &&
        _catalogs[parentSessionId]!.phase != SubagentCatalogPhase.loading) {
      return _catalogs[parentSessionId]!;
    }
    final previous = _catalogs[parentSessionId];
    _catalogs[parentSessionId] = SubagentCatalogState(
      entries: previous?.entries ?? const <SubagentListEntry>[],
      parentAvailable: previous?.parentAvailable ?? false,
      phase: SubagentCatalogPhase.loading,
    );
    _emitCatalogs();
    final operation = _fetchCatalog(parentSessionId);
    _catalogInflight[parentSessionId] = operation;
    try {
      await operation;
    } finally {
      _catalogInflight.remove(parentSessionId);
      // 在飞响应早于触发 stale 的帧:settle 后补一拉才能收敛到最新。
      if (_catalogStale.remove(parentSessionId)) {
        unawaited(listChildren(parentSessionId, force: true));
      }
    }
    return _catalogs[parentSessionId]!;
  }

  Future<void> _fetchCatalog(String parentSessionId) async {
    try {
      final value = await api.call(
        RpcMethods.subagentList,
        <String, dynamic>{'parentSessionId': parentSessionId},
        parse: SubagentListValue.fromJson,
      );
      _catalogs[parentSessionId] = SubagentCatalogState(
        entries: value.entries,
        parentAvailable: value.parentAvailable,
        phase: SubagentCatalogPhase.ready,
      );
    } on Object catch (e) {
      // 错误保留旧 entries(UI 旧数据可用 + 可重试;对齐 web error 态)。
      final previous = _catalogs[parentSessionId];
      _catalogs[parentSessionId] = SubagentCatalogState(
        entries: previous?.entries ?? const <SubagentListEntry>[],
        parentAvailable: previous?.parentAvailable ?? false,
        phase: SubagentCatalogPhase.error,
        error: e,
      );
    }
    _emitCatalogs();
  }

  /// 显式重拉某 parent 的目录(prompt/interrupt 后 activity 可能翻转;host
  /// 帧行内维护已覆盖常规路径,此方法留作 UI 主动刷新入口)。
  @override
  Future<void> invalidateChildren(String parentSessionId) =>
      listChildren(parentSessionId, force: true);

  /// 装载子会话 transcript(subagent.history 分页取完;重复调用幂等,靠 seq 去重)。
  /// [mode] 来自目录行('one-shot'|'continuable'),store 不假设。
  /// 读子会话 transcript**尾页**(默认 50 条;性能契约对齐 loadHistory:
  /// 打开即全量拉取是隐性 DoS,更早走 [loadOlderTranscript])。
  @override
  Future<List<SessionEvent>> readTranscript(
    String parentSessionId,
    String childSessionId, {
    required String mode,
    int? maxMessages,
    bool full = false,
  }) async {
    final transcript =
        await _fetchTranscriptPage(parentSessionId, childSessionId, mode,
            maxMessages: maxMessages ?? 50);
    if (!full) return transcript.events;
    while (transcript.hasOlder) {
      final earliest = transcript.earliestLoadedSeq;
      if (earliest == null) break;
      await _fetchTranscriptPage(parentSessionId, childSessionId, mode,
          maxMessages: maxMessages ?? 50, beforeSeq: earliest);
    }
    return transcript.events;
  }

  /// 向前补一页(幂等:无更早时 no-op)。
  @override
  Future<List<SessionEvent>> loadOlderTranscript(
    String parentSessionId,
    String childSessionId, {
    required String mode,
    int? maxMessages,
  }) async {
    final transcript = transcriptFor(childSessionId);
    final earliest = transcript.earliestLoadedSeq;
    if (!transcript.hasOlder || earliest == null) return transcript.events;
    return _fetchTranscriptPage(parentSessionId, childSessionId, mode,
        maxMessages: maxMessages ?? 50, beforeSeq: earliest)
        .then((_) => transcript.events);
  }

  Future<SubagentTranscript> _fetchTranscriptPage(
    String parentSessionId,
    String childSessionId,
    String mode, {
    required int maxMessages,
    int? beforeSeq,
  }) async {
    final transcript = transcriptFor(childSessionId);
    final payload = <String, dynamic>{
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': mode,
      'maxMessages': maxMessages,
      if (beforeSeq != null) 'beforeSeq': beforeSeq,
    };
    final value = await api.call(
      RpcMethods.subagentHistory,
      payload,
      parse: SubagentHistoryValue.fromJson,
    );
    transcript.appendAll([for (final entry in value.events) entry.event]);
    transcript.hasOlder = value.hasMore && value.events.isNotEmpty;
    return transcript;
  }

  /// 续聊:mode 恒 'continuable';仅当目录行 parentAvailable==true 且 child 非
  /// one-shot/非运行中时 UI 才暴露入口(store 不复查,服务端仍权威)。
  @override
  Future<SubagentPromptValue> promptChild(
    String parentSessionId,
    String childSessionId,
    String text, {
    String? clientTimeZone,
  }) {
    final request = <String, dynamic>{
      'parentSessionId': parentSessionId,
      'childSessionId': childSessionId,
      'mode': 'continuable',
      'content': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'text', 'text': text},
      ],
    };
    if (clientTimeZone != null) request['clientTimeZone'] = clientTimeZone;
    return api.call(
      RpcMethods.subagentPrompt,
      request,
      parse: SubagentPromptValue.fromJson,
    );
  }

  /// 中断运行中的可继续子会话。
  @override
  Future<SubagentInterruptValue> interruptChild(
          String parentSessionId, String childSessionId) =>
      api.call(
        RpcMethods.subagentInterrupt,
        <String, dynamic>{
          'parentSessionId': parentSessionId,
          'childSessionId': childSessionId,
          'mode': 'continuable',
        },
        parse: SubagentInterruptValue.fromJson,
      );

  void _emitCatalogs() {
    if (!_catalogsController.isClosed) {
      _catalogsController
          .add(Map<String, SubagentCatalogState>.unmodifiable(_catalogs));
    }
  }

  void _onSummaries(List<SessionSummary> summaries) {
    if (_disposed) return;
    _summariesById
      ..clear()
      ..addAll({for (final s in summaries) s.sessionId: s});
    final next = indexSubagentDescendants(summaries);
    // 等值不重发(摘要流高频:每个投影帧/状态帧都整表发)。
    var changed = next.length != _descendants.length;
    if (!changed) {
      for (final e in next.entries) {
        final old = _descendants[e.key];
        if (old == null || old.count != e.value.count || old.runningCount != e.value.runningCount) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      _descendants = next;
      if (!_descendantsController.isClosed) _descendantsController.add(next);
    } else {
      _descendants = next;
    }
  }

  void _onSnapshot(ConnectionSnapshot snap) {
    if (_disposed || snap.phase != ConnectionPhase.ready) return;
    if (snap.generation <= _lastReadyGeneration) return;
    _lastReadyGeneration = snap.generation;
    // 重连=全量重取:目录缓存清空;transcript 保留(seq 去重,幂等补齐)。
    if (_catalogs.isNotEmpty) {
      _catalogs.clear();
      _emitCatalogs();
    }
  }

  void _onMuxFrame(MuxFrame frame) {
    // 子会话事件实时增量(仅已缓存 transcript;未打开过的 child 不预登记)。
    if (frame is MuxFrameSessionEvent) {
      _transcripts[frame.sessionId]?.append(frame.event);
    }
  }

  void _onHostFrame(HostFrame frame) {
    switch (frame) {
      case HostFrameHostSessionStatus():
        // child 运行翻转 → 所有已装目录的对应行**行内**翻转(零 RPC;
        // parentAvailable 只能重拉得知,常规路径由 added/removed 兜住)。
        _applyActivity(frame.sessionId, frame.running);
      case HostFrameHostSessionAdded():
        if (frame.origin == 'subagent' && frame.parentSessionId != null) {
          // 孙出生:① 子行(所有含该行的目录)hasChildren 正提示 —— 即使
          // 目录快照还没带上它,展开箭头先出现(web markCatalogParent
          // Expandable);② 防抖重拉「子」的目录,新孙行可见。
          _markExpandable(frame.parentSessionId!);
          _scheduleCatalogRefresh(frame.parentSessionId!);
        }
      case HostFrameHostSessionRemoved():
        // 行内折 activity(web:Activation 脱离≠删除 durable 子代,行保留)。
        _applyActivity(frame.sessionId, false);
        // 被移除的会话不再可能是任何目录的投递属主:parentAvailable 即时
        // 置 false(不等重拉 —— 关着的目录永远不会重拉)。
        final owned = _catalogs[frame.sessionId];
        if (owned != null && owned.parentAvailable) {
          _catalogs[frame.sessionId] = SubagentCatalogState(
            entries: owned.entries,
            parentAvailable: false,
            phase: owned.phase,
            error: owned.error,
          );
          _emitCatalogs();
        }
      default:
        break;
    }
  }

  /// 行内翻转某 child 在所有已装目录里的 activity(以及摘要镜像)。
  void _applyActivity(String sessionId, bool running) {
    final activity = running ? 'running' : 'inactive';
    var changed = false;
    for (final key in _catalogs.keys.toList()) {
      final catalog = _catalogs[key]!;
      var rowChanged = false;
      final entries = <SubagentListEntry>[];
      for (final e in catalog.entries) {
        if (e is SubagentListEntryChild &&
            e.id == sessionId &&
            e.activity != activity) {
          entries.add(SubagentListEntryChild(
            id: e.id,
            mode: e.mode,
            activity: activity,
            hasChildren: e.hasChildren,
            label: e.label,
          ));
          rowChanged = true;
        } else {
          entries.add(e);
        }
      }
      if (rowChanged) {
        _catalogs[key] = SubagentCatalogState(
          entries: entries,
          parentAvailable: catalog.parentAvailable,
          phase: catalog.phase,
          error: catalog.error,
        );
        changed = true;
      }
    }
    if (changed) _emitCatalogs();
  }

  /// 把所有已装目录里 id==[childSessionId] 的行标成可展开(hasChildren=true)。
  void _markExpandable(String childSessionId) {
    var changed = false;
    for (final key in _catalogs.keys.toList()) {
      final catalog = _catalogs[key]!;
      var rowChanged = false;
      final entries = <SubagentListEntry>[];
      for (final e in catalog.entries) {
        if (e is SubagentListEntryChild &&
            e.id == childSessionId &&
            !e.hasChildren) {
          entries.add(SubagentListEntryChild(
            id: e.id,
            mode: e.mode,
            activity: e.activity,
            hasChildren: true,
            label: e.label,
          ));
          rowChanged = true;
        } else {
          entries.add(e);
        }
      }
      if (rowChanged) {
        _catalogs[key] = SubagentCatalogState(
          entries: entries,
          parentAvailable: catalog.parentAvailable,
          phase: catalog.phase,
          error: catalog.error,
        );
        changed = true;
      }
    }
    if (changed) _emitCatalogs();
  }

  /// 防抖重拉某 parent 的目录(50ms;在飞响应早于触发帧时标 stale,
  /// settle 后由 listChildren 的 finally 补拉 —— 对齐 web scheduleCatalogRefresh)。
  void _scheduleCatalogRefresh(String parentSessionId) {
    if (!_catalogs.containsKey(parentSessionId)) return;
    if (_catalogDebounce.containsKey(parentSessionId)) return;
    _catalogDebounce[parentSessionId] = Timer(const Duration(milliseconds: 50), () {
      _catalogDebounce.remove(parentSessionId);
      if (_catalogInflight.containsKey(parentSessionId)) {
        _catalogStale.add(parentSessionId);
        return;
      }
      unawaited(listChildren(parentSessionId, force: true));
    });
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final t in _catalogDebounce.values) {
      t.cancel();
    }
    _catalogDebounce.clear();
    await _snapshotsSub?.cancel();
    await _muxSub?.cancel();
    await _hostSub?.cancel();
    await _summariesSub?.cancel();
    for (final t in _transcripts.values) {
      await t.dispose();
    }
    await _catalogsController.close();
    await _descendantsController.close();
  }
}
