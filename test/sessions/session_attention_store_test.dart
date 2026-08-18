// SessionAttentionStore 域测试(M5 会话列表状态):
// - running 翻转:非当前会话跑完 → 未读;切过去(markVisited)清;
// - 新一轮开跑:上一轮错误标记让位;
// - turn/error 与 turn/end(error)折叠为错误标记;
// - 待审批/待问答从 interactor 快照派生,优先级最高;
// - attentionArrivals:基线快照不触发,此后非当前会话的新 rpcId 才广播。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart'
    show AddressedMuxFrame;
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/session_attention_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class _StubApi extends ApiClient {
  _StubApi() : super(baseUri: Uri.parse('http://localhost:1'));
}

class _FakeSessionView implements SessionStoreView {
  final _ctrl = StreamController<List<SessionSummary>>.broadcast();
  List<SessionSummary> _current = const [];

  void emit(List<SessionSummary> list) {
    _current = list;
    _ctrl.add(list);
  }

  @override
  Stream<List<SessionSummary>> get summaries => _ctrl.stream;
  @override
  List<SessionSummary> get currentSummaries => _current;
  @override
  SessionLog logFor(String sessionId) => SessionLog(sessionId);
  @override
  Future<void> loadHistory(String sessionId) async {}
  @override
  Future<void> loadOlder(String sessionId) async {}
  @override
  Future<String> fork(String sessionId, {int? atSeq}) async => 'forked';
}

SessionSummary _summary(String id, {bool running = false}) => SessionSummary(
      sessionId: id,
      updatedAt: 1786760000000,
      running: running,
      blank: false,
    );

SessionEvent _event(String type, {Map<String, dynamic>? data, int seq = 1}) =>
    SessionEvent.fromJson({
      'seq': seq,
      'time': 1786760000000,
      'type': type,
      if (data != null) 'data': data,
    });

