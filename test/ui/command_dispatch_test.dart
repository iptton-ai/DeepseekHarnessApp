// 命令与技能菜单分发验收(ChatScreen 级,web ui-commands dispatch + ui-skill
// onPick 对齐):
// - skill → 回填 '/name ' 到输入框,不直接发送;
// - leadingInput 命令(goal 等 input.hint)→ 回填 '/name ';
// - 裸命令(compact)→ 立即 commands/execute;export 成功追加导出回调;
// - model contribution 行(actions.onPickModel 注入才有)→ 打开模型选择器;
// - permission 装饰命令 → 权限预设表(选中即 '/permission <preset>');
// - 提交斜杠仲裁:首 token 命中宿主目录 → execute;否则 prompt;
//   目录降级(非 agent-busy)→ 内联错误 + 输入保留;agent-busy → 走 prompt。
// 模式:假 CommandStoreView + ChatSenderBinding 记录 prompt(不碰 socket/HTTP)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 假命令目录:固定目录(compact/export 裸;goal/permission/plan 带 hint)+
/// 可切降级态;execute/listAll/listCommands 记录调用。
class _FakeDispatchCommands implements CommandStoreView {
  _FakeDispatchCommands() : _directory = _fullDirectory();

  final List<CommandEntry> _directory;
  CommandListResult? listResultOverride;

  final executed = <String>[];
  final listed = <String>[];

  void degrade({required String code}) {
    listResultOverride = CommandListResult.degraded(CommandListError(code, null));
  }

  void restore() => listResultOverride = null;

  static List<CommandEntry> _fullDirectory() => const [
        CommandEntry(name: 'compact', description: '压缩历史'),
        CommandEntry(name: 'export', description: '导出会话 ZIP'),
        CommandEntry(name: 'goal', description: '目标', hint: '[<objective>]'),
        CommandEntry(
            name: 'permission', description: '权限', hint: '<preset>'),
        CommandEntry(name: 'plan', description: '计划', hint: '[off|message]'),
      ];

  @override
  Future<CommandListResult> listCommands(String sessionId,
      {bool force = false}) async {
    listed.add(sessionId);
    return listResultOverride ??
        CommandListResult.ok(List<CommandEntry>.of(_directory));
  }

  @override
  Future<CommandMenu> listAll(String sessionId, {bool force = false}) async {
    final result = await listCommands(sessionId, force: force);
    return CommandMenu(
      commands: [
        for (final c in result.commands) CommandMenuItem.command(c),
      ],
      skills: [
        CommandMenuItem.skill(SkillEntry(
          name: 'skill-x',
          description: '示例技能',
          whenToUse: null,
          modelInvocable: true,
        )),
      ],
      degraded: result.isDegraded,
      errorCode: result.error?.code,
      errorMessage: result.error?.message,
    );
  }

  @override
  Future<void> execute(String sessionId, String line) async {
    // 目录内预校验(镜像真实 store:未知命令本地拒绝)。
    final name = commandNameOf(line);
    if (name == null || !_directory.any((c) => c.name == name)) {
      throw UnknownCommandException(name ?? '');
    }
    executed.add(line);
  }
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SessionSummary _summary(String id) => SessionSummary(
      sessionId: id,
      updatedAt: 1786760000000,
      running: false,
      blank: false,
    );

class _Harness {
  final store = _FakeDispatchCommands();
  final prompts = <String>[];
  final exports = <String>[];
  int modelPicks = 0;
  late final ChatViewModel vm;

  _Harness() {
    final sessions = _FakeSessionView();
    sessions.emit([_summary('s1')]);
    vm = ChatViewModel(store: sessions, connection: null)
      ..phase = ConnectionPhase.ready;
  }

  SessionActions get actions => SessionActions(
        onPickModel: () => modelPicks += 1,
        onExport: exports.add,
      );

  Widget wrap() => MaterialApp(
        home: ChatSenderBinding(
          sender: (sessionId, text) async => prompts.add(text),
          child: ChatScreen(vm: vm, commands: store, actions: actions),
        ),
      );
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('composer-add-command')));
  await tester.pumpAndSettle();
  expect(find.text('命令与技能'), findsOneWidget);
}

String _inputText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const ValueKey('composer-input'))).controller!.text;

