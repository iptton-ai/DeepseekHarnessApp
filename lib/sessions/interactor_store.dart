// InteractorStore — M3 交互帧域层:审批、问答、队列快照的收敛。
//
// 契约(DSH-PROTOCOL §1/§4/§5 + approvals/questions.schema.js):
// - approval/question 帧是可应答 ServerRequest:rpcId 回显进 /api/respond 的
//   client-response 信封;payload 放 result.value 槽
// - approval 应答值:{sessionId, approvalId, outcome: allowed-once|rejected}
// - question 应答值:{sessionId, answer:{answers:[{id, selected, custom?}]}}
//   服务端极严校验:label 精确匹配、批次完整、单选互斥、空 custom 拒
// - respond 回执:{accepted} 或 {accepted:false, reason:not-pending|bad-response}
//   —— 第一个应答赢;迟到者 not-pending,畸形者 bad-response
// - approval/resolved、question/resolved 帧负责清场;重连重放未决帧(同 rpcId)
//   —— 但 resolved 只 broadcast 一次、绝不重放:断线窗口错过的 resolved
//   帧没有补偿,靠「新代际清场 + 基线重放重建」对账(web Session.resync
//   的 pending.clear 同款),not-pending 回执是第二道清场信号
// - session/queue 是完整快照(整帧收敛,直接替换)
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 应答回执折叠。
class RespondReceipt {
  const RespondReceipt({required this.accepted, this.reason});
  final bool accepted;
  final String? reason; // not-pending | bad-response
  bool get late => !accepted && reason == 'not-pending';
  bool get malformed => !accepted && reason == 'bad-response';
}

class PendingApproval {
  const PendingApproval({
    required this.rpcId,
    required this.sessionId,
    required this.approvalId,
    required this.toolName,
    this.callId,
    this.reason,
  });
  final String rpcId;
  final String sessionId;
  final String approvalId;
  final String toolName;
  final String? callId;
  final String? reason;
}

class PendingQuestion {
  const PendingQuestion({required this.rpcId, required this.sessionId, required this.questions});
  final String rpcId;
  final String sessionId;
  final List<AskUserQuestionItem> questions;

  /// label 精确匹配表:questionId -> 合法 label 集(应答前本地预校验,
  /// 服务端仍是权威;本地预拒只为省一次 bad-response 往返)。
  Set<String> allowedLabelsFor(String questionId) {
    for (final q in questions) {
      if (q.id == questionId) {
        return (q.options ?? const <Map<String, dynamic>>[])
            .map((o) => o['label'] as String)
            .toSet();
      }
    }
    return const <String>{};
  }
}

class InteractorStore {
  InteractorStore({required this.api, required ConnectionController? connection}) {
    _approvalsController = StreamController<List<PendingApproval>>.broadcast();
    _questionsController = StreamController<List<PendingQuestion>>.broadcast();
    _queueController = StreamController<Map<String, List<Map<String, dynamic>>>>.broadcast();
    if (connection != null) {
      _muxSub = connection.addressedMuxFrames.listen(_onAddressedFrame);
      _genSub = connection.snapshots.listen(_onGeneration);
    }
  }

  final ApiClient api;
  late final StreamController<List<PendingApproval>> _approvalsController;
  late final StreamController<List<PendingQuestion>> _questionsController;
  late final StreamController<Map<String, List<Map<String, dynamic>>>> _queueController;
  StreamSubscription<AddressedMuxFrame>? _muxSub;
  StreamSubscription<ConnectionSnapshot>? _genSub;

  final Map<String, PendingApproval> _approvals = {};
  final Map<String, PendingQuestion> _questions = {};
  final Map<String, List<Map<String, dynamic>>> _queues = {};

  Stream<List<PendingApproval>> get approvals => _approvalsController.stream;
  Stream<List<PendingQuestion>> get questions => _questionsController.stream;
  Stream<Map<String, List<Map<String, dynamic>>>> get queues => _queueController.stream;

  List<PendingApproval> get currentApprovals => List.unmodifiable(_approvals.values);
  List<PendingQuestion> get currentQuestions => List.unmodifiable(_questions.values);
  Map<String, List<Map<String, dynamic>>> get currentQueues => Map.unmodifiable(_queues);

