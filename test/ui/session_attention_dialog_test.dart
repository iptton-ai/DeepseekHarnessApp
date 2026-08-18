// M5 移动端「需要关注」提醒测试:
// - 非当前会话交互到达(窄屏 enabled)→ 振动 3s + 唯一聚合 dialog;
// - dialog 已开时新到达不再振动、条目汇入同一 dialog;
// - 点条目 → 切换到该会话 + 关 dialog;全部 resolved → dialog 自收;
// - 宽屏(enabled: false)不振动不弹窗;
// - 交互卡就地渲染仍只限当前会话(门控回归)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart'
    show AddressedMuxFrame;
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/session_attention_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/session_attention_dialog.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class _RecordingApi extends ApiClient {
  _RecordingApi() : super(baseUri: Uri.parse('http://localhost:1'));

  @override
  Future<Map<String, dynamic>> postRespond(
    Map<String, dynamic> clientResponseEnvelope,
  ) async =>
      {'accepted': true};
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

SessionSummary _summary(String id) => SessionSummary(
      sessionId: id,
      updatedAt: 1786760000000,
      running: false,
      blank: false,
    );

class _FakeVibrator implements AttentionVibrator {
  int calls = 0;
  @override
  void vibrate3s() => calls++;
}

void main() {
  late _RecordingApi api;
  late InteractorStore interactor;
  late _FakeSessionView sessions;
  late ChatViewModel vm;
  late _FakeVibrator vibrator;

  setUp(() {
    api = _RecordingApi();
    interactor = InteractorStore(api: api, connection: null);
    sessions = _FakeSessionView();
    sessions.emit([_summary('session-s1'), _summary('session-ab12')]);
    vm = ChatViewModel(store: sessions, connection: null)
      ..interactor = interactor
      ..attention = SessionAttentionStore(
        sessions: sessions,
        interactor: interactor,
      );
    vibrator = _FakeVibrator();
  });

  tearDown(() {
    vm.attention?.dispose();
    vm.dispose();
    interactor.dispose();
  });

  void feedApproval(String rpcId, String sessionId) {
    interactor.debugFeed(AddressedMuxFrame(
      rpcId: rpcId,
      frame: MuxFrameApprovalRequested(
        sessionId: sessionId,
        approvalId: 'ap-' + rpcId,
        toolName: 'bash',
        reason: 'escalate sandbox',
      ),
    ));
  }

  void resolveApproval(String rpcId, String sessionId) {
    interactor.debugFeed(AddressedMuxFrame(
      rpcId: rpcId,
      frame: MuxFrameApprovalResolved(
        sessionId: sessionId,
        approvalId: 'ap-' + rpcId,
        outcome: 'allowed-once',
      ),
    ));
  }

  /// 基线快照:喂一条随后立即 resolve 的审批 —— 建立 _sawApprovalsBaseline
  /// 标记,但不在待处理集合里留残余(否则后续断言分不清基线与真实到达)。
  void feedBaseline() {
    feedApproval('ar-baseline', 'session-ab12');
    resolveApproval('ar-baseline', 'session-ab12');
  }

  Future<void> pumpNarrow(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: ChatSenderBinding(
        sender: (id, text) async {},
        child: ChatScreen(vm: vm, attentionVibrator: vibrator),
      ),
    ));
    await tester.pump();
  }

  testWidgets('非当前会话审批到达(窄屏)→ 振动一次 + 唯一聚合 dialog;条目直达切换',
      (tester) async {
    await pumpNarrow(tester);
    // 到达前:无 dialog、无振动、当前会话交互面无卡(门控)。
    expect(vibrator.calls, 0);
    expect(find.text('需要你的关注'), findsNothing);
    feedBaseline();
    feedApproval('ar-live', 'session-ab12');
    await tester.pump(const Duration(milliseconds: 50));
    expect(vibrator.calls, 1, reason: '新到达振动一次');
    expect(find.text('需要你的关注'), findsOneWidget);
    expect(find.textContaining('等待审批'), findsOneWidget);
    // 点条目 → 切换到该会话 + dialog 关闭。
    await tester.tap(find.textContaining('等待审批'));
    await tester.pumpAndSettle();
    expect(vm.selectedId, 'session-ab12');
    expect(find.text('需要你的关注'), findsNothing);
    // 切过去后:该会话的交互卡就地渲染(门控的另一面)。
    expect(find.text('审批请求'), findsOneWidget);
  });

  testWidgets('dialog 已开时新到达不再振动,条目汇入同一 dialog', (tester) async {
    await pumpNarrow(tester);
    feedBaseline();
    feedApproval('ar-b', 'session-ab12');
    await tester.pump(const Duration(milliseconds: 50));
    expect(vibrator.calls, 1);
    // 第三个会话的到达:同 dialog 汇入,不重复振动。
    sessions.emit([
      _summary('session-s1'),
      _summary('session-ab12'),
      _summary('session-cd34'),
    ]);
    await tester.pump(const Duration(milliseconds: 50));
    feedApproval('ar-c', 'session-cd34');
    await tester.pump(const Duration(milliseconds: 50));
    expect(vibrator.calls, 1, reason: 'dialog 已开,只更新条目');
    expect(find.textContaining('等待审批'), findsNWidgets(2));
    expect(find.text('需要你的关注'), findsOneWidget);
  });

  testWidgets('全部 resolved → dialog 自动收起', (tester) async {
    await pumpNarrow(tester);
    feedBaseline();
    feedApproval('ar-x', 'session-ab12');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('需要你的关注'), findsOneWidget);
    resolveApproval('ar-x', 'session-ab12');
    await tester.pumpAndSettle();
    expect(find.text('需要你的关注'), findsNothing);
  });

  testWidgets('当前会话自己的交互不弹 dialog 不振动', (tester) async {
    await pumpNarrow(tester);
    feedApproval('ar-mine', 'session-s1');
    await tester.pump(const Duration(milliseconds: 50));
    expect(vibrator.calls, 0);
    expect(find.text('需要你的关注'), findsNothing);
    // 就地渲染当前会话的卡。
    expect(find.text('审批请求'), findsOneWidget);
  });

  testWidgets('宽屏:非当前会话交互不振动不弹窗(侧栏状态点承载)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: ChatSenderBinding(
        sender: (id, text) async {},
        child: ChatScreen(vm: vm, attentionVibrator: vibrator),
      ),
    ));
    await tester.pump();
    feedApproval('ar-wide', 'session-ab12');
    await tester.pump(const Duration(milliseconds: 50));
    expect(vibrator.calls, 0);
    expect(find.text('需要你的关注'), findsNothing);
  });
}
