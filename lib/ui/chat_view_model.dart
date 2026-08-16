// ChatViewModel — M2 UI 的纯状态层(不 import任何 socket/HttpClient,
// widget 测试用 _FakeView 注入即可,绕开 flutter_test 的 HttpClient 假货)。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/sessions/event_text.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/ui/todo_panel.dart'
    show SessionTodoItem, backscanSessionTodos;
import 'package:singleman/wire/generated/wire_generated.dart';

/// 一条渲染气泡(纯文本先行;markdown 与工具卡是 M3/M4)。
@immutable
class ChatBubble {
  const ChatBubble({
    required this.seq,
    required this.role,
    required this.text,
    required this.ephemeral,
  });

  final int seq;
  final String role; // 'user' | 'assistant' | 'system-notice'
  final String text;
  final bool ephemeral; // 乐观本地占位(真帧到达后被同 seq 覆盖)

  @override
  bool operator ==(Object other) =>
      other is ChatBubble && other.seq == seq && other.role == role && other.text == text;
  @override
  int get hashCode => Object.hash(seq, role, text);
}

/// 从 session/event 提取文本(实现在 sessions/event_text.dart,纯 Dart 无 flutter 依赖)。


class ChatViewModel extends ChangeNotifier {
  ChatViewModel({required SessionStoreView store, required ConnectionController? connection})
      : _store = store,
        _connection = connection {
    _summariesSub = store.summaries.listen((list) {
      _sessions = List<SessionSummary>.of(list);
      _ensureSelection();
      notifyListeners();
    });
    final initial = store.currentSummaries;
    if (initial.isNotEmpty) {
      _sessions = List<SessionSummary>.of(initial);
      _ensureSelection();
    }
    _connection?.snapshots.listen((snap) {
      phase = snap.phase;
      generation = snap.generation;
      failureReason = snap.failureReason;
      if (snap.phase == ConnectionPhase.ready) {
        describe = snap.describe;
        // 新代际:上一代的 view 渲染意图整体作废。
        _viewsSelected.clear();
      }
      notifyListeners();
    });
    _viewsSub = _connection?.muxFrames.listen((frame) {
      if (frame is MuxFrameSessionEvent &&
          frame.view != null &&
          frame.event.type.contains('tool')) {
        // 懒注册:只收当前选中会话的渲染意图 —— 全会话收集会随
        // 会话数无界增长(长连接下没人消费的会话也在堆积)。
        final selected = _selectedId;
        if (selected == null || frame.sessionId != selected) return;
        _viewsSelected
            .putIfAbsent(frame.event.seq, () => frame.view!);
      }
    });
  }

  final SessionStoreView _store;
  final ConnectionController? _connection;
  StreamSubscription<List<SessionSummary>>? _summariesSub;
  StreamSubscription<List<SessionEvent>>? _eventsSub;

  /// 会话摘要的透传(W1 集成:WorkspaceBrowser 直接吃 store 流,
  /// 不经过 VM 的拷贝,避免双份状态)。
  Stream<List<SessionSummary>> get summaries => _store.summaries;

  List<SessionSummary> _sessions = <SessionSummary>[];
  String? _selectedId;
  final List<ChatBubble> _bubbles = <ChatBubble>[];

  // W1-E 集成:节点流(markdown/工具卡/think/todo/压缩/重试/错误)。
  // view = 主机算好的渲染意图,只在实时 mux 帧携带(MuxFrameSessionEvent.view)。
  // 生命周期:仅选中会话(懒注册)、切换即弃(view 不跨会话/不跨代保留)。
  List<ChatNode> _nodes = <ChatNode>[];
  List<SessionTodoItem> _todos = <SessionTodoItem>[];
  final Map<int, ToolEventView> _viewsSelected = <int, ToolEventView>{};
  StreamSubscription<MuxFrame>? _viewsSub;
  final List<ChatBubble> _ephemeral = <ChatBubble>[];
  ConnectionPhase phase = ConnectionPhase.connecting;
  int generation = 0;
  HostDescribeValue? describe;
  String? failureReason;
  String? lastError;

  List<SessionSummary> get sessions => List.unmodifiable(_sessions);
  String? get selectedId => _selectedId;

