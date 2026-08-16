// M3 交互帧测试(假主机):审批应答信封、问答应答强校验、队列快照收敛、
// resolved 清场、not-pending 迟到折叠。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

import '../helpers/fake_dsh_host.dart';

void main() {
  late FakeDshHost host;
  late ConnectionController controller;
  late ApiClient api;
  late InteractorStore store;

  setUp(() async {
    host = await FakeDshHost.start();
    controller = ConnectionController(
      baseUri: host.baseUri,
      initialBackoff: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 150),
      probeTimeout: const Duration(milliseconds: 400),
    );
    api = ApiClient(baseUri: host.baseUri);
    store = InteractorStore(api: api, connection: controller);
    controller.start();
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 3));
  });

  tearDown(() async {
    await store.dispose();
    await controller.dispose();
    api.dispose();
    await host.stop();
  });

  test('approval: frame folds in, respond echoes frame rpcId, resolved clears', () async {
    final pending = store.approvals.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 3));
    host.pushApprovalFrame(
      rpcId: 'appr-1',
      sessionId: 'session-s1',
      approvalId: 'approval-1',
      reason: 'rm -rf test',
    );
    final list = await pending;
    expect(list, hasLength(1));
    expect(list.first.toolName, 'bash');
    expect(list.first.rpcId, 'appr-1');

    final cleared = store.approvals.firstWhere((l) => l.isEmpty).timeout(const Duration(seconds: 3));
    final receipt = await store.respondApproval('appr-1', 'session-s1', 'approval-1', allow: true);
    expect(receipt.accepted, isTrue);
    // 信封纪律:client-response + rpcId 回显帧的。
    final env = host.respondCalls.single;
    expect(env['type'], 'client-response');
    expect(env['rpcId'], 'appr-1');
    final value = (env['result'] as Map)['value'] as Map;
    expect(value['outcome'], 'allowed-once');
    expect(value['approvalId'], 'approval-1');
    await cleared; // resolved 帧清场
    expect(store.currentApprovals, isEmpty);
  });

  test('approval: rejected outcome carries through', () async {
    final pending = store.approvals.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 3));
    host.pushApprovalFrame(rpcId: 'appr-2', sessionId: 'session-s1', approvalId: 'approval-2');
    await pending;
    final receipt = await store.respondApproval('appr-2', 'session-s1', 'approval-2', allow: false);
    expect(receipt.accepted, isTrue);
    final value = (host.respondCalls.single['result'] as Map)['value'] as Map;
    expect(value['outcome'], 'rejected');
  });

  test('late respond folds into not-pending receipt', () async {
    host.rejectNextRespond = true;
    host.nextRespondRejectReason = 'not-pending';
    final receipt = await store.respondApproval('appr-unknown', 'session-s1', 'approval-x', allow: true);
    expect(receipt.accepted, isFalse);
    expect(receipt.late, isTrue);
  });

  test('question: strict validation catches malformed drafts before wire', () async {
    final questions = <AskUserQuestionItem>[
      AskUserQuestionItem(
        id: 'q1',
        question: '选择部署形态',
        options: [
          {'label': '桌面(推荐)', 'description': 'loopback 零配置'},
          {'label': '手机 LAN', 'description': '需 trusted-host'},
        ],
        multiSelect: false,
      ),
      AskUserQuestionItem(
        id: 'q2',
        question: '附加能力',
        options: [
          {'label': 'A'},
          {'label': 'B'},
        ],
        multiSelect: true,
      ),
    ];
    final pq = PendingQuestion(rpcId: 'q-batch-1', sessionId: 'session-s1', questions: questions);

    // 漏答 → 拒
    expect(store.validateQuestionAnswers(pq, [QuestionAnswerDraft(questionId: 'q1', selected: ['桌面(推荐)'])]),
        contains('missing'));
    // 未知 label → 拒
    expect(
        store.validateQuestionAnswers(pq, [
          QuestionAnswerDraft(questionId: 'q1', selected: ['桌面']),
          QuestionAnswerDraft(questionId: 'q2', selected: ['A']),
        ]),
        contains('unknown label'));
    // 单选多 label → 拒
    expect(
        store.validateQuestionAnswers(pq, [
          QuestionAnswerDraft(questionId: 'q1', selected: ['桌面(推荐)', '手机 LAN']),
          QuestionAnswerDraft(questionId: 'q2', selected: ['A']),
        ]),
        contains('single-select'));
    // 重复 id → 拒
    expect(
        store.validateQuestionAnswers(pq, [
          QuestionAnswerDraft(questionId: 'q1', selected: ['桌面(推荐)']),
          QuestionAnswerDraft(questionId: 'q1', selected: ['手机 LAN']),
          QuestionAnswerDraft(questionId: 'q2', selected: ['A']),
        ]),
        contains('duplicate'));
    // 完整合法 → null
    expect(
        store.validateQuestionAnswers(pq, [
          QuestionAnswerDraft(questionId: 'q1', selected: ['桌面(推荐)']),
          QuestionAnswerDraft(questionId: 'q2', selected: ['A', 'B']),
        ]),
        isNull);
  });

  test('question: full round trip with answered envelope + resolved clear', () async {
    final pending = store.questions.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 3));
    host.pushQuestionFrame(
      rpcId: 'q-batch-2',
      sessionId: 'session-s1',
      questions: [
        {
          'id': 'q1',
          'question': '继续吗?',
          'options': [
            {'label': '继续'},
            {'label': '停止'},
          ],
          'multiSelect': false,
        }
      ],
    );
    await pending;
    final cleared = store.questions.firstWhere((l) => l.isEmpty).timeout(const Duration(seconds: 3));
    final err = store.validateQuestionAnswers(
      store.currentQuestions.single,
      [QuestionAnswerDraft(questionId: 'q1', selected: ['继续'])],
    );
    expect(err, isNull);
    final receipt = await store.respondQuestions('q-batch-2', 'session-s1', [
      {'id': 'q1', 'selected': ['继续']},
    ]);
    expect(receipt.accepted, isTrue);
    final env = host.respondCalls.single;
    expect(env['rpcId'], 'q-batch-2');
    final value = (env['result'] as Map)['value'] as Map;
    final answers = (value['answer'] as Map)['answers'] as List;
    expect(answers, [
      {'id': 'q1', 'selected': ['继续']},
    ]);
    await cleared;
    expect(store.currentQuestions, isEmpty);
  });

  test('updateQueue remove: server splices and pushes snapshot; unknown id -> queue-item-not-found', () async {
    host.seedQueue('session-s1', [
      {
        'id': 'm9',
        'placement': 'queued',
        'message': {
          'id': 'm9',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '待删消息'},
          ],
          'source': {'kind': 'user'},
        },
      },
    ]);
    final seen = <Map<String, List<Map<String, dynamic>>>>[];
    final sub = store.queues.listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await store.removeQueueItem('session-s1', 'm9');
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while ((seen.length < 2 || (seen.last['session-s1'] ?? const []).isNotEmpty) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await sub.cancel();
    expect(seen.last['session-s1'] ?? const [], isEmpty);

    // 未知 itemId:业务错误 queue-item-not-found 折叠为 RpcBusinessError。
    await expectLater(
      store.removeQueueItem('session-s1', 'nope'),
      throwsA(isA<RpcBusinessError>()),
    );
  });

  test('queue snapshot replaces wholesale (收敛语义)', () async {
    // 广播流无重放:先订阅快照流再推帧,收集所有状态。
    final states = <Map<String, List<Map<String, dynamic>>>>[];
    final sub = store.queues.listen(states.add);
    host.pushQueueFrame(sessionId: 'session-s1', items: [
      {
        'id': 'm1',
        'placement': 'queued',
        'message': {
          'id': 'm1',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '第一条'},
          ],
          'source': {'kind': 'user'},
        },
      },
    ]);
    host.pushQueueFrame(sessionId: 'session-s1', items: []);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (states.length < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await sub.cancel();
    expect(states, hasLength(2));
    expect(states.first['session-s1'], hasLength(1));
    // 第二帧整帧替换为空(收敛语义:不是追加)。
    expect(states.last['session-s1'] ?? const [], isEmpty);
  });

  // ---- 断线窗口对账(用户实报:web 侧回答后,手机侧交互卡不消失)----
  //
  // host 语义(api-proxy.ts):resolved 帧 broadcast 一次、绝不重放;
  // mux open 只重放 still-pending 的 requested 帧(同 rpcId)。断线期间
  // 错过的 resolved 没有补偿,客户端必须在新代际清场 + 靠基线重放重建
  // (web 官方 Session.resync 的 pending.clear 同款)。

  test('reconnect window: resolved missed during disconnect does not linger', () async {
    host.pushApprovalFrame(rpcId: 'appr-disc', sessionId: 'session-s1', approvalId: 'approval-disc');
    await store.approvals.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 3));
    expect(store.currentApprovals, hasLength(1));

    // 订阅先于拔线:清场事件(connecting)必定可见。
    final cleared = store.approvals.firstWhere((l) => l.isEmpty).timeout(const Duration(seconds: 3));
    host.unplugMux();
    // 断线窗口内 web 侧回答:host settled(重放集移除),resolved 帧
    // broadcast 时 muxSockets 为空 —— 手机收不到,重连后也不会重放。
    host.resolveApprovalExternally(rpcId: 'appr-disc', sessionId: 'session-s1', approvalId: 'approval-disc');

    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready && s.generation >= 2)
        .timeout(const Duration(seconds: 5));
    await cleared; // 旧代码此处永远等不到:卡片残留,永不消失
    expect(store.currentApprovals, isEmpty);
  });

  test('reconnect replay: still-pending requested frame re-arrives with same rpcId', () async {
    host.pushApprovalFrame(rpcId: 'appr-rep', sessionId: 'session-s1', approvalId: 'approval-rep');
    await store.approvals.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 3));

    final seenAgain = store.approvals.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 5));
    host.unplugMux();
    // 未被任何端回答:mux open 时 fake host 原样重放(同 rpcId)。
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready && s.generation >= 2)
        .timeout(const Duration(seconds: 5));
    final list = await seenAgain;
    expect(list, hasLength(1));
    expect(list.first.rpcId, 'appr-rep');
    expect(list.first.approvalId, 'approval-rep');
  });

  test('late receipt (not-pending) clears the stale approval card locally', () async {
    host.pushApprovalFrame(rpcId: 'appr-late', sessionId: 'session-s1', approvalId: 'approval-late');
    await store.approvals.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 3));
    // rejectNextRespond:回执 not-pending 且不发 resolved 帧 ——
    // 分离「回执清场」与「resolved 帧清场」两条路径。
    host.rejectNextRespond = true;
    final receipt = await store.respondApproval('appr-late', 'session-s1', 'approval-late', allow: true);
    expect(receipt.late, isTrue);
    expect(store.currentApprovals, isEmpty);
  });

  test('late receipt clears the stale question form locally', () async {
    host.pushQuestionFrame(rpcId: 'q-late', sessionId: 'session-s1', questions: [
      {
        'id': 'q1',
        'question': '继续吗?',
        'options': [
          {'label': '继续'},
          {'label': '停止'},
        ],
        'multiSelect': false,
      }
    ]);
    await store.questions.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 3));
    host.rejectNextRespond = true;
    final receipt = await store.respondQuestions('q-late', 'session-s1', [
      {'id': 'q1', 'selected': ['继续']},
    ]);
    expect(receipt.late, isTrue);
    expect(store.currentQuestions, isEmpty);
  });
}