  /// 审批应答:rpcId 回显帧的;value 槽装 {sessionId, approvalId, outcome}。
  /// not-pending 回执 = host 侧已 resolved(另一端先答/turn 取消)——
  /// resolved 帧只 broadcast 一次,若已错过(断线窗口),这是最后的权威
  /// 清场信号,本地立即移除,卡片不再滞留。
  Future<RespondReceipt> respondApproval(String rpcId, String sessionId, String approvalId, {required bool allow}) async {
    final receipt = await _respond(rpcId, <String, dynamic>{
      'sessionId': sessionId,
      'approvalId': approvalId,
      'outcome': allow ? 'allowed-once' : 'rejected',
    });
    if (receipt.late && _approvals.containsKey(rpcId)) {
      _approvals.remove(rpcId);
      _approvalsController.add(currentApprovals);
    }
    return receipt;
  }

  /// 队列项删除(按 MessageId 寻址;被 claim 的 splice 赢竞态,后来者
  /// queue-item-not-found —— 服务端语义,本地不重试)。
  Future<void> removeQueueItem(String sessionId, String itemId) => api.call(
        RpcMethods.sessionUpdateQueue,
        <String, dynamic>{
          'sessionId': sessionId,
          'itemId': itemId,
          'action': <String, dynamic>{'kind': 'remove'},
        },
        parse: SessionUpdateQueueValue.fromJson,
      );

  /// 队列项插话提升(session.updateQueue kind:'steer';web queue.steer
  /// 同款)。steer-unavailable / queue-item-not-found 是合法竞态结果
  /// (轮次刚结束/项刚被 claim),调用方应静默收敛,不当错误处理。
  Future<void> steerQueueItem(String sessionId, String itemId) => api.call(
        RpcMethods.sessionUpdateQueue,
        <String, dynamic>{
          'sessionId': sessionId,
          'itemId': itemId,
          'action': <String, dynamic>{'kind': 'steer'},
        },
        parse: SessionUpdateQueueValue.fromJson,
      );

  /// 取消当前 turn(保留 pending inbox;FIFO 认领由主机驱动,客户端永不提升)。
  Future<void> cancelSession(String sessionId) => api.call(
        RpcMethods.sessionCancel,
        <String, dynamic>{'sessionId': sessionId},
        parse: SessionCancelValue.fromJson,
      );

  /// 问答应答:批次必须完整(每个 questionId 一条),label 精确匹配,
  /// multiSelect 才可多选 + custom;custom 空串拒。
  /// not-pending 同 respondApproval:权威已 resolved,本地清场。
  Future<RespondReceipt> respondQuestions(String rpcId, String sessionId, List<Map<String, dynamic>> answers) async {
    final receipt = await _respond(rpcId, <String, dynamic>{
      'sessionId': sessionId,
      'answer': <String, dynamic>{
        'answers': answers,
      },
    });
    if (receipt.late && _questions.containsKey(rpcId)) {
      _questions.remove(rpcId);
      _questionsController.add(currentQuestions);
    }
    return receipt;
  }

  Future<RespondReceipt> _respond(String rpcId, Map<String, dynamic> value) async {
    // /api/respond 的响应体不是 server-response,而是回执 JSON。
    final raw = await api.postRespond(<String, dynamic>{
      'type': 'client-response',
      'rpcId': rpcId,
      'result': <String, dynamic>{'ok': true, 'value': value},
    });
    return RespondReceipt(
      accepted: raw['accepted'] == true,
      reason: raw['reason'] as String?,
    );
  }

