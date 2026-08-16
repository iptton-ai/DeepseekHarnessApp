// 宽屏折叠轨道可见性回归(用户实报:宽屏收起后只见 56dp 空条,
// 竖排四按钮 —— 展开/新建会话/新建工作区/设置 —— 不显示)。
// 与既有「56dp 往返」用例的差异:全量注入(对齐 main.dart 真机形态,
// settings/scope/directory/commands 都在),并在收起后逐按钮断言:
//   ① 存在且位于 56dp 轨道几何范围内;
//   ② 所在子树的 AnimatedOpacity 已收敛到 1.0(真的画出来了,而非仅
//      容器宽度变 56),同时展开态内容 opacity 收敛到 0;
//   ③ 轨道「新建会话」点按仍继承当前选中会话的工作区(w1)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/sessions/directory_store.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/session_store.dart';
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

class _FakeCommands implements CommandStoreView {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 目录浏览器假实现(轨道「新建工作区」渲染门控要求 directory 非空;
/// 构建期不调用其方法,真机由 main.dart 注入 DirectoryBrowserStore)。
class _FakeDirectory implements DirectoryBrowserView {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 空目录假 settings store(设置入口渲染不依赖特权数据)。
class _FakeSettingsStore implements SettingsStoreView {
  final _ctrl = StreamController<SettingsSnapshot>.broadcast();

  @override
  Stream<SettingsSnapshot> get snapshots => _ctrl.stream;

  @override
  SettingsSnapshot get current => SettingsSnapshot.empty;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SessionSummary _summary(String id) => SessionSummary(
  sessionId: id,
  updatedAt: 1786760000000,
  running: false,
  blank: false,
);

/// 轨道里某 tooltip 按钮所在 AnimatedOpacity 子树的当前不透明度。
double _opacityOf(WidgetTester tester, Finder tooltip) {
  final ro = tester.renderObject<RenderAnimatedOpacity>(
    find.ancestor(of: tooltip, matching: find.byType(AnimatedOpacity)),
  );
  return ro.opacity.value;
}

void main() {
  testWidgets('宽屏收起:轨道四按钮全部渲染可见,不只是宽度变 56dp', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    final ws = _FakeWorkspaceStore();
    ws.emit([
      WorkspaceView(
        workspaceId: 'w1',
        path: '/tmp/w1',
        title: '轨道工作区',
        sessionIds: const ['s1'],
        createdAt: '2026-08-14T00:00:00Z',
        updatedAt: '2026-08-14T00:00:00Z',
      ),
    ]);
    final vm = ChatViewModel(store: sessions, connection: null);

    final created = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          vm: vm,
          workspaces: ws,
          settings: _FakeSettingsStore(),
          scope: scopeFor(Uri.parse('http://192.168.1.5:3080')),
          commands: _FakeCommands(),
          directory: _FakeDirectory(),
          onNewSession: (workspaceId) => created.add(workspaceId),
        ),
      ),
    );
    await tester.pump();

    final pane = find.byKey(const ValueKey('wide-sidebar-pane'));
    expect(tester.getSize(pane).width, 292);

    // 收起:侧栏头部 ⟨⟨| 按钮。
    await tester.tap(find.byIcon(Icons.keyboard_double_arrow_left));
    await tester.pumpAndSettle();
    expect(tester.getSize(pane).width, 56);

    // ① 四按钮存在,且都画在 56dp 轨道几何范围内。
    final expand = find.byTooltip('展开侧栏');
    final newSession = find.byTooltip('新建会话(当前工作区)');
    final newWorkspace = find.byTooltip('新建工作区');
    final settings = find.byTooltip('设置');
    for (final f in [expand, newSession, newWorkspace, settings]) {
      expect(f, findsOneWidget);
      final tl = tester.getTopLeft(f);
      expect(tl.dx, greaterThanOrEqualTo(0), reason: '不越出轨道左缘');
      expect(tl.dx, lessThan(56), reason: '在 56dp 轨道内');
      expect(tester.getTopLeft(f).dy, greaterThan(0));
    }

    // ② 轨道子树 opacity 收敛到 1(真可见);展开态品牌字标收敛到 0。
    for (final f in [expand, newSession, newWorkspace, settings]) {
      expect(_opacityOf(tester, f), 1.0, reason: '轨道按钮必须完全不透明');
    }
    expect(
      _opacityOf(tester, find.text('DshAPP')),
      0.0,
      reason: '展开态内容应收起为不可见',
    );

    // ③ 轨道「新建会话」继承当前选中会话的工作区(s1 ∈ w1)。
    await tester.tap(newSession);
    await tester.pump();
    expect(created, ['w1']);

    // 还原:轨道展开按钮。
    await tester.tap(expand);
    await tester.pumpAndSettle();
    expect(tester.getSize(pane).width, 292);
  });
}
