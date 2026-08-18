// SessionAttentionStore — 会话列表「需要关注」域层(M5 状态完善)。
//
// 数据面(全部只读折叠,不持有会话日志):
// - running 翻转:来自 SessionStore.summaries;非当前会话 true→false =
//   一轮跑完但用户没看 → 未读绿点;false→true = 新一轮开跑 → 上一轮的
//   错误标记让位(新一轮自证)。
// - 错误:来自 mux session/event 帧的 turn/error、turn/end(reason.kind ==
//   'error');不注册日志 —— 全会话扫描 type/data 后即弃,不占内存。
// - 待审批/待问答:从 InteractorStore 的 current* 快照派生(不复制状态),
//   resolved 帧由 interactor 自己清场。
// - 当前会话:select 时 markVisited —— 清未读/错误(用户已经看到了);
//   待审批标记不清(resolved 才清,web warning 点同语义)。
//
// 优先级(needsInput > error > running > unread)对齐 web sessionStatuses
// 「pending interaction is primary and live activity outranks completion」。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 会话行状态(侧栏 18dp 前置槽的唯一事实源)。
enum SessionRowStatus {
  /// 无标记(闲置/已读):不占槽,标题左缘对齐保持。
  idle,

  /// 执行中:web StateDot ongoing —— 3×3 像素追逐动画(非 loading 环)。
  running,

  /// 未读:非当前会话刚跑完一轮(running→完成),切过去即清。
  unread,

  /// 出错:本轮 turn/error 或 turn/end(error);新一轮开跑或访问时清。
  error,

  /// 需要用户输入:待审批(approval)或待问答(question)。
  needsInput,
}

class SessionAttentionStore extends ChangeNotifier {
  SessionAttentionStore({
    required SessionStoreView sessions,
    InteractorStore? interactor,
    ConnectionController? connection,
  }) : _interactor = interactor,
       _running = <String, bool>{
         for (final s in sessions.currentSummaries) s.sessionId: s.running,
       } {
    _summariesSub = sessions.summaries.listen(_onSummaries);
    if (interactor != null) {
      _approvalsSub = interactor.approvals.listen(_onApprovals);
      _questionsSub = interactor.questions.listen(_onQuestions);
    }
    _muxSub = connection?.muxFrames.listen(_onMuxFrame);
  }

  InteractorStore? _interactor;
  StreamSubscription<List<SessionSummary>>? _summariesSub;
  StreamSubscription<List<PendingApproval>>? _approvalsSub;
  StreamSubscription<List<PendingQuestion>>? _questionsSub;
  StreamSubscription<MuxFrame>? _muxSub;

  final Map<String, bool> _running;
  final Set<String> _unread = <String>{};
  final Set<String> _errors = <String>{};
  String? _currentId;

  /// 已见过的交互 rpcId(重连基线重放同 rpcId 不再当「新到达」)。
  final Set<String> _seenRpcIds = <String>{};
  bool _sawApprovalsBaseline = false;
  bool _sawQuestionsBaseline = false;
  /// sync 广播:到达在折叠点同步派发(异步控制器多一跳调度,消费方
  /// 在同一事件轮次内的断言/渲染会错过事件 —— 实测 fake-async 下 ARRIVE
  /// 晚于 pump 窗口)。监听器只做 setState/showDialog,无重入 add,安全。
  final StreamController<String> _arrivals = StreamController<String>.broadcast(sync: true);

  /// 新的待审批/待问答到达了非当前会话(移动端振动+聚合弹窗的触发源;
  /// 基线快照与重连重放不触发)。
  Stream<String> get attentionArrivals => _arrivals.stream;

  /// 当前选中会话(测试/日志用)。
  String? get currentSessionId => _currentId;

  /// 未读会话集(测试断言用)。
  Set<String> get unreadSessions => Set.unmodifiable(_unread);

  /// 出错会话集(测试断言用)。
  Set<String> get errorSessions => Set.unmodifiable(_errors);

  /// 有待审批/待问答的会话(弹窗聚合列表;含当前会话,展示层再过滤)。
  List<String> pendingInputSessions() {
    final ids = <String>{};
    for (final a in _interactor?.currentApprovals ?? const <PendingApproval>[]) {
      ids.add(a.sessionId);
    }
    for (final q in _interactor?.currentQuestions ?? const <PendingQuestion>[]) {
      ids.add(q.sessionId);
    }
    return ids.toList();
  }

  /// 该会话是否待审批。
  bool hasPendingApproval(String sessionId) =>
      (_interactor?.currentApprovals ?? const <PendingApproval>[])
          .any((a) => a.sessionId == sessionId);