  /// 选中会话的日志(轨迹页等直接消费;未选中为 null)。
  SessionLog? get logForSelected =>
      _selectedId == null ? null : _store.logFor(_selectedId!);

  /// 选中会话 running(host/session-status 折叠;composer 插话/停止态用)。
  bool get selectedRunning {
    final s = _sessions.where((s) => s.sessionId == _selectedId).toList();
    return s.isNotEmpty && s.first.running;
  }

  /// 选中会话当前权限预设(访问模式;web permissions projection 对齐):
  /// 回溯会话日志最新 permission/preset 事件;无记录 = null(主机 default)。
  /// 切换经 /permission 斜杠命令,事件回流后此处自然收敛。
  String? get selectedPermissionPreset {
    final log = logForSelected;
    if (log == null) return null;
    for (final e in log.events.reversed) {
      if (e.type != 'permission/preset') continue;
      final d = e.data;
      if (d is Map) {
        for (final key in ['preset', 'value', 'name']) {
          final v = d[key];
          if (v is String && v.isNotEmpty) return v;
        }
      }
    }
    return null;
  }

  /// 选中会话的 Agent 预设 id(工作模式;null = 主机默认)。
  String? get selectedAgentPreset {
    final id = _selectedId;
    if (id == null) return null;
    for (final s in _sessions) {
      if (s.sessionId == id) return s.agentPreset;
    }
    return null;
  }
  List<ChatBubble> get bubbles =>
      List.unmodifiable([..._bubbles, ..._ephemeral]);

  /// 当前会话的任务清单(todo/write 投影;空 = 无清单或已随新一轮退役)。
  List<SessionTodoItem> get todos => List.unmodifiable(_todos);

  /// 当前会话的节点流(空日志为空列表;UI 优先用它,bubbles 保留为兜底)。
  /// 乐观占位(刚发送、真帧未回流)以负数 seq 的 ChatNodeUser 追加在尾:
  /// 节点流渲染路径与 bubbles 路径的即发即见体验对齐。
  List<ChatNode> get nodes => _ephemeral.isEmpty
      ? List.unmodifiable(_nodes)
      : List.unmodifiable([
          ..._nodes,
          for (var i = 0; i < _ephemeral.length; i++)
            ChatNodeUser(
              seq: -1 - i,
              type: 'user/message/ephemeral',
              text: _ephemeral[i].text,
            ),
        ]);

  // M3 交互帧(interactor 可为 null:纯聊天场景/测试)。
  InteractorStore? interactor;

  /// 选中会话的历史尾页装载中(切换会话到装载完成之间为 true)。
  /// 非空会话在装载完成前应显示加载态,而非空白会话的空态 UI。
  bool historyLoading = false;

  /// 选中会话是否 blank(尚无任何 turn;摘要缺席时按非空处理,
  /// 让装载期显示加载态而非误导性的「新会话」空态)。
  bool get selectedBlank {
    final id = _selectedId;
    if (id == null) return true;
    for (final s in _sessions) {
      if (s.sessionId == id) return s.blank;
    }
    return false;
  }
  bool get canSend =>
      phase == ConnectionPhase.ready &&
      _selectedId != null &&
      (describe == null || describe!.attachedSessions >= 0);

  void select(String sessionId) {
    if (_selectedId == sessionId) return;
    _selectedId = sessionId;
    _bubbles.clear();
    _ephemeral.clear();
    _viewsSelected.clear();
    _eventsSub?.cancel();
    _rebuildTimer?.cancel();
    _rebuildTimer = null;
    final log = _store.logFor(sessionId);
    _lastEventCount = log.events.length; // 换会话:增量基准重置
    _rebuildFromLog(log);
    _eventsSub = log.eventStream.listen((events) => _onLogEvents(log, events));
    lastError = null;
    // 历史装载中:非空会话的首帧不该闪「准备好开始了吗」空白态。
    historyLoading = true;
    notifyListeners();
    // 切换会话即拉历史尾页(单页 50 条,首屏快;更早走 loadOlder)。
    unawaited(_loadSelectedHistory(sessionId));
  }

