// 侧栏主机切换下拉 + 会话列表装载态验收(多主机 UI 补齐):
// - 头部标题块:主机簿非空 → 当前宿主名 + 下拉菜单(全部主机 + 添加);
//   无簿保持静态「DshAPP / AI 工作台」。
// - 会话列表:连接未就绪且无数据 → 加载态(切主机整代重装窗口),
//   不再闪误导性的「新建会话」空态;已有数据照常显示,不闪空。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/host_info.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class _FakeWorkspaceStore implements WorkspaceStoreView {
  final _ctrl = StreamController<List<WorkspaceView>>.broadcast();
  List<WorkspaceView> _items = const [];

  @override
  Stream<List<WorkspaceView>> get workspaces => _ctrl.stream;
  @override
  List<WorkspaceView> get currentWorkspaces => _items;
  @override
  Stream<List<String>> get archivedSessionIds => const Stream.empty();
  @override
  List<String> get currentArchivedSessionIds => const [];
  @override
  bool isArchived(String sessionId) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

StoredCredentials _host(String id, String base, {String label = ''}) =>
    StoredCredentials(
      id: id,
      baseUri: Uri.parse(base),
      token: 'token-$id',
      hostLabel: label,
    );

void main() {
  testWidgets('无主机簿:头部保持静态品牌文案,无切换器', (tester) async {
    final vm = ChatViewModel(store: _FakeSessionView(), connection: null);
    await tester.pumpWidget(MaterialApp(home: ChatScreen(vm: vm)));
    await tester.pump();

    expect(find.text('AI 工作台'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-switcher')), findsNothing);
  });

  testWidgets('有主机簿:头部显示活动主机(簿驱动,标签随簿翻转即时更新)',
      (tester) async {
    final gw1 = _host('https://a.example.com:443', 'https://a.example.com',
        label: 'devs-MacBook-Pro');
    final gw2 =
        _host('https://b.example.com:443#t2', 'https://b.example.com');
    final hosts =
        ValueNotifier(HostBook(hosts: [gw1, gw2], activeId: gw1.id));
    // 连接层的实时机器名属于旧代连接:头部标签不得被它盖住(否则切了
    // 主机、头部还显示旧宿主名)。
    final status = ValueNotifier(
      const HostStatus(authed: true, up: true, machine: '旧宿主实时名'),
    );
    final vm = ChatViewModel(store: _FakeSessionView(), connection: null)
      ..phase = ConnectionPhase.ready;

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(vm: vm, hosts: hosts, hostStatus: status),
    ));
    await tester.pump();

    // 标签 = 簿内活动条目 hostLabel;不是连接层 machine。
    expect(find.text('devs-MacBook-Pro'), findsOneWidget);
    expect(find.text('旧宿主实时名'), findsNothing);

    // 簿翻转(选中另一台)→ 头部标签同一拍更新,不等整代重装。
    hosts.value = HostBook(hosts: [gw1, gw2], activeId: gw2.id);
    await tester.pump();
    expect(find.text('b.example.com'), findsOneWidget);
    expect(find.text('devs-MacBook-Pro'), findsNothing,
        reason: '头部标签与菜单勾选态同源,切了就必须换');
  });

  testWidgets('下拉菜单:列出全部主机,选中其他主机触发 onSwitchHost',
      (tester) async {
    final gw1 = _host('https://a.example.com:443', 'https://a.example.com',
        label: 'devs-MacBook-Pro');
    final gw2 =
        _host('https://b.example.com:443#t2', 'https://b.example.com');
    final hosts =
        ValueNotifier(HostBook(hosts: [gw1, gw2], activeId: gw1.id));
    String? switched;
    var paired = 0;
    // phase=ready:避免装载态转圈动画令 pumpAndSettle 永不收敛。
    final vm = ChatViewModel(store: _FakeSessionView(), connection: null)
      ..phase = ConnectionPhase.ready;

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        vm: vm,
        hosts: hosts,
        onSwitchHost: (id) async => switched = id,
        onOpenPairing: () => paired++,
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('host-switcher')));
    await tester.pumpAndSettle();

    // 两台主机 + 添加入口;gw2 无 label → 显示网关地址(不重复附地址);
    // gw1 有 label → 附网关地址消歧(同机名多条通道可分辨)。
    expect(find.text('devs-MacBook-Pro'), findsWidgets);
    expect(find.text('a.example.com'), findsOneWidget);
    expect(find.text('b.example.com'), findsOneWidget);
    expect(find.text('添加主机(配对)'), findsOneWidget);

    // 点当前主机:不触发切换。
    await tester.tap(find.text('devs-MacBook-Pro').last);
    await tester.pumpAndSettle();
    expect(switched, isNull);

    // 点另一台主机:带复合键 id 上抛。
    await tester.tap(find.byKey(const ValueKey('host-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b.example.com'));
    await tester.pumpAndSettle();
    expect(switched, 'https://b.example.com:443#t2');
    expect(paired, 0, reason: '切主机与添加入口互不串扰');
  });

  testWidgets('下拉菜单:「添加主机(配对)」打开配对页入口', (tester) async {
    final gw1 = _host('https://a.example.com:443', 'https://a.example.com',
        label: 'devs-MacBook-Pro');
    final hosts = ValueNotifier(HostBook(hosts: [gw1], activeId: gw1.id));
    var paired = 0;
    // phase=ready:避免装载态转圈动画令 pumpAndSettle 永不收敛。
    final vm = ChatViewModel(store: _FakeSessionView(), connection: null)
      ..phase = ConnectionPhase.ready;

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        vm: vm,
        hosts: hosts,
        onOpenPairing: () => paired++,
      ),
    ));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('host-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加主机(配对)'));
    await tester.pumpAndSettle();
    expect(paired, 1);
  });

  testWidgets('会话列表装载态:连接未就绪且无数据 → 加载态而非「新建会话」空态',
      (tester) async {
    final sessions = _FakeSessionView();
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(vm: vm, workspaces: _FakeWorkspaceStore())),
    );
    await tester.pump();

    // connection == null → phase 恒 connecting(装载窗口的等价形态)。
    expect(find.text('正在加载会话…'), findsOneWidget);
    expect(find.text('新建会话'), findsNothing);

    // 数据到达(列表在飞的新主机会话):立即让位,不闪空。
    sessions.emit([_summary('s1')]);
    await tester.pump();
    expect(find.text('正在加载会话…'), findsNothing);
    expect(find.text('s1'), findsOneWidget);
  });

  testWidgets('会话列表装载态:已就绪的空列表保持「未分组」空态',
      (tester) async {
    final vm = ChatViewModel(store: _FakeSessionView(), connection: null)
      ..phase = ConnectionPhase.ready;

    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(vm: vm, workspaces: _FakeWorkspaceStore())),
    );
    await tester.pump();

    expect(find.text('正在加载会话…'), findsNothing);
    // 侧栏「未分组」兜底组头(composer 工作区 chip 亦显示同名)。
    expect(find.text('未分组'), findsWidgets);
  });

  testWidgets('扁平回退列表(workspaces 未注入)同样遵循装载态语义',
      (tester) async {
    final vm = ChatViewModel(store: _FakeSessionView(), connection: null);
    await tester.pumpWidget(MaterialApp(home: ChatScreen(vm: vm)));
    await tester.pump();
    expect(find.text('正在加载会话…'), findsOneWidget);

    vm.phase = ConnectionPhase.ready;
    await tester.pumpWidget(MaterialApp(home: ChatScreen(vm: vm)));
    await tester.pump();
    expect(find.text('还没有会话'), findsOneWidget);
  });
}
