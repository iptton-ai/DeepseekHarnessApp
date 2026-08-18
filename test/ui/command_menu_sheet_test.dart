// CommandMenuSheet widget 测试(W2-D):分组渲染、搜索过滤、点击回调拼 '/name'、
// 降级重试、空目录提示;360dp 窄屏,行高 ≥48。
// 模式:假 CommandStoreView(不碰 socket/HTTP)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/ui/command_menu_sheet.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 假 CommandStoreView:常驻 menu + 可选 sequence(按序弹出,重试用)+ force 记录。
class _FakeCommandStore implements CommandStoreView {
  CommandMenu? menu;
  final List<CommandMenu> sequence = <CommandMenu>[];
  final List<bool> forces = <bool>[];
  Object? error;

  @override
  Future<CommandMenu> listAll(String sessionId, {bool force = false}) async {
    forces.add(force);
    if (error != null) throw error!;
    if (sequence.isNotEmpty) return sequence.removeAt(0);
    return menu ?? _menu(const <CommandEntry>[], const <SkillEntry>[]);
  }

  @override
  Future<CommandListResult> listCommands(String sessionId,
      {bool force = false}) async {
    return CommandListResult.ok(const <CommandEntry>[]);
  }

  @override
  Future<void> execute(String sessionId, String line) async {}
}

CommandMenu _menu(List<CommandEntry> commands, List<SkillEntry> skills) =>
    CommandMenu(
      commands: <CommandMenuItem>[
        for (final c in commands) CommandMenuItem.command(c),
      ],
      skills: <CommandMenuItem>[
        for (final s in skills) CommandMenuItem.skill(s),
      ],
      degraded: false,
    );

CommandMenu _degraded(List<SkillEntry> skills,
        {String code = 'agent-busy'}) =>
    CommandMenu(
      commands: const <CommandMenuItem>[],
      skills: <CommandMenuItem>[
        for (final s in skills) CommandMenuItem.skill(s),
      ],
      degraded: true,
      errorCode: code,
      errorMessage: 'use subagent delivery',
    );

CommandEntry _cmd(String name, String description, {String? hint}) =>
    CommandEntry(name: name, description: description, hint: hint);

SkillEntry _skill(String name, String description,
        {bool modelInvocable = true}) =>
    SkillEntry(
        name: name,
        description: description,
        whenToUse: null,
        modelInvocable: modelInvocable);

