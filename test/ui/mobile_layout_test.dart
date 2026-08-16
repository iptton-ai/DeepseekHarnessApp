// W1 集成验收:窄屏(<600dp)抽屉形态 + workspace 分组在抽屉内可见。
// 移动可用性硬性验收(PLAN「W1 集成规格」第 4/5 条)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/agent_preset_store.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class _FakeWorkspaceStore implements WorkspaceStoreView {
  final _ctrl = StreamController<List<WorkspaceView>>.broadcast();
  final _archivedCtrl = StreamController<List<String>>.broadcast();
  List<WorkspaceView> _items = const [];
  List<String> _archived = const [];

  void emit(List<WorkspaceView> items) {
    _items = items;
    _ctrl.add(items);
  }

  @override
  Stream<List<WorkspaceView>> get workspaces => _ctrl.stream;
  @override
  List<WorkspaceView> get currentWorkspaces => _items;
  @override
  Stream<List<String>> get archivedSessionIds => _archivedCtrl.stream;
  @override
  List<String> get currentArchivedSessionIds => _archived;
  @override
  bool isArchived(String sessionId) => _archived.contains(sessionId);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSessionView implements SessionStoreView {
  final _ctrl = StreamController<List<SessionSummary>>.broadcast();
  final logs = <String, SessionLog>{};
  List<SessionSummary> _current = const [];
  int loadCalls = 0;

  /// 可控历史装载:非 null 时挂起直到 complete/completeError。
  Completer<void>? loadGate;

  void emit(List<SessionSummary> list) {
    _current = list;
    _ctrl.add(list);
  }

  @override
  Stream<List<SessionSummary>> get summaries => _ctrl.stream;
  @override
  List<SessionSummary> get currentSummaries => _current;
  @override
  SessionLog logFor(String sessionId) =>
      logs.putIfAbsent(sessionId, () => SessionLog(sessionId));
  @override
  Future<void> loadHistory(String sessionId) async {
    loadCalls += 1;
    final gate = loadGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> loadOlder(String sessionId) async {}

  @override
  Future<String> fork(String sessionId, {int? atSeq}) async => 'forked';

}

WorkspaceView _ws(String id, String title, List<String> sessionIds) =>
    WorkspaceView(
      workspaceId: id,
      path: '/tmp/$id',
      title: title,
      sessionIds: sessionIds,
      createdAt: '2026-08-15T00:00:00Z',
      updatedAt: '2026-08-15T00:00:00Z',
    );

SessionSummary _summary(String id) => SessionSummary(
  sessionId: id,
  updatedAt: 1786760000000,
  running: false,
  blank: false,
);

/// 内置预设目录假 store(trust=system;select 直通)。
class _FakePresetStore implements AgentPresetStoreView {
  @override
  Future<AgentPresetListValue> list({bool force = false}) async =>
      AgentPresetListValue(
        presets: const [
          AgentPresetEntry(id: 'standard', trust: 'system', isDefault: true),
          AgentPresetEntry(id: 'code', trust: 'system', isDefault: false),
        ],
        authorable: false,
        hasDocument: false,
      );
  @override
  Future<AgentPresetSelectValue> select(
          String sessionId, String agentPreset) async =>
      AgentPresetSelectValue(agentPreset: agentPreset);
}

/// 头部动作区只需要 commands 非空(构建期不调用其方法)。
class _FakeCommands implements CommandStoreView {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 假命令目录 store:记录 execute 调用(权限切换回归:必须走 commands/execute)。
class _FakeCommandStore implements CommandStoreView {
  final executed = <String>[];
  final loaded = <String>[];

  @override
  Future<CommandListResult> listCommands(String sessionId,
      {bool force = false}) async {
    loaded.add(sessionId);
    return CommandListResult.ok(const [
      CommandEntry(name: 'permission', description: '切换权限'),
    ]);
  }

  @override
  Future<CommandMenu> listAll(String sessionId, {bool force = false}) async {
    final result = await listCommands(sessionId, force: force);
    return CommandMenu(
      commands: [for (final c in result.commands) CommandMenuItem.command(c)],
      skills: const [],
      degraded: false,
    );
  }

  @override
  Future<void> execute(String sessionId, String line) async {
    executed.add(line);
  }
}

/// 空目录假 settings store(设置中心入口/子菜单渲染不依赖特权数据)。
class _FakeSettingsStore implements SettingsStoreView {
  final _ctrl = StreamController<SettingsSnapshot>.broadcast();

  @override
  Stream<SettingsSnapshot> get snapshots => _ctrl.stream;

  @override
  SettingsSnapshot get current => SettingsSnapshot.empty;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('窄屏(<600dp):侧栏进抽屉,打开后 workspace 分组可见', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      _ws('w1', '我的工作区', ['s1']),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(vm: vm, workspaces: ws),
      ),
    );
    await tester.pump();

    // 窄屏:消息 pane 直接可见,菜单按钮存在;workspace 分组不直接渲染(在抽屉里)。
    // s1 非 blank(会话已开始)→ composer 上方行整体隐藏(用户诉求:
    // 会话进行中不再显示工作区/工作模式 chip)。
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.text('我的工作区'), findsNothing,
        reason: '非 blank 会话:composer 工作区 chip 不渲染');

    // 打开抽屉:分组出现(仅抽屉组头一处)。
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('我的工作区'), findsOneWidget);

    // 窄屏抽屉顶部右上角同样有「收起」按钮(用户诉求;收起=关抽屉)。
    final collapse = find.byTooltip('收起侧栏');
    expect(collapse, findsOneWidget);
    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(find.text('我的工作区'), findsNothing,
        reason: '抽屉关闭且非 blank:无处显示工作区名');
  });

  testWidgets('窄屏:顶部仅 AppBar 一根标题栏,pane 内 52dp 标题行让位(用户实报双标题栏)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      _ws('w1', '我的工作区', ['s1']),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          vm: vm,
          workspaces: ws,
          commands: _FakeCommands(),
          onNewSession: (_) {},
        ),
      ),
    );
    await tester.pump();

    // 用户诉求:只保留带菜单 icon + 新建会话 icon 的那根 AppBar。
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byIcon(Icons.add),
      ),
      findsOneWidget,
      reason: 'AppBar「新建会话」(composer「+」命令按钮另有同款 icon,需限定)',
    );

    // 标题锚点与标题栏动作簇各只一份:修复前 AppBar 与 pane 标题行
    // 各渲染一次 pane-title/timeline/terminal(两根标题栏叠放)。
    expect(find.byKey(const ValueKey('pane-title')), findsOneWidget);
    expect(find.byIcon(Icons.timeline), findsOneWidget,
        reason: '「轨迹」动作仅 AppBar 一份');
    expect(find.byIcon(Icons.terminal), findsOneWidget,
        reason: '「命令」动作仅 AppBar 一份');
  });

  testWidgets('composer 上方行:blank 会话显示工作区/工作模式 chip;会话开始后整体隐藏',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([
      SessionSummary(
        sessionId: 'b1',
        updatedAt: 1786760000000,
        running: false,
        blank: true,
        agentPreset: 'code',
      ),
    ]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '新会话区', ['b1'])]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          vm: vm,
          workspaces: ws,
          agentPresets: _FakePresetStore(),
          onNewSession: (_) {},
        ),
      ),
    );
    await tester.pump();

    // blank:工作区 chip + 工作模式 chip 都在;内置 code 预设显示
    //「PTC 模式」(web presetDisplayText 语义),不是裸 id「code」。
    expect(find.byKey(const ValueKey('composer-workspace')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-workmode')), findsOneWidget);
    expect(find.text('PTC 模式'), findsOneWidget);
    expect(find.text('新会话区'), findsNWidgets(2),
        reason: '侧栏组头 + composer 工作区 chip');

    // 会话开始(non-blank):上方行整体隐藏(用户诉求)。
    sessions.emit([
      SessionSummary(
        sessionId: 'b1',
        updatedAt: 1786760000001,
        running: false,
        blank: false,
        agentPreset: 'code',
      ),
    ]);
    await tester.pump();
    expect(find.byKey(const ValueKey('composer-workspace')), findsNothing);
    expect(find.byKey(const ValueKey('composer-workmode')), findsNothing);
    expect(find.text('PTC 模式'), findsNothing);
    expect(find.text('新会话区'), findsOneWidget,
        reason: '仅侧栏组头保留');
  });

  testWidgets('权限切换走 commands/execute,不发用户消息(web session.command 对齐)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    // 预置 permission/preset 事件:selectedPermissionPreset 回溯出 read-only。
    sessions.logFor('s1').append(const SessionEvent(
      type: 'permission/preset',
      seq: 1,
      time: 1,
      data: {'preset': 'read-only'},
    ));
    sessions.emit([_summary('s1')]);
    final commands = _FakeCommandStore();
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(vm: vm, commands: commands),
      ),
    );
    await tester.pump();

    // chip 显示当前档位(由日志回溯)。
    expect(find.text('只读'), findsOneWidget);

    // 打开切换 sheet → 选「工作区可写」(非 danger,不弹确认)。
    await tester.tap(find.byKey(const ValueKey('composer-permission')));
    await tester.pumpAndSettle();
    expect(find.text('访问模式'), findsOneWidget);
    await tester.tap(find.text('工作区可写'));
    await tester.pumpAndSettle();

    // 关键断言:经 commands/execute 通道(非 prompt —— 命令不发用户消息)。
    expect(commands.executed, ['/permission workspace-write']);
    expect(commands.loaded, isNotEmpty, reason: 'execute 前预热目录缓存');
    // 会话日志无新增 user/message(错误通道的可见症状)。
    expect(
      sessions.logFor('s1').events.where((e) => e.type == 'user/message'),
      isEmpty,
    );
  });

  testWidgets('宽屏(≥600dp):侧栏常驻,workspace 分组直接可见', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      _ws('w1', '宽屏工作区', ['s1']),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(vm: vm, workspaces: ws),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.menu), findsNothing);
    expect(find.text('宽屏工作区'), findsOneWidget,
        reason: '仅侧栏组头;非 blank 会话 composer chip 隐藏');
  });

  testWidgets('workspace 标题可折叠/展开组内会话', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      _ws('w1', '可折叠工作区', ['s1']),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(vm: vm, workspaces: ws),
      ),
    );
    await tester.pump();

    expect(find.text('s1'), findsOneWidget);
    final groupHeader = find.descendant(
      of: find.byKey(const ValueKey('wide-sidebar-pane')),
      matching: find.text('可折叠工作区'),
    );
    await tester.tap(groupHeader);
    await tester.pump();
    expect(find.text('s1'), findsNothing);

    await tester.tap(groupHeader);
    await tester.pump();
    expect(find.text('s1'), findsOneWidget);
  });

  testWidgets('M6/M6.1:设置中心常驻入口 —— 窄屏抽屉内可见,连接子菜单可达',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '我的工作区', ['s1'])]);
    final vm = ChatViewModel(store: sessions, connection: null);

    var pairingOpened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          vm: vm,
          workspaces: ws,
          settings: _FakeSettingsStore(),
          // LAN 形态(非特权):入口仍必须可见 —— 手机靠它进设置发起配对。
          scope: scopeFor(Uri.parse('http://192.168.1.5:3080')),
          onOpenPairing: () => pairingOpened++,
        ),
      ),
    );
    await tester.pump();

    // 窄屏:设置入口在抽屉里,主界面不直接可见;独立的「远程网关」tile
    // 已移除(重构:收进设置中心的「连接」分区)。
    expect(find.text('设置'), findsNothing);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('远程网关'), findsNothing);

    // 打开设置中心:连接分区提供 发起配对 子菜单(密码登录入口已移除)。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('模型选择'), findsOneWidget);
    expect(find.text('密码登录'), findsNothing);
    expect(find.text('发起配对'), findsOneWidget);

    await tester.tap(find.text('发起配对'));
    await tester.pump();
    expect(pairingOpened, 1);
  });

  testWidgets('宽屏:侧栏可最小化为 56dp 轨道,展开可还原', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      _ws('w1', '轨道工作区', ['s1']),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(vm: vm, workspaces: ws)),
    );
    await tester.pump();

    final pane = find.byKey(const ValueKey('wide-sidebar-pane'));
    expect(tester.getSize(pane).width, 292);
    expect(find.text('轨道工作区'), findsOneWidget,
        reason: '仅侧栏组头;非 blank 会话 composer chip 隐藏');

    // 最小化:292 → 56,折叠控件在侧栏头部(⟨⟨| 形,_PanelCollapseIcon)。
    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
    await tester.pumpAndSettle();
    expect(tester.getSize(pane).width, 56);

    // 轨道展开按钮还原 292dp。
    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_right));
    await tester.pumpAndSettle();
    expect(tester.getSize(pane).width, 292);
    expect(find.text('轨道工作区'), findsOneWidget,
        reason: '仅侧栏组头;非 blank 会话 composer chip 隐藏');
  });

  testWidgets('窄屏:抽屉内选中会话后抽屉自动收起', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      _ws('w1', '我的工作区', ['s1']),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(vm: vm, workspaces: ws)),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    // 仅抽屉组头一处(非 blank 会话 composer chip 隐藏)。
    expect(find.text('我的工作区'), findsOneWidget);

    // 选中会话 → 抽屉主动收起。
    // (AppBar 标题也是 's1',必须限定在抽屉内点击会话行。)
    await tester.tap(find.descendant(
      of: find.byType(Drawer),
      matching: find.text('s1'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('我的工作区'), findsNothing,
        reason: '抽屉已收起,非 blank 会话 composer chip 不渲染');
  });

  testWidgets('会话行:无专门图标,running 会话显示 loading 小动画', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([
      SessionSummary(
        sessionId: 'r1',
        updatedAt: 1786760000000,
        running: true,
        blank: false,
      ),
      _summary('s2'),
    ]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      _ws('w1', '状态工作区', ['r1', 's2']),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(vm: vm, workspaces: ws)),
    );
    await tester.pump();

    // 仅 running 会话一个小动画;旧的状态图标全部移除。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
    expect(find.byIcon(Icons.autorenew), findsNothing);
    expect(find.byIcon(Icons.circle_outlined), findsNothing);
  });

  testWidgets('会话名:web displayTitle 链 —— title 投影 → cwd 目录名 → 原始 id',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([
      // 有 title 投影:优先显示投影标题。
      SessionSummary(
        sessionId: 'p1',
        updatedAt: 1786760000000,
        running: false,
        blank: false,
        cwd: '/tmp/somewhere',
        // rc.6 wire:title 投影值是纯字符串(非嵌套 map)。
        projections: SessionProjectionsBlock(
          asOfSeq: 1,
          values: const {'title': '调研侧栏逻辑'},
        ),
      ),
      // 无投影但有 cwd:回退工作区目录名(去结尾斜杠取末段)。
      SessionSummary(
        sessionId: 'c1',
        updatedAt: 1786760000000,
        running: false,
        blank: false,
        cwd: '/tmp/workspaces/demo-project/',
      ),
      // 两者皆无:回退原始 sessionId(不再截 UUID 片段)。
      _summary('raw-id-fallback'),
    ]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      _ws('w1', '名称工作区', ['p1', 'c1', 'raw-id-fallback']),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(vm: vm, workspaces: ws)),
    );
    await tester.pump();

    expect(find.text('调研侧栏逻辑'), findsOneWidget);
    expect(find.text('demo-project'), findsOneWidget);
    expect(find.text('raw-id-fallback'), findsOneWidget);
  });

  testWidgets('非空会话装载历史中显示加载态,不闪空白会话 UI;blank 会话仍显空态',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.loadGate = Completer<void>(); // 先装闸门:构造器即自动选中并拉历史
    sessions.emit([
      _summary('s1'), // 非空会话(blank: false),历史装载挂起
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(MaterialApp(home: ChatScreen(vm: vm)));
    await tester.pump();

    // 自动选中首个会话 → 历史挂起:加载态,而非「准备好开始了吗」。
    expect(vm.selectedId, 's1');
    expect(find.byKey(const ValueKey('history-loading')), findsOneWidget);
    expect(find.text('准备好开始了吗？'), findsNothing);

    // 装载完成(空历史):回到空态 UI(此时是已装载的空,不再误导)。
    sessions.loadGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-loading')), findsNothing);
    expect(find.text('准备好开始了吗？'), findsOneWidget);

    // blank 会话即使装载中也直接空态(它本来就是「新会话」)。
    sessions.emit([
      SessionSummary(
        sessionId: 'b1',
        updatedAt: 1786760000000,
        running: false,
        blank: true,
      ),
    ]);
    sessions.loadGate = Completer<void>();
    vm.select('b1');
    await tester.pump();
    expect(find.byKey(const ValueKey('history-loading')), findsNothing);
    expect(find.text('准备好开始了吗？'), findsOneWidget);
    sessions.loadGate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('blank 会话:仅选中那条可见,行无时间无菜单,标题为「新会话」',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([
      _summary('s1'),
      SessionSummary(
        sessionId: 'b1',
        updatedAt: 1786760000000,
        running: false,
        blank: true,
      ),
      SessionSummary(
        sessionId: 'b2',
        updatedAt: 1786760000000,
        running: false,
        blank: true,
      ),
    ]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      _ws('w1', '空白工作区', ['s1', 'b1', 'b2']),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(vm: vm, workspaces: ws)),
    );
    await tester.pump();

    // 未选中的 blank 会话(b1/b2)按 web sessionVisible 隐藏。
    expect(find.text('s1'), findsOneWidget);
    expect(find.text('新会话'), findsNothing);

    // 选中 b1:仅它作为临时「新会话」行出现,且无操作菜单。
    vm.select('b1');
    await tester.pump();
    expect(find.text('新会话'), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, '新会话'),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );
  });
}
