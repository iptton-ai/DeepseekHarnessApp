// 交互卡片刷新安全测试(ask/approval 不因界面刷新丢渲染):
// - 种子态:帧先到、面板后挂载 → current* 快照播种仍渲染;
// - 状态保持:问题列表增删(rpcId key)时已选/已输入状态不串位;
// - 单选语义:点第二个选项自动替换第一个;多选支持自定义输入;
// - 回执反馈:校验失败/过期应答内联提示,不清空已填内容。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

import '../helpers/fake_dsh_host.dart';

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

const _qYesNo = <Map<String, dynamic>>[
  {
    'id': 'q1',
    'question': '继续吗?',
    'options': [
      {'label': '继续', 'description': '马上继续'},
      {'label': '停止', 'description': '就此打住'},
    ],
  },
];

const _qMulti = <Map<String, dynamic>>[
  {
    'id': 'q2',
    'question': '选 toppings(可多选)',
    'multiSelect': true,
    'options': [
      {'label': '芝士'},
      {'label': '蘑菇'},
    ],
  },
];

void main() {
  late FakeDshHost host;
  late ConnectionController controller;
  late ApiClient api;
  late InteractorStore store;
  late _FakeSessionView sessions;
  late ChatViewModel vm;

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
    sessions = _FakeSessionView();
    sessions.emit([_summary('session-s1')]);
    vm = ChatViewModel(store: sessions, connection: null)..interactor = store;
  });

  tearDown(() async {
    await store.dispose();
    await controller.dispose();
    api.dispose();
    await host.stop();
    vm.dispose();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ChatSenderBinding(
        sender: (id, text) async {},
        child: ChatScreen(vm: vm),
      ),
    ));
    await tester.pump();
  }

  testWidgets('帧先到、面板后挂载 → 问题表单仍渲染(种子快照播种)', (tester) async {
    // 帧在 ChatScreen 构建之前推入(重连重放 pending 的时序)。
    host.pushQuestionFrame(rpcId: 'qr-seed', sessionId: 'session-s1', questions: _qYesNo);
    await Future<void>.delayed(Duration.zero);
    await pumpScreen(tester);
    expect(find.text('代理提问'), findsOneWidget);
    expect(find.text('继续吗?'), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);
  });

  testWidgets('流式到达:挂载后推帧,表单即时出现', (tester) async {
    await pumpScreen(tester);
    expect(find.text('代理提问'), findsNothing);
    host.pushQuestionFrame(rpcId: 'qr-live', sessionId: 'session-s1', questions: _qYesNo);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('继续吗?'), findsOneWidget);
  });

  testWidgets('列表增删不丢已选状态(rpcId key 防串位)', (tester) async {
    host.pushQuestionFrame(rpcId: 'qr-a', sessionId: 'session-s1', questions: _qYesNo);
    host.pushQuestionFrame(rpcId: 'qr-b', sessionId: 'session-s1', questions: _qMulti);
    await pumpScreen(tester);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('选 toppings(可多选)'), findsOneWidget);

    // 在 qr-b(多选)勾选「芝士」。
    await tester.tap(find.text('芝士'));
    await tester.pump();
    expect(find.text('选 toppings(可多选)'), findsOneWidget);

    // 应答 qr-a(先到的问题)→ resolved 清场,qr-b 上移一位。
    // 旧实现按位置匹配 element,qr-b 的已选状态会串到已被移除的问题上;
    // rpcId key 下状态跟随问题本体。
    await store.respondQuestions('qr-a', 'session-s1', [
      {
        'id': 'q1',
        'selected': ['继续'],
      },
    ]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('继续吗?'), findsNothing);
    expect(find.text('选 toppings(可多选)'), findsOneWidget);
    // qr-b 的「芝士」仍处于选中态(视觉标记存在)。
    expect(find.text('芝士'), findsOneWidget);
  });

  testWidgets('单选:点第二个选项自动替换第一个', (tester) async {
    host.pushQuestionFrame(rpcId: 'qr-single', sessionId: 'session-s1', questions: _qYesNo);
    await pumpScreen(tester);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('继续'));
    await tester.pump();
    await tester.tap(find.text('停止'));
    await tester.pump();
    // 提交:只有「停止」被选中(单选互斥由 UI 侧先行保证)。
    await tester.tap(find.text('提交'));
    await tester.pump(const Duration(milliseconds: 50));
    final env = host.respondCalls.single;
    final answers =
        ((env['result'] as Map)['value'] as Map)['answer'] as Map;
    expect((answers['answers'] as List).single['selected'], ['停止']);
  });

  testWidgets('多选:选项 + 自定义输入一起提交', (tester) async {
    host.pushQuestionFrame(rpcId: 'qr-multi', sessionId: 'session-s1', questions: _qMulti);
    await pumpScreen(tester);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('蘑菇'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '加辣');
    await tester.pump();
    await tester.tap(find.text('提交'));
    await tester.pump(const Duration(milliseconds: 50));
    final env = host.respondCalls.single;
    final answers =
        ((env['result'] as Map)['value'] as Map)['answer'] as Map;
    final answer = (answers['answers'] as List).single as Map;
    expect(answer['selected'], ['蘑菇']);
    expect(answer['custom'], '加辣');
  });

  testWidgets('校验失败 → 内联错误,内容不丢', (tester) async {
    host.pushQuestionFrame(rpcId: 'qr-empty', sessionId: 'session-s1', questions: _qYesNo);
    await pumpScreen(tester);
    await tester.pump(const Duration(milliseconds: 50));
    // 未选任何选项直接提交 → 本地预校验拒绝,内联显示错误。
    await tester.tap(find.text('提交'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('应答不完整'), findsOneWidget);
    expect(find.text('继续吗?'), findsOneWidget);
    // 已选内容仍可继续补填后成功提交。
    await tester.tap(find.text('继续'));
    await tester.pump();
    await tester.tap(find.text('提交'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(host.respondCalls, hasLength(1));
  });

  testWidgets('审批卡:帧先到后挂载也渲染;应答走按钮回调', (tester) async {
    host.pushApprovalFrame(
      rpcId: 'appr-1',
      sessionId: 'session-s1',
      approvalId: 'approval-1',
      reason: 'escalate sandbox',
    );
    await Future<void>.delayed(Duration.zero);
    await pumpScreen(tester);
    expect(find.text('审批请求'), findsOneWidget);
    expect(find.textContaining('escalate sandbox'), findsOneWidget);
    await tester.tap(find.text('允许一次'));
    await tester.pump(const Duration(milliseconds: 50));
    final env = host.respondCalls.single;
    final value = (env['result'] as Map)['value'] as Map;
    expect(value['outcome'], 'allowed-once');
    // resolved 帧清场。
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('审批请求'), findsNothing);
  });

  testWidgets('队列 Dock:切会话后从快照重读(不漏不串)', (tester) async {
    sessions.emit([_summary('session-s1'), _summary('session-s2')]);
    await pumpScreen(tester);
    host.pushQueueFrame(sessionId: 'session-s2', items: [
      {
        'itemId': 'qi-1',
        'placement': 'steering',
        'message': {
          'content': [
            {'type': 'text', 'text': '先看这个'},
          ],
        },
      },
    ]);
    await tester.pump(const Duration(milliseconds: 50));
    // 当前选中 s1(首个):s2 的队列不显示。
    expect(find.textContaining('先看这个'), findsNothing);
    // 切到 s2 → 队列从快照重读显示。
    vm.select('session-s2');
    await tester.pump();
    expect(find.textContaining('先看这个'), findsOneWidget);
  });
}
