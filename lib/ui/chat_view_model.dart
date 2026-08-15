// ChatViewModel — M2 UI 的纯状态层(不 import任何 socket/HttpClient,
// widget 测试用 _FakeView 注入即可,绕开 flutter_test 的 HttpClient 假货)。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/sessions/event_text.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/session_store.dart';
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
  List<ChatBubble> get bubbles =>
      List.unmodifiable([..._bubbles, ..._ephemeral]);

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
    final log = _store.logFor(sessionId);
    _rebuildFromLog(log);
    _eventsSub = log.eventStream.listen((_) => _scheduleRebuild(log));
    notifyListeners();
    // 切换会话即拉历史尾页(单页 50 条,首屏快;更早走 loadOlder)。
    _store.loadHistory(sessionId).then((_) {
      if (_selectedId == sessionId) {
        _rebuildFromLog(log);
        _pruneEphemeral();
        notifyListeners();
      }
    }).catchError((Object e) {
      if (_selectedId == sessionId) {
        lastError = '历史加载失败: ' + e.toString();
        notifyListeners();
      }
    });
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

  /// 批量广播合并:同一事件循环排空内多次日志变更只做一次全量重算
  /// (extractNodes 是 O(n);逐帧重算会卡流式渲染,见 PROGRESS 性能回写)。
  bool _rebuildScheduled = false;
  void _scheduleRebuild(SessionLog log) {
    if (_rebuildScheduled) return;
    _rebuildScheduled = true;
    scheduleMicrotask(() {
      _rebuildScheduled = false;
      _rebuildFromLog(log);
      _pruneEphemeral();
      notifyListeners();
    });
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
    final realSeqs = _bubbles.map((b) => b.seq).toSet();
    // user 消息的 seq 是服务器分配的;乐观占位 seq=-1,真帧到达即撤。
    _ephemeral.removeWhere((b) => b.seq < 0 && _bubbles.isNotEmpty && _lastUserArrived(b.text));
  }

  bool _lastUserArrived(String text) =>
      _bubbles.any((b) => b.role == 'user' && b.text == text);

  /// 发送:先乐观占位,真帧由 mux 回流覆盖。
  Future<void> send(String text, Future<void> Function(String sessionId, String text) sender) async {
    final id = _selectedId;
    if (id == null || text.trim().isEmpty) return;
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
    super.dispose();
  }
}
