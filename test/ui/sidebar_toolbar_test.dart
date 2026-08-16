// 侧栏重构验收(用户五诉求):
// 1. 会话默认按最后更新时间倒序(最新在最上面)
// 2. 单列表 / 按工作区分组 两种分组方式(默认按工作区)
// 3. 工具区一行:新会话/搜索/排序方式/分组方式/添加工作区;搜索展开占全行
// 4. 「gen1」表意不明 → ready 态显「已连接」(代际进 tooltip);
//    bolt 技能按钮移除(web 无对应功能,活体 RpcBusinessError)
// 5. 宽屏内容区显式避让系统状态栏(SafeArea top)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
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
  Future<void> loadHistory(String sessionId) async {}
  @override
  Future<void> loadOlder(String sessionId) async {}
  @override
  Future<String> fork(String sessionId, {int? atSeq}) async => 'forked';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 头部动作区只需要 commands 非空(构建期不调用其方法)。
class _FakeCommands implements CommandStoreView {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

WorkspaceView _ws(String id, String title, List<String> sessionIds) =>
    WorkspaceView(
      workspaceId: id,
      path: '/tmp/' + id,
      title: title,
      sessionIds: sessionIds,
      createdAt: '2026-08-15T00:00:00Z',
      updatedAt: '2026-08-15T00:00:00Z',
    );

SessionSummary _summary(String id, {double updatedAt = 1786760000000}) =>
    SessionSummary(
      sessionId: id,
      updatedAt: updatedAt,
      running: false,
      blank: false,
    );

Future<ChatViewModel> _pumpWide(
  WidgetTester tester, {
  required _FakeSessionView sessions,
  required _FakeWorkspaceStore ws,
  ChatScreen Function(ChatViewModel vm)? build,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final vm = ChatViewModel(store: sessions, connection: null);
  await tester.pumpWidget(
    MaterialApp(
      home: (build ?? (v) => ChatScreen(vm: v, workspaces: ws))(vm),
    ),
  );
  await tester.pump();
  return vm;
}

/// 侧栏内查找(组头/会话行):composer 工作区 chip 与宽屏 pane 标题会
/// 让裸 find.text 命中多份,断言与 tap 都必须限定在侧栏 pane 内。
Finder _inSidebar(String text) => find.descendant(
      of: find.byKey(const ValueKey('wide-sidebar-pane')),
      matching: find.text(text),
    );

void main() {
  testWidgets('默认排序:会话按最后更新时间倒序(最新在最上面)', (tester) async {
    final sessions = _FakeSessionView();
    // 注册表顺序 older 在前;updatedAt 上 newer 更新 —— 默认视图必须 newer 在上。
    sessions.emit([
      _summary('older', updatedAt: 1786750000000),
      _summary('newer', updatedAt: 1786760000000),
    ]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '排序工作区', ['older', 'newer'])]);

    await _pumpWide(tester, sessions: sessions, ws: ws);

    expect(find.text('排序工作区'), findsOneWidget,
        reason: '仅侧栏组头;非 blank 会话 composer chip 隐藏(用户诉求)');
    expect(
      tester.getTopLeft(_inSidebar('newer')).dy,
      lessThan(tester.getTopLeft(_inSidebar('older')).dy),
      reason: '默认「最近更新」模式:最新会话应排在最上面',
    );
  });

  testWidgets('排序方式:切「手动排序」保留注册表顺序,可切回最近更新',
      (tester) async {
    final sessions = _FakeSessionView();
    sessions.emit([
      _summary('older', updatedAt: 1786750000000),
      _summary('newer', updatedAt: 1786760000000),
    ]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '排序工作区', ['older', 'newer'])]);

    await _pumpWide(tester, sessions: sessions, ws: ws);

    // 默认 updated:newer 在上;切手动 → 注册表顺序 older 在上。
    await tester.tap(find.byTooltip('排序方式:最近更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动排序'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_inSidebar('older')).dy,
      lessThan(tester.getTopLeft(_inSidebar('newer')).dy),
      reason: '手动排序 = web manual 模式:保持注册表(workspace)顺序',
    );