  /// 本地预校验(纪律:先 fixture 测试再 UI;服务端是权威)。
  /// 返回 null = 可发;否则返回拒绝原因(不发请求)。
  String? validateQuestionAnswers(PendingQuestion q, List<QuestionAnswerDraft> drafts) {
    final byId = <String, QuestionAnswerDraft>{};
    for (final d in drafts) {
      if (byId.containsKey(d.questionId)) return 'duplicate answer for ' + d.questionId;
      byId[d.questionId] = d;
    }
    for (final question in q.questions) {
      final d = byId[question.id];
      if (d == null) return 'missing answer for ' + question.id;
      final allowed = q.allowedLabelsFor(question.id);
      if (d.selected.any((s) => !allowed.contains(s))) {
        return 'unknown label for ' + question.id;
      }
      final multi = question.multiSelect == true;
      if (!multi && d.selected.length > 1) return 'single-select question got multiple labels: ' + question.id;
      if (d.selected.isEmpty && (d.custom == null || d.custom!.isEmpty)) {
        return 'empty answer for ' + question.id;
      }
      if (d.custom != null && d.selected.isNotEmpty && !multi) {
        return 'custom with selection on single-select: ' + question.id;
      }
    }
    if (byId.length > q.questions.length) return 'unknown question id in answers';
    return null;
  }

  /// 测试直喂(widget 测试在 fake-async zone 下真连接的 Timer 不走,
  /// 用这个绕开 ConnectionController 直接喂帧;生产路径是 mux 订阅)。
  @visibleForTesting
  void debugFeed(AddressedMuxFrame addressed) => _onAddressedFrame(addressed);

  void _onAddressedFrame(AddressedMuxFrame addressed) {
    final frame = addressed.frame;
    if (frame is MuxFrameApprovalRequested) {
      final pending = PendingApproval(
        rpcId: addressed.rpcId,
        sessionId: frame.sessionId,
        approvalId: frame.approvalId,
        toolName: frame.toolName,
        callId: frame.callId,
        reason: frame.reason,
      );
      _approvals[addressed.rpcId] = pending;
      _approvalsController.add(currentApprovals);
    } else if (frame is MuxFrameApprovalResolved) {
      // resolved 即清场(无论 outcome)。Map.removeWhere 回调是 (key, value)。
      _approvals.removeWhere((rpcId, a) => a.approvalId == frame.approvalId);
      _approvalsController.add(currentApprovals);
    } else if (frame is MuxFrameQuestionRequested) {
      _questions[addressed.rpcId] = PendingQuestion(
        rpcId: addressed.rpcId,
        sessionId: frame.sessionId,
        questions: frame.questions,
      );
      _questionsController.add(currentQuestions);
    } else if (frame is MuxFrameQuestionResolved) {
      _questions.removeWhere((rpcId, q) => q.rpcId == frame.questionRpcId);
      _questionsController.add(currentQuestions);
    } else if (frame is MuxFrameSessionQueue) {
      _queues[frame.sessionId] = frame.items;
      _queueController.add(currentQueues);
    }
  }

  /// 新代际开始(connecting):旧代际已死、新 mux 尚未打开,基线重放帧
  /// 必然还未流入 —— 此刻清场无竞态。resolved 帧 host 只 broadcast 一次、
  /// 绝不重放(mux-open 只重放 still-pending 的 requested 帧);断线窗口
  /// 错过的 resolved 没有任何补偿,不清场会让交互卡永久滞留。对齐 web
  /// 官方 Session.resync 的语义:「Superseded, not settled: the baseline
  /// replay re-sends still-pending requested frames verbatim (same rpcId)」。
  /// 队列同清:session/queue 是整帧收敛快照,host 在 mux open 后重推;
  /// 保留旧快照可能滞留幻影(web manager 的 re-baseline 同款取舍)。
  void _onGeneration(ConnectionSnapshot snap) {
    if (snap.phase != ConnectionPhase.connecting) return;
    if (_approvals.isEmpty && _questions.isEmpty && _queues.isEmpty) return;
    _approvals.clear();
    _questions.clear();
    _queues.clear();
    _approvalsController.add(currentApprovals);
    _questionsController.add(currentQuestions);
    _queueController.add(currentQueues);
  }

  Future<void> dispose() async {
    await _muxSub?.cancel();
    await _genSub?.cancel();
    await _approvalsController.close();
    await _questionsController.close();
    await _queueController.close();
  }
}

/// UI 收集的应答草稿(预校验用)。
class QuestionAnswerDraft {
  const QuestionAnswerDraft({required this.questionId, this.selected = const <String>[], this.custom});
  final String questionId;
  final List<String> selected;
  final String? custom;
}
