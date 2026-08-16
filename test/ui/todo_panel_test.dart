// 本轮验收:轨道栏竖排四动作(新建会话带当前工作区)+ 任务清单面板
// (todo/write 投影,web TodoDock 复刻)。composer 聚焦隐藏停止的用例
// 在 composer_pro_test.dart。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/directory_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/todo_panel.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class _FakeWorkspaceStore implements WorkspaceStoreView {
  final _ctrl = StreamController<List<WorkspaceView>>.broadcast();
  final _archivedCtrl = StreamController<List<String>>.broadcast();
  List<WorkspaceView> _items = const [];

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
  List<String> get currentArchivedSessionIds => const [];
  @override
  bool isArchived(String sessionId) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 可注入日志事件的假会话视图(事件经 SessionLog.append 广播)。
class _FakeSessionView implements SessionStoreView {
  final _ctrl = StreamController<List<SessionSummary>>.broadcast();
  final logs = <String, SessionLog>{};
  List<SessionSummary> _current = const [];

  void emit(List<SessionSummary> list) {
    _current = list;
    _ctrl.add(list);
  }

  SessionLog logEdit(String id) =>
      logs.putIfAbsent(id, () => SessionLog(id));

  @override
  Stream<List<SessionSummary>> get summaries => _ctrl.stream;
  @override
  List<SessionSummary> get currentSummaries => _current;
  @override
  SessionLog logFor(String sessionId) => logEdit(sessionId);
  @override
  Future<void> loadHistory(String sessionId) async {}
  @override
  Future<void> loadOlder(String sessionId) async {}
  @override
  Future<String> fork(String sessionId, {int? atSeq}) async => 'forked';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 轨道「新建工作区」只要求 directory 非空(点击才真正用到流)。
class _FakeDirectoryView implements DirectoryBrowserView {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 空目录假 settings store(设置入口渲染不依赖特权数据)。
class _FakeSettingsStore implements SettingsStoreView {
  @override
  Stream<SettingsSnapshot> get snapshots => const Stream.empty();
  @override
  SettingsSnapshot get current => SettingsSnapshot.empty;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SessionEvent _ev(int seq, String type, [Map<String, dynamic>? data]) =>
    SessionEvent(type: type, seq: seq, time: seq.toDouble(), data: data ?? {});

SessionSummary _summary(String id) => SessionSummary(
      sessionId: id,
      updatedAt: 1786760000000,
      running: false,
      blank: false,
    );

WorkspaceView _ws(String id, String title, List<String> sessionIds) =>
    WorkspaceView(
      workspaceId: id,
      path: '/tmp/' + id,
      title: title,
      sessionIds: sessionIds,
      createdAt: '2026-08-15T00:00:00Z',
      updatedAt: '2026-08-15T00:00:00Z',
    );

void main() {
  testWidgets('轨道栏竖排:展开/新建会话/新建工作区;新建会话带当前工作区',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '轨道分组', ['s1'])]);
    final vm = ChatViewModel(store: sessions, connection: null);