    // 切回最近更新。
    await tester.tap(find.byTooltip('排序方式:手动排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近更新'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_inSidebar('newer')).dy,
      lessThan(tester.getTopLeft(_inSidebar('older')).dy),
    );
  });

  testWidgets('分组方式:单列表隐藏组头,切回「按工作区」还原分组',
      (tester) async {
    final sessions = _FakeSessionView();
    sessions.emit([
      _summary('s1', updatedAt: 1786760000000),
      _summary('s2', updatedAt: 1786750000000),
    ]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '分组工作区', ['s1', 's2'])]);

    await _pumpWide(tester, sessions: sessions, ws: ws);
    expect(_inSidebar('分组工作区'), findsOneWidget);

    // 切单列表:无组头(web flat:无父级层级),会话行仍在
    // (composer chip 不受分组方式影响,仍显示工作区名)。
    await tester.tap(find.byTooltip('分组方式:按工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('单列表'));
    await tester.pumpAndSettle();
    expect(_inSidebar('分组工作区'), findsNothing);
    expect(_inSidebar('s1'), findsOneWidget);
    expect(_inSidebar('s2'), findsOneWidget);

    // 切回按工作区:组头还原。
    await tester.tap(find.byTooltip('分组方式:单列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按工作区'));
    await tester.pumpAndSettle();
    expect(_inSidebar('分组工作区'), findsOneWidget);
  });

  testWidgets('工具区:搜索展开占全行,过滤生效,关闭还原按钮行', (tester) async {
    final sessions = _FakeSessionView();
    sessions.emit([
      _summary('s1', updatedAt: 1786760000000),
      _summary('s2', updatedAt: 1786750000000),
    ]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '搜索工作区', ['s1', 's2'])]);

    await _pumpWide(tester, sessions: sessions, ws: ws);

    // 收起态:工具按钮同一行(注:「新建会话」tooltip 在折叠轨道里
    // 还有一份常驻隐形实例,故以搜索/排序/分组按钮断言)。
    expect(find.byTooltip('搜索会话或工作区'), findsOneWidget);
    expect(find.byTooltip('排序方式:最近更新'), findsOneWidget);
    expect(find.byTooltip('分组方式:按工作区'), findsOneWidget);

    // 展开:输入框占全行,其余工具按钮让位(底部 composer 的输入框
    // 不算 —— 侧栏内唯一 TextField)。
    await tester.tap(find.byTooltip('搜索会话或工作区'));
    await tester.pump();
    final searchField = find.descendant(
      of: find.byKey(const ValueKey('wide-sidebar-pane')),
      matching: find.byType(TextField),
    );
    expect(searchField, findsOneWidget);
    expect(find.text('搜索会话或工作区'), findsOneWidget); // hintText
    expect(find.byTooltip('排序方式:最近更新'), findsNothing);
    expect(find.byTooltip('分组方式:按工作区'), findsNothing);
    expect(find.byTooltip('搜索会话或工作区'), findsNothing);

    // 输入过滤:仅命中会话可见(搜索框自身内容不算,看会话行)。
    await tester.enterText(searchField, 's1');
    await tester.pump();
    expect(find.widgetWithText(ListTile, 's1'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 's2'), findsNothing);

    // 关闭:清词收起,工具按钮还原。
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pump();
    expect(find.byTooltip('搜索会话或工作区'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 's2'), findsOneWidget);
  });

  testWidgets('连接徽标:移入头部行,无 gen 文案,bolt 技能按钮已移除',
      (tester) async {
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '徽标工作区', ['s1'])]);

    await _pumpWide(tester, sessions: sessions, ws: ws);

    // 无连接注入 → 默认 connecting:徽标显「连接中」且在头部行内
    // (y 与品牌标题同域,而非原 gen1 独占的第二行)。
    final badgeTop = tester.getTopLeft(find.text('连接中')).dy;
    final brandTop = tester.getTopLeft(find.text('DshAPP')).dy;
    expect(badgeTop - brandTop, lessThan(24),
        reason: '徽标应与品牌同行(原 gen1 徽标独占一行浪费空间)');
    expect(find.textContaining(RegExp('gen')), findsNothing,
        reason: '「gen1」表意不明,不再渲染代际文案(ready 态改显「已连接」,代际进 tooltip)');
    expect(find.byIcon(Icons.bolt), findsNothing,
        reason: '侧栏技能按钮点击即 RpcBusinessError 且 web 无此功能,已移除');
  });

  testWidgets('宽屏:内容区避让系统状态栏(SafeArea top)', (tester) async {
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '状态栏工作区', ['s1'])]);

    await _pumpWide(
      tester,
      sessions: sessions,
      ws: ws,
      build: (vm) =>
          ChatScreen(vm: vm, workspaces: ws, commands: _FakeCommands()),
    );
    await tester.pump();

    // 标题栏锚点(pane-title key):「对话工作台」文案行已移除,标题栏
    // 显示当前选中会话标题(s1 被自动选中)。
    expect(find.text('对话工作台'), findsNothing);
    final title = find.byKey(const ValueKey('pane-title'));
    expect(title, findsOneWidget);
    // 无状态栏 inset:页头贴顶。
    expect(tester.getTopLeft(title).dy, lessThan(20));

    // 模拟状态栏 44dp:页头必须整体下移避让(修复前直接顶进状态栏)。
    // 注:TestFlutterView.padding 是物理像素,按 dpr=1 直读逻辑值。
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.devicePixelRatio = 3.0);
    tester.view.padding = FakeViewPadding(top: 44);
    addTearDown(() => tester.view.padding = FakeViewPadding.zero);
    await tester.pump();
    expect(
      tester.getTopLeft(title).dy,
      greaterThanOrEqualTo(44),
    );
  });
}
