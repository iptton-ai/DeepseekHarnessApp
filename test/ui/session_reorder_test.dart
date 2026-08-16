// 手动排序验收(用户诉求:切换到手动排序时,会话支持长按拖拽重排;
// 按工作区分组时会话只能移到本工作区范围内)。
//
// 复刻 web 语义:
// - 分组模式:拖拽落盘 workspace.insertSessionBefore(wsId, sessionId,
//   beforeSessionId?);跨组目标直接拒绝(host 会抛 not accounted)。
// - 未分组('')与单列表(平铺键):纯客户端顺序,不落盘。
// - 最近更新模式:不可拖。
// - anchor 半侧判定:目标行上半 = 插其前,下半 = 插其后(= 下一行之前;
//   末行下半 = 移到末尾,beforeSessionId = null)。
// - no-op 判定:位置未变 / 相邻等价移动直接忽略(web commitSessionDrag)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/ui/workspace_browser.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class _FakeWsStore implements WorkspaceStoreView {
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

WorkspaceView _ws(String id, String title, List<String> sessionIds) =>
    WorkspaceView(
      workspaceId: id,
      path: '/tmp/' + id,
      title: title,
      sessionIds: sessionIds,
      createdAt: '2026-08-15T00:00:00Z',
      updatedAt: '2026-08-15T00:00:00Z',
    );

SessionSummary _s(String id, {double updatedAt = 1786760000000}) =>
    SessionSummary(
      sessionId: id,
      updatedAt: updatedAt,
      running: false,
      blank: false,
    );

/// 行查找器:文字所在的整行(ListTile)。
Finder _rowOf(Finder text) =>
    find.ancestor(of: text, matching: find.byType(ListTile)).first;

