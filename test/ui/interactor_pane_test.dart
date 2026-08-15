// 交互卡片刷新安全测试(ask/approval 不因界面刷新丢渲染):
// - 种子态:帧先到、面板后挂载 → current* 快照播种仍渲染;
// - 状态保持:问题列表增删(rpcId key)时已选/已输入状态不串位;
// - 单选语义:点第二个选项自动替换第一个;多选支持自定义输入;
// - 回执反馈:校验失败内联提示,不清空已填内容;应答信封回显 rpcId。
// 纪律:不碰真 socket —— 帧经 InteractorStore.debugFeed 直喂(fake-async
// zone 下真连接的 Timer 不走),应答经 _RecordingApi 截获。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/interactor_widgets.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(baseUri: Uri.parse('http://localhost:1'));
  final responds = <Map<String, dynamic>>[];
  /// 应答回执:true = accepted;false = not-pending(迟到)。
  bool acceptNext = true;

  @override
  Future<Map<String, dynamic>> postRespond(
    Map<String, dynamic> clientResponseEnvelope,
  ) async {
    responds.add(clientResponseEnvelope);
    return acceptNext
        ? {'accepted': true}
        : {'accepted': false, 'reason': 'not-pending'};
  }
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
}

SessionSummary _summary(String id) => SessionSummary(
      sessionId: id,
      updatedAt: 1786760000000,
      running: false,
      blank: false,
    );

final _qYesNo = <AskUserQuestionItem>[
  AskUserQuestionItem.fromJson(const {
    'id': 'q1',
    'question': '继续吗?',
    'options': [
      {'label': '继续', 'description': '马上继续'},
      {'label': '停止', 'description': '就此打住'},
    ],
  }),
];

final _qMulti = <AskUserQuestionItem>[
  AskUserQuestionItem.fromJson(const {
    'id': 'q2',
    'question': '选 toppings(可多选)',
    'multiSelect': true,
    'options': [
      {'label': '芝士'},
      {'label': '蘑菇'},
    ],
  }),
];

