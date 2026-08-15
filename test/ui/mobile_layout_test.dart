// W1 集成验收:窄屏(<600dp)抽屉形态 + workspace 分组在抽屉内可见。
// 移动可用性硬性验收(PLAN「W1 集成规格」第 4/5 条)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/connection_controller.dart';
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
  int loadCalls = 0;

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
  }
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

void main() {
  testWidgets('窄屏(<600dp):侧栏进抽屉,打开后 workspace 分组可见', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '我的工作区', ['s1'])]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(vm: vm, workspaces: ws),
    ));
    await tester.pump();

    // 窄屏:消息 pane 直接可见,菜单按钮存在;workspace 分组不直接渲染(在抽屉里)。
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.text('我的工作区'), findsNothing);

    // 打开抽屉:分组出现。
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('我的工作区'), findsOneWidget);
  });

  testWidgets('宽屏(≥600dp):侧栏常驻,workspace 分组直接可见', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([_ws('w1', '宽屏工作区', ['s1'])]);
    final vm = ChatViewModel(store: sessions, connection: null);

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(vm: vm, workspaces: ws),
    ));
    await tester.pump();

    expect(find.byIcon(Icons.menu), findsNothing);
    expect(find.text('宽屏工作区'), findsOneWidget);
  });
}