Future<void> _send(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('composer-send')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('菜单分发:skill/leadingInput 命令回填输入框;裸命令直接 execute',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.wrap());
    await tester.pump();

    // skill → 回填 '/skill-x ',不发送。(sheet 高度受限,skill 行在虚拟
    // 列表外;搜索过滤让它进入视口。)
    await _openMenu(tester);
    await tester.enterText(
        find.byKey(const ValueKey('command-menu-search')), 'skill');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('command-item-skill-x')));
    await tester.pumpAndSettle();
    expect(_inputText(tester), '/skill-x ');
    expect(h.prompts, isEmpty, reason: 'skill 不直发,发送时走 prompt 仲裁');

    // leadingInput 命令(goal)→ 回填 '/goal '。
    await _openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('command-item-goal')));
    await tester.pumpAndSettle();
    expect(_inputText(tester), '/goal ');

    // 裸命令(compact)→ 立即 execute,不回填、不 prompt。
    await _openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('command-item-compact')));
    await tester.pumpAndSettle();
    expect(h.store.executed, ['/compact']);
    expect(_inputText(tester), '/goal ', reason: '裸命令不触碰输入框');
    expect(h.prompts, isEmpty);
  });

  testWidgets('菜单分发:export 成功后追加导出回调(web 下载后续的 App 等价物)',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.wrap());
    await tester.pump();

    await _openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('command-item-export')));
    await tester.pumpAndSettle();
    expect(h.store.executed, ['/export']);
    expect(h.exports, ['s1']);
  });

  testWidgets('菜单分发:model contribution 行仅在 actions 注入时出现,点击打开模型选择',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.wrap());
    await tester.pump();

    // 未注入 actions → 无 model 行(model 不在宿主目录,web 语义:客户端项)。
    await tester.pumpWidget(MaterialApp(
      home: ChatSenderBinding(
        sender: (sessionId, text) async {},
        child: ChatScreen(vm: h.vm, commands: h.store),
      ),
    ));
    await tester.pump();
    await _openMenu(tester);
    expect(find.byKey(const ValueKey('command-item-model')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('command-menu-close')));
    await tester.pumpAndSettle();

    // 注入 actions → model 行出现,点击回调模型选择。
    await tester.pumpWidget(h.wrap());
    await tester.pump();
    await _openMenu(tester);
    expect(find.byKey(const ValueKey('command-item-model')), findsOneWidget,
        reason: 'onPickModel 注入 → /model contribution 行(web 对齐)');
    await tester.tap(find.byKey(const ValueKey('command-item-model')));
    await tester.pumpAndSettle();
    expect(h.modelPicks, 1);
    expect(h.store.executed, isEmpty, reason: 'model 是客户端项,不走 execute');
  });

  testWidgets('菜单分发:permission 装饰命令打开权限预设表', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.wrap());
    await tester.pump();

    await _openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('command-item-permission')));
    await tester.pumpAndSettle();
    expect(find.text('访问模式'), findsOneWidget, reason: '权限预设表弹出');
    expect(h.store.executed, isEmpty, reason: '选中预设才执行,打开不执行');

    // 选中 workspace-write → execute '/permission workspace-write'。
    // (composer 权限 chip 同名文案,限定 ListTile 即表内行。)
    await tester.tap(find.widgetWithText(ListTile, '工作区可写'));
    await tester.pumpAndSettle();
    expect(h.store.executed, ['/permission workspace-write']);
  });

  testWidgets('提交仲裁:宿主命令行 → execute;skill 行/未知行 → prompt 原文',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.wrap());
    await tester.pump();

    // '/compact' 发送 → execute,非 prompt。
    await tester.enterText(
        find.byKey(const ValueKey('composer-input')), '/compact');
    await tester.pump();
    await _send(tester);
    expect(h.store.executed, ['/compact']);
    expect(h.prompts, isEmpty);
    expect(_inputText(tester), '', reason: '命令提交成功后清空输入');

    // '/goal set x'(带参命令)→ execute 原行。
    await tester.enterText(
        find.byKey(const ValueKey('composer-input')), '/goal set x');
    await tester.pump();
    await _send(tester);
    expect(h.store.executed, ['/compact', '/goal set x']);
    expect(h.prompts, isEmpty);

    // '/skill-x hi'(skill 行)→ prompt 收到原文。
    await tester.enterText(
        find.byKey(const ValueKey('composer-input')), '/skill-x hi');
    await tester.pump();
    await _send(tester);
    expect(h.prompts, ['/skill-x hi']);
    expect(h.store.executed.length, 2, reason: 'skill 不进命令通道');

    // '/nosuch x'(未知命令)→ prompt 放行(host pre-step 决定去留)。
    await tester.enterText(
        find.byKey(const ValueKey('composer-input')), '/nosuch x');
    await tester.pump();
    await _send(tester);
    expect(h.prompts, ['/skill-x hi', '/nosuch x']);
  });

  testWidgets('提交仲裁:目录降级(非 agent-busy)→ 内联错误 + 输入保留',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.wrap());
    await tester.pump();

    h.store.degrade(code: 'transport');
    await tester.enterText(
        find.byKey(const ValueKey('composer-input')), '/goal x');
    await tester.pump();
    await _send(tester);

    expect(find.byKey(const ValueKey('composer-error')), findsOneWidget);
    expect(_inputText(tester), '/goal x', reason: '失败保留输入可重试');
    expect(h.store.executed, isEmpty);
    expect(h.prompts, isEmpty);
  });

  testWidgets('提交仲裁:agent-busy 降级(子代理会话)→ 放行走 prompt(web 语义)',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.wrap());
    await tester.pump();

    h.store.degrade(code: 'agent-busy');
    await tester.enterText(
        find.byKey(const ValueKey('composer-input')), '/goal x');
    await tester.pump();
    await _send(tester);

    expect(h.prompts, ['/goal x']);
    expect(h.store.executed, isEmpty);
  });
}