void main() {
  late _RecordingApi api;
  late InteractorStore store;
  late _FakeSessionView sessions;
  late ChatViewModel vm;

  setUp(() {
    api = _RecordingApi();
    store = InteractorStore(api: api, connection: null);
    sessions = _FakeSessionView();
    sessions.emit([_summary('session-s1')]);
    vm = ChatViewModel(store: sessions, connection: null)..interactor = store;
  });

  tearDown(() async {
    await store.dispose();
    vm.dispose();
  });

  void feedQuestion(String rpcId, {String sessionId = 'session-s1', List<AskUserQuestionItem>? questions}) {
    store.debugFeed(AddressedMuxFrame(
      rpcId: rpcId,
      frame: MuxFrameQuestionRequested(
        sessionId: sessionId,
        questions: questions ?? _qYesNo,
      ),
    ));
  }

  void resolveQuestion(String rpcId) {
    store.debugFeed(AddressedMuxFrame(
      rpcId: rpcId,
      frame: MuxFrameQuestionResolved(
        sessionId: 'session-s1',
        questionRpcId: rpcId,
        outcome: 'answered',
      ),
    ));
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ChatSenderBinding(
        sender: (id, text) async {},
        child: ChatScreen(vm: vm),
      ),
    ));
    await tester.pump();
  }

  /// 点「提交」:面板在限高滚动容器里,先滚到位再点(否则 tap 落空)。
  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.text('提交'));
    await tester.pump();
    await tester.tap(find.text('提交'));
  }

  testWidgets('帧先到、面板后挂载 → 问题表单仍渲染(种子快照播种)', (tester) async {
    // 帧在 ChatScreen 构建之前推入(重连重放 pending 的时序)。
    // debugFeed 同步写入 store,无需等流(fake-async zone 里 delayed 不走)。
    feedQuestion('qr-seed');
    await pumpScreen(tester);
    expect(find.text('代理提问'), findsOneWidget);
    expect(find.text('继续吗?'), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);
  });

  testWidgets('流式到达:挂载后推帧,表单即时出现', (tester) async {
    await pumpScreen(tester);
    expect(find.text('代理提问'), findsNothing);
    feedQuestion('qr-live');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('继续吗?'), findsOneWidget);
  });

  testWidgets('列表增删不丢已选状态(rpcId key 防串位)', (tester) async {
    feedQuestion('qr-a');
    feedQuestion('qr-b', questions: _qMulti);
    await pumpScreen(tester);
    expect(find.text('选 toppings(可多选)'), findsOneWidget);

    // 在 qr-b(多选)勾选「芝士」(第二张卡在折叠线下,先滚到位)。
    await tester.ensureVisible(find.text('芝士'));
    await tester.pump();
    await tester.tap(find.text('芝士'));
    await tester.pump();

    // qr-a resolved 清场 → qr-b 上移一位。
    // 旧实现按位置匹配 element,qr-b 的已选状态会串到已被移除的问题上;
    // rpcId key 下状态跟随问题本体。
    resolveQuestion('qr-a');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('继续吗?'), findsNothing);
    expect(find.text('选 toppings(可多选)'), findsOneWidget);
    // qr-b 的「芝士」仍可提交(状态未丢)。
    await submit(tester);
    await tester.pump(const Duration(milliseconds: 50));
    final env = api.responds.single;
    expect(env['rpcId'], 'qr-b');
    final answer =
        (((env['result'] as Map)['value'] as Map)['answer'] as Map)['answers'] as List;
    expect(answer.single['selected'], ['芝士']);
  });

  testWidgets('单选:点第二个选项自动替换第一个', (tester) async {
    feedQuestion('qr-single');
    await pumpScreen(tester);
    await tester.tap(find.text('继续'));
    await tester.pump();
    await tester.tap(find.text('停止'));
    await tester.pump();
    await submit(tester);
    await tester.pump(const Duration(milliseconds: 50));
    final env = api.responds.single;
    final answer =
        (((env['result'] as Map)['value'] as Map)['answer'] as Map)['answers'] as List;
    expect(answer.single['selected'], ['停止']);
  });

  testWidgets('多选:选项 + 自定义输入一起提交', (tester) async {
    feedQuestion('qr-multi', questions: _qMulti);
    await pumpScreen(tester);
    await tester.tap(find.text('蘑菇'));
    await tester.pump();
    await tester.enterText(
      find.descendant(of: find.byType(QuestionForm), matching: find.byType(TextField)),
      '加辣',
    );
    await tester.pump();
    await submit(tester);
    await tester.pump(const Duration(milliseconds: 50));
    final env = api.responds.single;
    final answer =
        (((env['result'] as Map)['value'] as Map)['answer'] as Map)['answers'] as List;
    final a = answer.single as Map;
    expect(a['selected'], ['蘑菇']);
    expect(a['custom'], '加辣');
  });

  testWidgets('校验失败 → 内联错误,内容不丢', (tester) async {
    feedQuestion('qr-empty');
    await pumpScreen(tester);
    // 未选任何选项直接提交 → 本地预校验拒绝,内联显示错误。
    await submit(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('应答不完整'), findsOneWidget);
    expect(find.text('继续吗?'), findsOneWidget);
    expect(api.responds, isEmpty); // 未发请求
    // 补填后成功提交。
    await tester.tap(find.text('继续'));
    await tester.pump();
    await submit(tester);
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.responds, hasLength(1));
  });

  testWidgets('迟到应答(not-pending)→ 表单内联提示', (tester) async {
    feedQuestion('qr-late');
    await pumpScreen(tester);
    api.acceptNext = false; // 服务端回执 not-pending
    await tester.tap(find.text('继续'));
    await tester.pump();
    await submit(tester);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('已被处理'), findsOneWidget);
  });

  testWidgets('审批卡:帧先到后挂载也渲染;应答走按钮回调', (tester) async {
    store.debugFeed(const AddressedMuxFrame(
      rpcId: 'appr-1',
      frame: MuxFrameApprovalRequested(
        sessionId: 'session-s1',
        approvalId: 'approval-1',
        toolName: 'bash',
        reason: 'escalate sandbox',
      ),
    ));
    await pumpScreen(tester);
    expect(find.text('审批请求'), findsOneWidget);
    expect(find.textContaining('escalate sandbox'), findsOneWidget);
    await tester.tap(find.text('允许一次'));
    await tester.pump(const Duration(milliseconds: 50));
    final env = api.responds.single;
    expect(env['rpcId'], 'appr-1');
    final value = (env['result'] as Map)['value'] as Map;
    expect(value['outcome'], 'allowed-once');
    // resolved 帧清场。
    store.debugFeed(const AddressedMuxFrame(
      rpcId: 'appr-1',
      frame: MuxFrameApprovalResolved(
        sessionId: 'session-s1',
        approvalId: 'approval-1',
        outcome: 'allowed-once',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('审批请求'), findsNothing);
  });

  testWidgets('跨会话审批/提问带归属徽标', (tester) async {
    sessions.emit([_summary('session-s1'), _summary('session-ab12')]);
    await pumpScreen(tester);
    feedQuestion('qr-other', sessionId: 'session-ab12');
    await tester.pump(const Duration(milliseconds: 50));
    // 徽标文本 = '会话 ·ab12'。
    expect(find.text('会话 ·ab12'), findsOneWidget);
    // 当前会话(s1)自己的问题不带徽标。
    feedQuestion('qr-mine');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('继续吗?'), findsNWidgets(2));
  });

  testWidgets('队列 Dock:切会话后从快照重读(不漏不串)', (tester) async {
    sessions.emit([_summary('session-s1'), _summary('session-s2')]);
    await pumpScreen(tester);
    store.debugFeed(AddressedMuxFrame(
      rpcId: 'queue-1',
      frame: MuxFrameSessionQueue(
        sessionId: 'session-s2',
        items: [
          {
            'itemId': 'qi-1',
            'placement': 'steering',
            'message': {
              'content': [
                {'type': 'text', 'text': '先看这个'},
              ],
            },
          },
        ],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    // 当前选中 s1(首个):s2 的队列不显示。
    expect(find.textContaining('先看这个'), findsNothing);
    // 切到 s2 → 队列从快照重读显示(不依赖新帧)。
    vm.select('session-s2');
    await tester.pump();
    expect(find.textContaining('先看这个'), findsOneWidget);
  });
}