/// 拖一行到另一行的指定半侧(before = 上半,after = 下半)。
/// 长按 420ms 超过 360ms 阈值拖起;分步移动给 DragTarget 悬停帧;
/// 起点与半侧都按整行(ListTile)矩形算 —— 文字矩形只是行内一小段。
Future<void> _drag(
  WidgetTester tester, {
  required Finder from,
  required Finder to,
  bool toBottomHalf = false,
}) async {
  final start = tester.getCenter(_rowOf(from));
  final g = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 420));
  await g.moveBy(const Offset(0, 6));
  await tester.pump();
  final rect = tester.getRect(_rowOf(to));
  final target = toBottomHalf
      ? Offset(rect.center.dx, rect.bottom - rect.height * .25)
      : Offset(rect.center.dx, rect.top + rect.height * .25);
  // 分多步移动,确保途经行的 DragTarget onLeave 与目标行 onHover 都触发。
  final steps = 6;
  for (var i = 1; i <= steps; i++) {
    await g.moveTo(
      Offset.lerp(start + const Offset(0, 6), target, i / steps)!,
    );
    await tester.pump();
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  late _FakeWsStore ws;
  final reorders = <(String, String, String?)>[];
  final newSessions = <String?>[];
  late StreamController<List<SessionSummary>> sessionCtrl;

  Future<void> pump(
    WidgetTester tester, {
    required List<SessionSummary> sessions,
    WorkspaceGroupMode groupMode = WorkspaceGroupMode.workspace,
    WorkspaceOrderMode orderMode = WorkspaceOrderMode.manual,
  }) async {
    sessionCtrl = StreamController<List<SessionSummary>>.broadcast();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceBrowser(
            store: ws,
            sessionStream: sessionCtrl.stream,
            initialSessions: sessions,
            groupMode: groupMode,
            orderMode: orderMode,
            callbacks: WorkspaceBrowserCallbacks(
              onSelectSession: (_) {},
              onNewSession: (wsId) => newSessions.add(wsId),
              onReorderSession: (wsId, sessionId, before) async {
                reorders.add((wsId, sessionId, before));
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  setUp(() {
    ws = _FakeWsStore();
    reorders.clear();
    newSessions.clear();
  });

  testWidgets('分组手动排序:长按拖到末行下半 → 移到组尾,落盘 anchor=null',
      (tester) async {
    ws.emit([_ws('w1', '工作区一', ['s1', 's2', 's3'])]);
    await pump(tester, sessions: [_s('s1'), _s('s2'), _s('s3')]);

    // 初始:注册表顺序 s1 s2 s3。
    expect(tester.getTopLeft(find.text('s1')).dy,
        lessThan(tester.getTopLeft(find.text('s3')).dy));

    await _drag(tester, from: find.text('s1'), to: find.text('s3'),
        toBottomHalf: true);

    // 顺序翻转为 s2 s3 s1,远端收到 insertSessionBefore(w1, s1, null)。
    expect(tester.getTopLeft(find.text('s3')).dy,
        lessThan(tester.getTopLeft(find.text('s1')).dy));
    expect(reorders, [('w1', 's1', null)]);
  });

  testWidgets('分组手动排序:拖到目标行上半 → 插到目标之前(anchor=目标)',
      (tester) async {
    ws.emit([_ws('w1', '工作区一', ['s1', 's2', 's3'])]);
    await pump(tester, sessions: [_s('s1'), _s('s2'), _s('s3')]);

    await _drag(tester, from: find.text('s1'), to: find.text('s3'));

    // s1 插到 s3 之前:s2 s1 s3。
    expect(tester.getTopLeft(find.text('s2')).dy,
        lessThan(tester.getTopLeft(find.text('s1')).dy));
    expect(tester.getTopLeft(find.text('s1')).dy,
        lessThan(tester.getTopLeft(find.text('s3')).dy));
    expect(reorders, [('w1', 's1', 's3')]);
  });

  testWidgets('跨组拖拽被拒绝:会话只能移到本工作区范围内', (tester) async {
    ws.emit([
      _ws('w1', '工作区一', ['a1']),
      _ws('w2', '工作区二', ['b1']),
    ]);
    await pump(tester, sessions: [_s('a1'), _s('b1')]);

    await _drag(tester, from: find.text('a1'), to: find.text('b1'));

    // 无落盘调用,顺序保持原样(a1 仍在工作区一)。
    expect(reorders, isEmpty);
    expect(tester.getTopLeft(find.text('a1')).dy,
        lessThan(tester.getTopLeft(find.text('b1')).dy));
  });

  testWidgets('相邻等价移动为 no-op:不下发落盘调用', (tester) async {
    ws.emit([_ws('w1', '工作区一', ['s1', 's2', 's3'])]);
    await pump(tester, sessions: [_s('s1'), _s('s2'), _s('s3')]);

    // s1 拖到 s2 上半 = 插到 s2 之前 = 原位置(web anchorIndex==sourceIndex+1
    // 直接忽略;也覆盖 anchor==sessionId 分支等价)。
    await _drag(tester, from: find.text('s1'), to: find.text('s2'));

    expect(reorders, isEmpty);
    expect(tester.getTopLeft(find.text('s1')).dy,
        lessThan(tester.getTopLeft(find.text('s2')).dy));
  });

  testWidgets('单列表:拖拽仅本地生效,不下发落盘(web FLAT 同款)',
      (tester) async {
    ws.emit([_ws('w1', '工作区一', ['s1', 's2'])]);
    await pump(
      tester,
      sessions: [_s('s1'), _s('s2')],
      groupMode: WorkspaceGroupMode.flat,
    );

    await _drag(tester, from: find.text('s1'), to: find.text('s2'),
        toBottomHalf: true);

    expect(tester.getTopLeft(find.text('s2')).dy,
        lessThan(tester.getTopLeft(find.text('s1')).dy));
    expect(reorders, isEmpty, reason: '单列表顺序纯客户端,不落盘');
  });

  testWidgets('最近更新模式:不可拖拽(无 LongPressDraggable)', (tester) async {
    ws.emit([_ws('w1', '工作区一', ['s1', 's2'])]);
    await pump(
      tester,
      sessions: [_s('s1'), _s('s2')],
      orderMode: WorkspaceOrderMode.updated,
    );
    expect(find.byType(LongPressDraggable<SessionDragPayload>), findsNothing);
  });

  testWidgets('落盘后被 host 广播的新注册表顺序收敛', (tester) async {
    ws.emit([_ws('w1', '工作区一', ['s1', 's2', 's3'])]);
    await pump(tester, sessions: [_s('s1'), _s('s2'), _s('s3')]);

    // 服务端确认后的权威顺序(w1: s2 s3 s1)经广播到达。
    // 广播流事件经 microtask + 下一帧落地,需两帧 pump。
    ws.emit([_ws('w1', '工作区一', ['s2', 's3', 's1'])]);
    await tester.pump();
    await tester.pump();

    expect(tester.getTopLeft(find.text('s2')).dy,
        lessThan(tester.getTopLeft(find.text('s3')).dy));
    expect(tester.getTopLeft(find.text('s3')).dy,
        lessThan(tester.getTopLeft(find.text('s1')).dy));
  });

  testWidgets('组头常显「+」:点击在本组新建;未分组桶为 null', (tester) async {
    ws.emit([_ws('w1', '工作区一', ['s1'])]);
    await pump(tester, sessions: [_s('s1'), _s('u1')]);

    // 组头 + (web ProjectRowItem onCreate 同构)。
    await tester.tap(find.byTooltip('在本组新建会话').first);
    await tester.pump();
    expect(newSessions, ['w1']);

    // 未分组桶组头同样有 + → null(继承当前工作区语义)。
    await tester.tap(find.byTooltip('在本组新建会话').last);
    await tester.pump();
    expect(newSessions, ['w1', null]);
  });

  test('reconcileSessionOrder:stored 优先,新会话补尾,去重',
      () {
    final rows = [_s('a'), _s('b'), _s('c'), _s('new')];
    final out = reconcileSessionOrder(rows, ['c', 'b', 'zz-gone', 'a']);
    expect(out.map((s) => s.sessionId).toList(), ['c', 'b', 'a', 'new']);
  });
}
