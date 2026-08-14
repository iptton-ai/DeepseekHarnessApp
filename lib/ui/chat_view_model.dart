// ChatViewModel — M2 UI 的纯状态层(不 import任何 socket/HttpClient,
// widget 测试用 _FakeView 注入即可,绕开 flutter_test 的 HttpClient 假货)。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:singleman/connection/connection_controller.dart';
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
      if (snap.phase == ConnectionPhase.ready) describe = snap.describe;
      notifyListeners();
    });
  }

  final SessionStoreView _store;
  final ConnectionController? _connection;
  StreamSubscription<List<SessionSummary>>? _summariesSub;
  StreamSubscription<List<SessionEvent>>? _eventsSub;

  List<SessionSummary> _sessions = <SessionSummary>[];
  String? _selectedId;
  final List<ChatBubble> _bubbles = <ChatBubble>[];
  final List<ChatBubble> _ephemeral = <ChatBubble>[];
  ConnectionPhase phase = ConnectionPhase.connecting;
  int generation = 0;
  HostDescribeValue? describe;
  String? lastError;

  List<SessionSummary> get sessions => List.unmodifiable(_sessions);
  String? get selectedId => _selectedId;
  List<ChatBubble> get bubbles =>
      List.unmodifiable([..._bubbles, ..._ephemeral]);

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
    _eventsSub?.cancel();
    final log = _store.logFor(sessionId);
    _rebuildFromLog(log);
    _eventsSub = log.eventStream.listen((_) {
      _rebuildFromLog(log);
      _pruneEphemeral();
      notifyListeners();
    });
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
    super.dispose();
  }
}