  /// 该会话是否待问答。
  bool hasPendingQuestion(String sessionId) =>
      (_interactor?.currentQuestions ?? const <PendingQuestion>[])
          .any((q) => q.sessionId == sessionId);

  /// 会话行状态(优先级见文件头)。
  SessionRowStatus statusOf(String sessionId) {
    if (hasPendingApproval(sessionId) || hasPendingQuestion(sessionId)) {
      return SessionRowStatus.needsInput;
    }
    if (_errors.contains(sessionId)) return SessionRowStatus.error;
    if (_running[sessionId] == true) return SessionRowStatus.running;
    if (_unread.contains(sessionId)) return SessionRowStatus.unread;
    return SessionRowStatus.idle;
  }

  /// 用户进入某会话:清该行未读/错误标记,并记住当前会话。
  void markVisited(String? sessionId) {
    final changed = _currentId != sessionId ||
        (sessionId != null && (_unread.contains(sessionId) || _errors.contains(sessionId)));
    _currentId = sessionId;
    if (sessionId != null) {
      _unread.remove(sessionId);
      _errors.remove(sessionId);
    }
    if (changed) notifyListeners();
  }

  void _onSummaries(List<SessionSummary> list) {
    var changed = false;
    final alive = <String>{};
    for (final s in list) {
      alive.add(s.sessionId);
      final prev = _running[s.sessionId];
      if (prev == null) {
        _running[s.sessionId] = s.running;
        continue;
      }
      if (prev == s.running) continue;
      _running[s.sessionId] = s.running;
      changed = true;
      if (s.running) {
        // 新一轮开跑:上一轮的错误标记让位(新一轮自证)。
        if (_errors.remove(s.sessionId)) changed = true;
      } else if (s.sessionId != _currentId) {
        // 非当前会话跑完一轮:未读绿点,切过去才清。
        if (_unread.add(s.sessionId)) changed = true;
      }
    }
    // 消失的会话:行没了,标记回收。
    if (_running.keys.any((id) => !alive.contains(id))) {
      _running.removeWhere((id, _) => !alive.contains(id));
      changed = true;
    }
    if (_unread.any((id) => !alive.contains(id))) {
      _unread.removeWhere((id) => !alive.contains(id));
      changed = true;
    }
    if (_errors.any((id) => !alive.contains(id))) {
      _errors.removeWhere((id) => !alive.contains(id));
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _onApprovals(List<PendingApproval> list) {
    _foldArrivals([for (final a in list) (a.rpcId, a.sessionId)]);
    if (!_sawApprovalsBaseline) {
      _sawApprovalsBaseline = true;
    }
    notifyListeners();
  }

  void _onQuestions(List<PendingQuestion> list) {
    _foldArrivals([for (final q in list) (q.rpcId, q.sessionId)]);
    if (!_sawQuestionsBaseline) {
      _sawQuestionsBaseline = true;
    }
    notifyListeners();
  }

  /// 首个快照是基线(冷启动/重放),不当新到达;此后未见过的 rpcId =
  /// 新交互,归属非当前会话才广播(当前会话的交互卡就地渲染,勿扰)。
  void _foldArrivals(List<(String, String)> rpcs) {
    final baseline = !_sawApprovalsBaseline && !_sawQuestionsBaseline;
    for (final (rpcId, sessionId) in rpcs) {
      final fresh = _seenRpcIds.add(rpcId);
      if (baseline || !fresh) continue;
      if (sessionId == _currentId) continue;
      if (!_arrivals.isClosed) _arrivals.add(sessionId);
    }
  }

  void _onMuxFrame(MuxFrame frame) {
    if (frame is! MuxFrameSessionEvent) return;
    final type = frame.event.type;
    var errored = type == 'turn/error' || type.startsWith('turn/error/');
    if (!errored && type == 'turn/end') {
      final data = frame.event.data;
      final reason = data is Map ? data['reason'] : null;
      errored = reason is Map && reason['kind'] == 'error';
    }
    if (!errored) return;
    if (_errors.add(frame.sessionId)) {
      notifyListeners();
    }
  }

  /// 测试直喂 mux 帧(生产路径 = connection.muxFrames 订阅)。
  @visibleForTesting
  void debugFeedMux(MuxFrame frame) => _onMuxFrame(frame);

  @override
  void dispose() {
    _summariesSub?.cancel();
    _approvalsSub?.cancel();
    _questionsSub?.cancel();
    _muxSub?.cancel();
    _arrivals.close();
    super.dispose();
  }
}