    final created = <String?>[];
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        vm: vm,
        workspaces: ws,
        directory: _FakeDirectoryView(),
        settings: _FakeSettingsStore(),
        scope: scopeFor(Uri.parse('http://127.0.0.1:3080')),
        onNewSession: created.add,
      ),
    ));
    await tester.pump();

    // 收起侧栏 → 56dp 轨道。
    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
    await tester.pumpAndSettle();

    // 轨道竖排四动作:展开 + 新建会话 + 新建工作区 + 底部设置。
    // (展开态侧栏仍在树中只是淡出,Icon 查找会撞双份,按 tooltip 定位。)
    expect(find.byIcon(Icons.keyboard_double_arrow_right), findsOneWidget);
    expect(find.byTooltip('新建会话(当前工作区)'), findsOneWidget);
    expect(find.byTooltip('新建工作区'), findsOneWidget);
    // 设置图标:展开态侧栏(已淡出仍在树中)+ 轨道各一份,取轨道内
    // (最左 56dp 区域)那份验证。
    final settingsIcons = find.byIcon(Icons.settings_outlined);
    expect(settingsIcons, findsWidgets);
    expect(tester.getTopLeft(settingsIcons.last).dx, lessThan(56));

    // 轨道「+」在当前选中会话(s1)的工作区 w1 新建。
    await tester.tap(find.byTooltip('新建会话(当前工作区)'));
    await tester.pump();
    expect(created, ['w1']);

    // 展开按钮还原 292dp 侧栏。
    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_right));
    await tester.pumpAndSettle();
    expect(find.text('轨道分组'), findsOneWidget,
        reason: '仅侧栏组头;非 blank 会话 composer chip 隐藏(用户诉求)');
  });

  testWidgets('轨道「+」按下即打开新会话(main onNewSession 语义:创建后 select)',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '轨道分组', ['s1'])]);
    final vm = ChatViewModel(store: sessions, connection: null);

    // 复刻 main.dart 的 onNewSession:创建(假)→ 摘要落地 → vm.select。
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        vm: vm,
        workspaces: ws,
        directory: _FakeDirectoryView(),
        settings: _FakeSettingsStore(),
        scope: scopeFor(Uri.parse('http://127.0.0.1:3080')),
        onNewSession: (workspaceId) async {
          sessions.emit([
            ...sessions.currentSummaries,
            SessionSummary(
              sessionId: 'brand-new',
              updatedAt: 1786760000001,
              running: false,
              blank: true,
            ),
          ]);
          ws.emit([_ws('w1', '轨道分组', ['s1', 'brand-new'])]);
          vm.select('brand-new');
        },
      ),
    ));
    await tester.pump();

    // 收起 → 按轨道「+」→ 新会话被选中打开:blank 空态可见(而非停在
    // 旧会话),侧栏出现「新会话」行。
    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建会话(当前工作区)'));
    await tester.pump();
    await tester.pump();
    expect(find.text('准备好开始了吗？'), findsOneWidget,
        reason: '按下「+」必须切到新会话的空态(此前只创建不打开,毫无反馈)');
    expect(find.text('新会话'), findsOneWidget);
  });

  test('backscanSessionTodos:最后 todo/write 生效;新一轮 turn/start 退役', () {
    final events = <SessionEvent>[
      _ev(1, 'turn/start'),
      _ev(2, 'todo/write', {
        'todos': [
          {'content': '调研', 'status': 'completed'},
          {'content': '实现', 'status': 'in_progress'},
          {'content': '验收', 'status': 'pending'},
        ]
      }),
    ];
    final todos = backscanSessionTodos(events);
    expect(todos.length, 3);
    expect(todos[0].completed, isTrue);
    expect(todos[1].inProgress, isTrue);
    expect(todoProgressLabel(todos), '1 已完成 · 1 进行中 · 1 待处理');

    // 快照更新:第二条 todo/write 覆盖第一条。
    events.add(_ev(3, 'todo/write', {
      'todos': [
        {'content': '全部完成', 'status': 'completed'},
      ]
    }));
    final updated = backscanSessionTodos(events);
    expect(updated.length, 1);
    expect(todoProgressLabel(updated), '1 已完成');

    // 新一轮开始:上一轮清单退役(web:新 turn/start 触发 todos=null)。
    events.add(_ev(4, 'turn/start'));
    expect(backscanSessionTodos(events), isEmpty);
  });

  testWidgets('TodoPanel:默认折叠显进度摘要,展开逐项渲染;空清单不渲染',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '任务工作区', ['s1'])]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(
      MaterialApp(home: ChatScreen(vm: vm, workspaces: ws)),
    );
    await tester.pump();

    // 无 todo/write:面板不渲染。
    expect(find.byKey(const ValueKey('todo-panel')), findsNothing);

    // 当前轮写入任务清单(选中会话 s1 的日志)。
    sessions.logEdit('s1').append(_ev(11, 'todo/write', {
      'todos': [
        {'content': '调研侧栏', 'status': 'completed'},
        {'content': '实现面板', 'status': 'in_progress'},
        {'content': '补测试', 'status': 'pending'},
      ]
    }));
    await tester.pump();

    // 默认折叠:头行 = 任务 + 进度摘要;条目不显示。
    expect(find.byKey(const ValueKey('todo-panel')), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.text('1 已完成 · 1 进行中 · 1 待处理'), findsOneWidget);
    expect(find.text('调研侧栏'), findsNothing);

    // 展开:逐项渲染(completed 打勾删除线,pending 虚线环)。
    await tester.tap(find.text('任务'));
    await tester.pump();
    expect(find.text('调研侧栏'), findsOneWidget);
    expect(find.text('实现面板'), findsOneWidget);
    expect(find.text('补测试'), findsOneWidget);

    // 新一轮开始:清单退役,面板消失。
    sessions.logEdit('s1').append(_ev(12, 'turn/start'));
    await tester.pump();
    expect(find.byKey(const ValueKey('todo-panel')), findsNothing);
  });
}