Future<void> _open(
    WidgetTester tester, _FakeCommandStore store, List<String> picked) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showCommandMenu(
              context,
              sessionId: 'session-s1',
              store: store,
              // onPick 现在给整条 item(command/skill 类型可判);
              // 这里记录派发行文本,与旧契约等价。
              onPick: (item) => picked.add(item.slash),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('360dp:分组渲染(命令组 name+description+input.hint,skill 组现有格式),行高≥48',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final picked = <String>[];
    final store = _FakeCommandStore();
    store.menu = _menu(
      [
        _cmd('compact', '紧凑显示', hint: 'on/off'),
        _cmd('export', '导出会话 ZIP'),
      ],
      [
        _skill('android', 'Android 开发'),
        _skill('game-design', '游戏设计', modelInvocable: false),
      ],
    );
    await _open(tester, store, picked);

    // 搜索框常显 + 分组头。
    expect(find.byKey(const ValueKey('command-menu-search')), findsOneWidget);
    expect(find.text('命令'), findsOneWidget);
    expect(find.text('技能'), findsOneWidget);

    // 命令组:name + description + input.hint(description+hint 合并为副标题)。
    expect(find.text('/compact'), findsOneWidget);
    expect(find.textContaining('紧凑显示'), findsOneWidget);
    expect(find.textContaining('输入: on/off'), findsOneWidget);
    expect(find.text('/export'), findsOneWidget);

    // skill 组:现有格式('/name' + description;不可模型调用 → lock 图标)。
    expect(find.text('/android'), findsOneWidget);
    expect(find.text('Android 开发'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);

    // 行高 ≥48(移动硬性)。
    expect(
        tester.getSize(find.byKey(const ValueKey('command-item-compact'))).height,
        greaterThanOrEqualTo(48));
    expect(
        tester.getSize(find.byKey(const ValueKey('command-item-android'))).height,
        greaterThanOrEqualTo(48));
  });

  testWidgets('360dp:搜索过滤(前缀优先 + 子序列,大小写不敏感)', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final picked = <String>[];
    final store = _FakeCommandStore();
    store.menu = _menu(
      [
        _cmd('compact', '紧凑显示'),
        _cmd('export', '导出会话 ZIP'),
        _cmd('goal', '目标'),
      ],
      const <SkillEntry>[],
    );
    await _open(tester, store, picked);

    // 子序列 'cpa' → 仅 compact。
    await tester.enterText(
        find.byKey(const ValueKey('command-menu-search')), 'cpa');
    await tester.pump();
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/export'), findsNothing);
    expect(find.text('/goal'), findsNothing);

    // 大小写不敏感 'EXP' → export。
    await tester.enterText(
        find.byKey(const ValueKey('command-menu-search')), 'EXP');
    await tester.pump();
    expect(find.text('/export'), findsOneWidget);
    expect(find.text('/compact'), findsNothing);

    // 前缀优先:'co' → compact(前缀)排前;export/goal 无匹配被过滤。
    await tester.enterText(
        find.byKey(const ValueKey('command-menu-search')), 'co');
    await tester.pump();
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/export'), findsNothing);

    // 无匹配 → 空提示。
    await tester.enterText(
        find.byKey(const ValueKey('command-menu-search')), 'zzz');
    await tester.pump();
    expect(find.text('没有匹配项'), findsOneWidget);
  });

  testWidgets("360dp:点击回调拼 '/name',sheet 关闭", (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final picked = <String>[];
    final store = _FakeCommandStore();
    store.menu = _menu(
      [_cmd('compact', '紧凑显示')],
      [_skill('android', 'Android 开发')],
    );
    await _open(tester, store, picked);

    await tester.tap(find.byKey(const ValueKey('command-item-compact')));
    await tester.pumpAndSettle();
    expect(picked, ['/compact']);
    expect(find.text('命令与技能'), findsNothing); // sheet 已关闭

    // 重开 → 点 skill 行 → onPick('/android')。
    await _open(tester, store, picked);
    await tester.tap(find.byKey(const ValueKey('command-item-android')));
    await tester.pumpAndSettle();
    expect(picked, ['/compact', '/android']);
  });

  testWidgets('360dp:命令目录降级(agent-busy)→ 内联提示 + 重试,技能仍可用',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final picked = <String>[];
    final store = _FakeCommandStore();
    // 首次:降级(skill-only);重试(force):成功目录。
    store.sequence.addAll([
      _degraded([_skill('android', 'Android 开发')]),
      _menu([_cmd('compact', '紧凑显示')], const <SkillEntry>[]),
    ]);
    await _open(tester, store, picked);

    // 降级横幅 + 重试按钮;技能组仍在(降级 skill-only)。
    expect(find.byKey(const ValueKey('command-menu-degraded')), findsOneWidget);
    expect(find.textContaining('子代理会话'), findsOneWidget);
    expect(find.byKey(const ValueKey('command-menu-retry')), findsOneWidget);
    expect(find.text('/android'), findsOneWidget);

    // 点重试 → force 重取,成功目录替换降级态。
    await tester.tap(find.byKey(const ValueKey('command-menu-retry')));
    await tester.pumpAndSettle();
    expect(store.forces, [false, true]);
    expect(find.byKey(const ValueKey('command-menu-degraded')), findsNothing);
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('/android'), findsNothing);
  });

  testWidgets('360dp:完全空目录 → 内联空提示,不崩', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final picked = <String>[];
    final store = _FakeCommandStore();
    store.menu = _menu(const <CommandEntry>[], const <SkillEntry>[]);
    await _open(tester, store, picked);

    expect(find.text('没有可用命令或技能'), findsOneWidget);
    expect(find.byKey(const ValueKey('command-menu-search')), findsOneWidget);
  });

  testWidgets('extraItems:客户端 contribution 并入命令组;与宿主目录重名跳过;搜索过滤生效',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final picked = <String>[];
    final store = _FakeCommandStore();
    // 宿主目录已有 export;extra 同时给 model(新增)与 export(重名)。
    store.menu = _menu(
      [_cmd('export', '导出会话 ZIP')],
      const <SkillEntry>[],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showCommandMenu(
                context,
                sessionId: 'session-s1',
                store: store,
                onPick: (item) => picked.add(item.slash),
                extraItems: [
                  CommandMenuItem.command(
                    const CommandEntry(name: 'model', description: '切换模型'),
                  ),
                  CommandMenuItem.command(
                    const CommandEntry(name: 'export', description: '客户端重名项'),
                  ),
                ],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // model 并入命令组;/export 仅宿主一份(重名 extra 跳过,无重复行)。
    expect(find.text('/model'), findsOneWidget);
    expect(find.byKey(const ValueKey('command-item-model')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('command-item-export')), findsOneWidget);
    expect(find.textContaining('客户端重名项'), findsNothing);

    // 搜索过滤对 extra 行同样生效。
    await tester.enterText(
        find.byKey(const ValueKey('command-menu-search')), 'mo');
    await tester.pump();
    expect(find.text('/model'), findsOneWidget);
    expect(find.text('/export'), findsNothing);

    // 点击 extra 行 → onPick('/model')。
    await tester.enterText(
        find.byKey(const ValueKey('command-menu-search')), '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('command-item-model')));
    await tester.pumpAndSettle();
    expect(picked, ['/model']);
  });
}