  /// 装载选中会话历史尾页;成功清错,失败(重试耗尽后)落 lastError。
  /// Store 层已做超时/载波自动重试;这里负责错误呈现与手动重试入口。
  Future<void> _loadSelectedHistory(String sessionId) async {
    try {
      await _store.loadHistory(sessionId);
      if (_selectedId != sessionId) return;
      lastError = null;
      historyLoading = false;
      _rebuildFromLog(_store.logFor(sessionId));
      _pruneEphemeral();
      notifyListeners();
    } on Object catch (e) {
      if (_selectedId != sessionId) return;
      lastError = '历史消息加载失败: ' + e.toString();
      historyLoading = false;
      notifyListeners();
    }
  }

  /// 手动重试历史装载(错误横幅的「重试」按钮):清错后重新拉取。
  Future<void> retryHistory() {
    final id = _selectedId;
    if (id == null) return Future.value();
    lastError = null;
    notifyListeners();
    return _loadSelectedHistory(id);
  }

  /// 选中会话是否还有更早历史(轨迹页 hasOlder)。
  bool get hasOlderSelected {
    final id = _selectedId;
    return id == null ? false : _store.logFor(id).hasOlder;
  }

  /// 向前补一页更早历史(轨迹页「加载更早」;装载后经日志流自动重算节点)。
  Future<void> loadOlderSelected() async {
    final id = _selectedId;
    if (id == null) return;
    await _store.loadOlder(id);
  }

  /// 消息操作区「分叉」:fork 当前选中会话(atSeq 锚定该消息)→
  /// 直接切换到子会话(对齐 web sessions.fork → open(childId))。
  Future<String?> forkSelectedAt(int seq) async {
    final id = _selectedId;
    if (id == null) return null;
    try {
      final childId = await _store.fork(id, atSeq: seq);
      select(childId);
      return childId;
    } on Object catch (e) {
      lastError = '分叉失败: ' + e.toString();
      notifyListeners();
      return null;
    }
  }

  /// 流式重建节流(两层 + 分档):
  /// ① microtask 合并 —— 同一事件循环排空内多次日志变更只重算一次
  ///   (extractNodes 是 O(n);逐帧重算会卡流式渲染,见 PROGRESS 性能回写)。
  /// ② 时间窗节流 —— 流式 delta 是逐帧到达的**独立事件循环轮次**,
  ///   microtask 合并不了跨轮变更:每个 delta 仍会各自触发一次
  ///   O(n) 重算 + 整屏 rebuild,think/文本高频流(几十~上百 delta/s)
  ///   会饱和 UI 线程、饿死输入事件(microtask 本身不产生让出点)。
  /// ③ 分档 —— 事件**类型**决定时效要求:
  ///   - 纯 assistant/chunk 追加(只是尾部长文本变长):慢档
  ///     [_kStreamInterval](250ms 一次;打字/尾随滚动的跳进感可接受,
  ///     换来滚动稳定流畅 —— 全量重算 + 流式文本重布局不再是每秒 15 次);
  ///   - 其他任何新事件(新节点/工具卡/轮次定界/历史页):立即落地,
  ///     结构变化一帧不等待。
  /// 慢档内:空闲后首个 delta 立即(leading,体感即时),窗口内后续
  /// 变更推迟到尾沿 Timer 统一落地(trailing,流结束的最终帧必达)。
  static const Duration _kStreamInterval = Duration(milliseconds: 250);

  bool _rebuildQueued = false;
  bool _rebuildSlow = false;
  Timer? _rebuildTimer;
  DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastEventCount = 0;

  void _onLogEvents(SessionLog log, List<SessionEvent> events) {
    // 新增事件 = 尾部切片(中间插入时切片会混入旧事件 → 判非纯追加,
    // 走立即档,保守正确)。纯 chunk 追加才允许慢档。
    final fresh = events.length > _lastEventCount
        ? events.sublist(_lastEventCount)
        : const <SessionEvent>[];
    _lastEventCount = events.length;
    final slow = fresh.isNotEmpty &&
        fresh.every((e) => e.type == 'assistant/chunk');
    _scheduleRebuild(log, slow: slow);
  }