void main() {
  late _FakeSessionView sessions;
  late InteractorStore interactor;
  late SessionAttentionStore store;

  setUp(() {
    sessions = _FakeSessionView();
    interactor = InteractorStore(api: _StubApi(), connection: null);
    sessions.emit([_summary('a'), _summary('b')]);
    store = SessionAttentionStore(sessions: sessions, interactor: interactor);
    store.markVisited('a'); // 当前会话 = a
  });

  tearDown(() {
    store.dispose();
    interactor.dispose();
  });

  group('running 翻转 → 未读', () {
    test('非当前会话跑完一轮 → 未读;切过去清', () async {
      sessions.emit([_summary('a'), _summary('b', running: true)]);
      await Future<void>.delayed(Duration.zero);
      expect(store.statusOf('b'), SessionRowStatus.running);
      sessions.emit([_summary('a'), _summary('b', running: false)]);
      await Future<void>.delayed(Duration.zero);
      expect(store.statusOf('b'), SessionRowStatus.unread);
      // 进入 b → 未读清。
      store.markVisited('b');
      expect(store.statusOf('b'), SessionRowStatus.idle);
    });

    test('当前会话跑完一轮 → 不产生未读', () async {
      sessions.emit([_summary('a', running: true), _summary('b')]);
      await Future<void>.delayed(Duration.zero);
      sessions.emit([_summary('a', running: false), _summary('b')]);
      await Future<void>.delayed(Duration.zero);
      expect(store.statusOf('a'), SessionRowStatus.idle);
    });

    test('会话消失 → 标记回收', () async {
      sessions.emit([_summary('a'), _summary('b', running: true)]);
      await Future<void>.delayed(Duration.zero);
      sessions.emit([_summary('a'), _summary('b', running: false)]);
      await Future<void>.delayed(Duration.zero);
      expect(store.unreadSessions, contains('b'));
      sessions.emit([_summary('a')]);
      await Future<void>.delayed(Duration.zero);
      expect(store.unreadSessions, isEmpty);
      expect(store.statusOf('b'), SessionRowStatus.idle);
    });
  });

  group('错误折叠', () {
    test('turn/error 帧 → 错误标记;新一轮开跑让位', () async {
      store.debugFeedMux(MuxFrameSessionEvent(
        sessionId: 'b',
        event: _event('turn/error', data: {'message': 'boom'}),
      ));
      expect(store.statusOf('b'), SessionRowStatus.error);
      // 新一轮开跑:错误让位(running 优先于遗留错误)。
      sessions.emit([_summary('a'), _summary('b', running: true)]);
      await Future<void>.delayed(Duration.zero);
      expect(store.statusOf('b'), SessionRowStatus.running);
      // 跑完 → 未读(不是错误;新一轮自证后无新错误)。
      sessions.emit([_summary('a'), _summary('b', running: false)]);
      await Future<void>.delayed(Duration.zero);
      expect(store.statusOf('b'), SessionRowStatus.unread);
    });

    test('turn/end reason.kind == error → 错误;completed 不标', () {
      store.debugFeedMux(MuxFrameSessionEvent(
        sessionId: 'b',
        event: _event('turn/end', data: {
          'reason': {
            'kind': 'error',
            'error': {'message': 'llm failure'},
          }
        }),
      ));
      expect(store.statusOf('b'), SessionRowStatus.error);
      store.debugFeedMux(MuxFrameSessionEvent(
        sessionId: 'b',
        event: _event('turn/end', data: {
          'reason': {'kind': 'completed'}
        }, seq: 2),
      ));
      // completed 不清错误(只有访问/新一轮开跑清)—— 但也不新增。
      expect(store.statusOf('b'), SessionRowStatus.error);
      store.markVisited('b');
      expect(store.statusOf('b'), SessionRowStatus.idle);
    });
  });

  group('待审批/待问答派生', () {
    test('approval 帧 → needsInput;resolved → 回落', () {
      interactor.debugFeed(AddressedMuxFrame(
        rpcId: 'ar-1',
        frame: const MuxFrameApprovalRequested(
          sessionId: 'b',
          approvalId: 'ap-1',
          toolName: 'bash',
        ),
      ));
      expect(store.statusOf('b'), SessionRowStatus.needsInput);
      expect(store.hasPendingApproval('b'), isTrue);
      interactor.debugFeed(AddressedMuxFrame(
        rpcId: 'ar-1',
        frame: const MuxFrameApprovalResolved(
          sessionId: 'b',
          approvalId: 'ap-1',
          outcome: 'allowed-once',
        ),
      ));
      expect(store.statusOf('b'), SessionRowStatus.idle);
    });

    test('question 帧 → needsInput;优先级高于错误/未读', () {
      store.debugFeedMux(MuxFrameSessionEvent(
        sessionId: 'b',
        event: _event('turn/error', data: {'message': 'boom'}),
      ));
      interactor.debugFeed(AddressedMuxFrame(
        rpcId: 'qr-1',
        frame: MuxFrameQuestionRequested(
          sessionId: 'b',
          questions: [
            AskUserQuestionItem.fromJson(const {
              'id': 'q1',
              'question': '继续吗?',
              'options': [
                {'label': '继续'},
              ],
            }),
          ],
        ),
      ));
      expect(store.statusOf('b'), SessionRowStatus.needsInput);
      expect(store.hasPendingQuestion('b'), isTrue);
    });
  });

  group('attentionArrivals(振动/弹窗触发源)', () {
    test('基线快照不触发;此后非当前会话新 rpcId 才广播', () async {
      final arrived = <String>[];
      final sub = store.attentionArrivals.listen(arrived.add);
      // 构造时 interactor 无快照 → 第一帧即基线。
      interactor.debugFeed(AddressedMuxFrame(
        rpcId: 'ar-baseline',
        frame: const MuxFrameApprovalRequested(
          sessionId: 'b',
          approvalId: 'ap-0',
          toolName: 'bash',
        ),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(arrived, isEmpty, reason: '首个快照是基线,不当新到达');
      // 新 rpcId + 非当前会话 → 广播。
      interactor.debugFeed(AddressedMuxFrame(
        rpcId: 'ar-new',
        frame: const MuxFrameApprovalRequested(
          sessionId: 'b',
          approvalId: 'ap-1',
          toolName: 'bash',
        ),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(arrived, ['b']);
      // 当前会话的交互不广播(就地渲染即可)。
      interactor.debugFeed(AddressedMuxFrame(
        rpcId: 'ar-mine',
        frame: const MuxFrameApprovalRequested(
          sessionId: 'a',
          approvalId: 'ap-2',
          toolName: 'bash',
        ),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(arrived, ['b']);
      // 同 rpcId 重放(重连重放 still-pending)不重复广播。
      interactor.debugFeed(AddressedMuxFrame(
        rpcId: 'ar-new',
        frame: const MuxFrameApprovalRequested(
          sessionId: 'b',
          approvalId: 'ap-1',
          toolName: 'bash',
        ),
      ));
      await Future<void>.delayed(Duration.zero);
      expect(arrived, ['b']);
      await sub.cancel();
    });

    test('question 到达同样广播', () async {
      final arrived = <String>[];
      final sub = store.attentionArrivals.listen(arrived.add);
      // 已有基线(approvals 快照先到过才会 _saw...Baseline;此处直接喂两帧:
      // 第一帧为基线,第二帧为新到达)。
      MuxFrameQuestionRequested q() => MuxFrameQuestionRequested(
            sessionId: 'b',
            questions: [
              AskUserQuestionItem.fromJson(const {
                'id': 'q1',
                'question': '继续吗?',
                'options': [
                  {'label': '继续'},
                ],
              }),
            ],
          );
      interactor.debugFeed(AddressedMuxFrame(rpcId: 'qr-base', frame: q()));
      interactor.debugFeed(AddressedMuxFrame(rpcId: 'qr-live', frame: q()));
      await Future<void>.delayed(Duration.zero);
      expect(arrived, ['b']);
      await sub.cancel();
    });
  });
}
