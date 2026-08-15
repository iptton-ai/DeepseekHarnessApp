// SubagentStore — W1-C subagent 域:子代理目录 + 子会话 transcript 的装载与续聊/中断。
//
// 契约(DSH-PROTOCOL §3 subagent 组 + subagents.schema.js):
// - subagent.list({parentSessionId}) → {entries, parentAvailable};目录按 parent 缓存,
//   失效点 = 代际 ready(重连=全量重取)、父会话运行状态翻转(host/session-status)、
//   显式 invalidateChildren(prompt/interrupt 后由 UI 触发)
// - subagent.history({parentSessionId, childSessionId, mode, beforeSeq?, maxMessages?})
//   → {events, hasMore};mode 取自目录行('one-shot'|'continuable'),store 不假设
// - subagent.prompt / subagent.interrupt 的 mode 恒为 'continuable';仅当目录行
//   parentAvailable==true 时 UI 才暴露续聊入口(store 不复查,服务端仍权威)
// - transcript 是只读事件日志(复用 SessionEvent):分页装载 + seq 去重,缓存跨代际
//   保留;mux session/event 帧到达已缓存 child 时增量追加(运行中子会话实时更新)
//
// 不变式:目录缓存只增不减直到显式失效;transcript 事件 seq 严格去重;错误不吞,
// 原样抛给 UI(subagentErrorMessage 提供可读文案)。
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

class SubagentStore {
  SubagentStore({required this.api, required this.connection}) {
    _catalogsController =
        StreamController<Map<String, SubagentListValue>>.broadcast();
    _snapshotsSub = connection.snapshots.listen(_onSnapshot);
    _muxSub = connection.muxFrames.listen(_onMuxFrame);
    _hostSub = connection.hostFrames.listen(_onHostFrame);
  }

  final ApiClient api;
  final ConnectionController connection;

  late final StreamController<Map<String, SubagentListValue>> _catalogsController;
  final Map<String, SubagentListValue> _catalogs = <String, SubagentListValue>{};
  final Map<String, SubagentTranscript> _transcripts =
      <String, SubagentTranscript>{};
  StreamSubscription<ConnectionSnapshot>? _snapshotsSub;
  StreamSubscription<MuxFrame>? _muxSub;
  StreamSubscription<HostFrame>? _hostSub;
  int _lastReadyGeneration = 0;
  bool _disposed = false;

  /// 目录快照广播流(parentSessionId -> SubagentListValue)。
  Stream<Map<String, SubagentListValue>> get catalogs =>
      _catalogsController.stream;

  /// 当前目录快照(未装载为 null)。
  SubagentListValue? catalogFor(String parentSessionId) =>
      _catalogs[parentSessionId];

  /// 取(或建)某子会话的只读日志。
  SubagentTranscript transcriptFor(String childSessionId) =>
      _transcripts.putIfAbsent(
          childSessionId, () => SubagentTranscript(childSessionId));

  /// 拉取(或命中缓存)某 parent 的直接 child 目录。缓存到下次失效
  /// (代际翻转 / 父会话状态翻转 / invalidateChildren / force)。
  Future<SubagentListValue> listChildren(String parentSessionId,
      {bool force = false}) async {
    if (!force && _catalogs.containsKey(parentSessionId)) {
      return _catalogs[parentSessionId]!;
    }
    final value = await api.call(
      RpcMethods.subagentList,
      <String, dynamic>{'parentSessionId': parentSessionId},
      parse: SubagentListValue.fromJson,
    );
    _catalogs[parentSessionId] = value;
    _emitCatalogs();
    return value;
  }

  /// 显式失效某 parent 的目录缓存(prompt/interrupt 后 activity 可能翻转)。
  void invalidateChildren(String parentSessionId) {
    if (_catalogs.remove(parentSessionId) != null) {
      _emitCatalogs();
    }
  }

  /// 装载子会话 transcript(subagent.history 分页取完;重复调用幂等,靠 seq 去重)。
  /// [mode] 来自目录行('one-shot'|'continuable'),store 不假设。
  Future<List<SessionEvent>> readTranscript(
    String parentSessionId,
    String childSessionId, {
    required String mode,
    int? maxMessages,
  }) async {
    maxMessages ??= 50;
    final transcript = transcriptFor(childSessionId);
    var hasMore = true;
    int? beforeSeq;
    while (hasMore) {
      final payload = <String, dynamic>{
        'parentSessionId': parentSessionId,
        'childSessionId': childSessionId,
        'mode': mode,
      };
      if (beforeSeq != null) payload['beforeSeq'] = beforeSeq;
      payload['maxMessages'] = maxMessages;
      final value = await api.call(
        RpcMethods.subagentHistory,
        payload,
        parse: SubagentHistoryValue.fromJson,
      );
      for (final entry in value.events) {
        transcript.append(entry.event);
      }
      if (value.hasMore && value.events.isNotEmpty) {
        beforeSeq = value.events.first.event.seq;
      } else {
        hasMore = false;
      }
    }
    return transcript.events;
  }

  /// 续聊:mode 恒 'continuable';仅当目录行 parentAvailable==true 且 child 非
  /// one-shot/非运行中时 UI 才暴露入口(store 不复查,服务端仍权威)。
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
          .add(Map<String, SubagentListValue>.unmodifiable(_catalogs));
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
    // 父会话运行状态翻转 → 其目录缓存失效(下次 listChildren 重取新 parentAvailable)。
    if (frame is HostFrameHostSessionStatus &&
        _catalogs.containsKey(frame.sessionId)) {
      invalidateChildren(frame.sessionId);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _snapshotsSub?.cancel();
    await _muxSub?.cancel();
    await _hostSub?.cancel();
    for (final t in _transcripts.values) {
      await t.dispose();
    }
    await _catalogsController.close();
  }
}