  void _scheduleRebuild(SessionLog log, {required bool slow}) {
    if (_rebuildQueued) {
      // 已排队的合并批次若含快档请求,保持快档(不能被后到的慢档降级)。
      if (!slow) _rebuildSlow = false;
      return;
    }
    _rebuildQueued = true;
    _rebuildSlow = slow;
    scheduleMicrotask(() {
      _rebuildQueued = false;
      final sinceLast = DateTime.now().difference(_lastFlush);
      final interval = _kStreamInterval;
      if (!_rebuildSlow || sinceLast >= interval) {
        _flushRebuild(log);
      } else {
        // 慢档窗口内:推迟到尾沿;delta 持续涌入时每窗口至多一次重算。
        _rebuildTimer ??= Timer(interval - sinceLast, () {
          _rebuildTimer = null;
          // 切换会话后旧日志的尾沿定时器可能仍挂着:只重建仍选中的会话。
          if (_selectedId == log.sessionId) _flushRebuild(log);
        });
      }
    });
  }

  void _flushRebuild(SessionLog log) {
    _lastFlush = DateTime.now();
    _rebuildFromLog(log);
    _pruneEphemeral();
    notifyListeners();
  }

  void _ensureSelection() {
    if (_selectedId == null && _sessions.isNotEmpty) {
      select(_sessions.first.sessionId);
    }
  }

  void _rebuildFromLog(SessionLog log) {
    _bubbles.clear();
    for (final event in log.events) {
      final bubble = _bubbleFor(event);
      if (bubble != null) _bubbles.add(bubble);
    }
    // 节点流:结构化渲染(工具卡/think/todo/...);view 只对实时帧可用。
    // 选中会话才有收集的 view(懒注册);历史页(无实时帧)自然无 view。
    final views = _selectedId == log.sessionId ? _viewsSelected : null;
    _nodes = extractNodes([
      for (final e in log.events)
        EventNodeInput(e, views?[e.seq]),
    ]);
    // 任务清单投影(web backscanTodos):最后一条 todo/write 未被更新的
    // turn/start 退役时即当前清单;随日志重建一起重算。
    _todos = backscanSessionTodos(log.events);
  }

  ChatBubble? _bubbleFor(SessionEvent event) {
    if (event.type == 'user/message') {
      final text = extractText(event.data);
      if (text.isEmpty) return null;
      final source = event.data is Map && (event.data as Map)['source'] is Map
          ? ((event.data as Map)['source'] as Map)['kind']
          : null;
      // 直发人类消息才冒泡;agent.inject 的合成上下文不进聊天流。
      if (source != null && source != 'user') return null;
      return ChatBubble(seq: event.seq, role: 'user', text: text, ephemeral: false);
    }
    if (event.type == 'assistant/message') {
      final text = extractText(event.data);
      if (text.isEmpty) return null;
      return ChatBubble(seq: event.seq, role: 'assistant', text: text, ephemeral: false);
    }
    return null;
  }

  void _pruneEphemeral() {
    if (_ephemeral.isEmpty) return;
    // user 消息的 seq 是服务器分配的;乐观占位 seq=-1,真帧到达即撤。
    _ephemeral.removeWhere((b) => b.seq < 0 && _bubbles.isNotEmpty && _lastUserArrived(b.text));
  }

  bool _lastUserArrived(String text) =>
      _bubbles.any((b) => b.role == 'user' && b.text == text);

  /// 发送:先乐观占位,真帧由 mux 回流覆盖。
  Future<void> send(String text, Future<void> Function(String sessionId, String text) sender) async {
    final id = _selectedId;
    if (id == null || text.trim().isEmpty) return;
    lastError = null; // 新动作清旧错(旧错误横幅不再赖着不走)。
    _ephemeral.add(ChatBubble(seq: -1, role: 'user', text: text.trim(), ephemeral: true));
    notifyListeners();
    try {
      await sender(id, text.trim());
    } catch (e) {
      _ephemeral.removeWhere((b) => b.text == text.trim());
      lastError = e.toString();
      notifyListeners();
      return;
    }
  }

  @override
  void dispose() {
    _summariesSub?.cancel();
    _eventsSub?.cancel();
    _viewsSub?.cancel();
    _rebuildTimer?.cancel();
    _rebuildTimer = null;
    super.dispose();
  }
}
