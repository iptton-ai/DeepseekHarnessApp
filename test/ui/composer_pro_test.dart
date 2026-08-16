// UpgradeComposer 测试(W2-A):域映射(prompt_modes) + widget 行为 + 失败路径。
//
// 模式:纯 widget 测试,注入假回调与假 sender(抛 RpcBusinessError 模拟
// steer-unavailable / agent-busy 等业务拒绝),不碰 socket / HttpClient,
// 不 import 共享 helper(自建最小假件)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/sessions/prompt_modes.dart';
import 'package:singleman/ui/composer_pro.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 录制回调的假件:可编程抛错(依次),成功则记账。
class _Harness {
  _Harness({
    this.running = false,
    this.canSend = true,
    this.errors = const [],
    this.withCancel = true,
    this.withPick = true,
  });

  final bool running;
  final bool canSend;
  final List<Object> errors;
  final bool withCancel;
  final bool withPick;

  final sends = <({String text, bool steer})>[];
  final intents = <String>[];
  int cancels = 0;
  int picks = 0;
  int _errIdx = 0;

  Future<void> onSend(String text, {required bool steer}) async {
    if (_errIdx < errors.length) {
      throw errors[_errIdx++];
    }
    sends.add((text: text, steer: steer));
  }

  void onCancel() => cancels++;
  void onCommandIntent(String query) => intents.add(query);
  void onPickImages() => picks++;
}

const _inputKey = ValueKey('composer-input');
const _sendKey = ValueKey('composer-send');
const _stopKey = ValueKey('composer-stop');
const _attachKey = ValueKey('composer-attach');
const _errorKey = ValueKey('composer-error');
const _menuKey = ValueKey('composer-command-menu');

Future<void> _pump(
  WidgetTester tester,
  _Harness h, {
  Widget? commandMenu,
  Widget? attachmentsSlot,
  TextEditingController? controller,
  Future<void> Function(String text, {required bool steer})? onSendOverride,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: UpgradeComposer(
          running: h.running,
          canSend: h.canSend,
          onSend: onSendOverride ?? h.onSend,
          onCancel: h.withCancel ? h.onCancel : null,
          onCommandIntent: h.onCommandIntent,
          onPickImages: h.withPick ? h.onPickImages : null,
          commandMenu: commandMenu,
          attachmentsSlot: attachmentsSlot,
          controller: controller,
        ),
      ),
    ),
  ));
}

FilledButton _sendBtn(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(_sendKey));

/// 停止按钮本体(外层是 48dp FilledButton;Tooltip/SizedBox 包裹)。
FilledButton _stopBtn(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(_stopKey));

String _inputText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_inputKey)).controller!.text;

void main() {
  group('PromptMode 域(prompt_modes.dart)', () {
    test('fromWire / wire 串 / forRunning / canSteer', () {
      expect(PromptMode.fromWire('queue'), PromptMode.queue);
      expect(PromptMode.fromWire('steer'), PromptMode.steer);
      expect(PromptMode.fromWire(null), PromptMode.queue);
      expect(PromptMode.fromWire('future-mode'), PromptMode.queue);
      expect(PromptMode.queue.wire, 'queue');
      expect(PromptMode.steer.wire, 'steer');
      expect(PromptMode.queue.label, '发送');
      expect(PromptMode.steer.label, '插话');
      expect(PromptMode.forRunning(false), PromptMode.queue);
      expect(PromptMode.forRunning(true), PromptMode.steer);
      expect(canSteer(false), isFalse);
      expect(canSteer(true), isTrue);
    });

    test('promptErrorMessage:已知码 / 未知码 / null / serverMessage', () {
      expect(promptErrorMessage('steer-unavailable'), contains('无法插话'));
      expect(promptErrorMessage('steer-unavailable'), contains('steer-unavailable'));
      expect(promptErrorMessage('agent-busy'), contains('会话正忙'));
      expect(promptErrorMessage('unknown-command'), contains('未知命令'));
      expect(promptErrorMessage('model-unavailable'), contains('不可路由'));
      expect(promptErrorMessage('internal'), contains('内部错误'));
      expect(promptErrorMessage('some-unknown-code'), contains('some-unknown-code'));
      expect(promptErrorMessage(null), '发送失败');
      expect(promptErrorMessage('steer-unavailable', serverMessage: 'round closed'),
          contains('round closed'));
    });

    test('promptErrorCode:业务错误提取 code,非业务异常为 null', () {
      expect(
        promptErrorCode(RpcBusinessError(
            RpcErrorSteerUnavailable(message: 'x', details: {}))),
        'steer-unavailable',
      );
      expect(
        promptErrorCode(
            RpcBusinessError(RpcErrorAgentBusy(message: 'x', details: {}))),
        'agent-busy',
      );
      expect(promptErrorCode(StateError('boom')), isNull);
      expect(promptErrorCode('plain'), isNull);
    });
  });

  group('UpgradeComposer widget', () {
    testWidgets('queue 模式:按钮「发送」,tap → onSend(text, steer:false),成功清空+trim',
        (tester) async {
      final h = _Harness();
      await _pump(tester, h);
      expect(find.text('发送'), findsOneWidget);
      expect(find.text('插话'), findsNothing);

      await tester.enterText(find.byKey(_inputKey), '  hello  ');
      await tester.pump();
      expect(_sendBtn(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(_sendKey));
      await tester.pump();

      expect(h.sends, [(text: 'hello', steer: false)]);
      expect(_inputText(tester), isEmpty);
    });

    testWidgets('running 模式:发送默认进队列(steer:false),按钮仍「发送」(用户诉求)',
        (tester) async {
      final h = _Harness(running: true);
      await _pump(tester, h);
      // 发送按钮不再因 running 变「插话」—— 插话入口移到队列 Dock。
      expect(find.text('发送'), findsOneWidget);
      expect(find.text('插话'), findsNothing);

      await tester.enterText(find.byKey(_inputKey), 'queued msg');
      await tester.pump();
      await tester.tap(find.byKey(_sendKey));
      await tester.pump();

      expect(h.sends, [(text: 'queued msg', steer: false)]);
    });

    testWidgets('空文本/纯空白禁发:按钮禁用,tap 无效', (tester) async {
      final h = _Harness();
      await _pump(tester, h);
      expect(_sendBtn(tester).onPressed, isNull); // 初始空

      await tester.enterText(find.byKey(_inputKey), '   ');
      await tester.pump();
      expect(_sendBtn(tester).onPressed, isNull);
      await tester.tap(find.byKey(_sendKey), warnIfMissed: false);
      await tester.pump();
      expect(h.sends, isEmpty);
    });

    testWidgets('canSend=false:输入框与发送按钮整体禁用', (tester) async {
      final h = _Harness(canSend: false);
      await _pump(tester, h);
      expect(tester.widget<TextField>(find.byKey(_inputKey)).enabled, isFalse);
      expect(_sendBtn(tester).onPressed, isNull);
    });

    testWidgets('停止:running 可用并回调;非 running 不渲染;onCancel null 不渲染',
        (tester) async {
      final h = _Harness(running: true);
      await _pump(tester, h);
      // 未聚焦 + running:停止出现在输入行内。
      expect(_stopBtn(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(_stopKey));
      await tester.pump();
      expect(h.cancels, 1);

      // 非 running:无事可停,整体不渲染(不再以禁用态占位)。
      final idle = _Harness();
      await _pump(tester, idle);
      expect(find.byKey(_stopKey), findsNothing);
      expect(idle.cancels, 0);

      final noCancel = _Harness(running: true, withCancel: false);
      await _pump(tester, noCancel);
      expect(find.byKey(_stopKey), findsNothing);
    });

    testWidgets('停止常显且在最右:聚焦输入框不隐藏,位于发送右侧(用户诉求)',
        (tester) async {
      final h = _Harness(running: true);
      await _pump(tester, h);
      expect(find.byKey(_stopKey), findsOneWidget);

      // 聚焦(点击输入框):停止不再隐藏 —— 让输入框失焦太麻烦。
      await tester.tap(find.byKey(_inputKey));
      await tester.pump();
      expect(find.byKey(_stopKey), findsOneWidget);
      expect(find.byKey(_sendKey), findsOneWidget);

      // 顺序:… 输入框 → 发送 → 停止(停止最右侧)。
      expect(
        tester.getTopLeft(find.byKey(_sendKey)).dx,
        lessThan(tester.getTopLeft(find.byKey(_stopKey)).dx),
        reason: '停止按钮应排在发送按钮右侧(最右)',
      );
    });

    testWidgets('斜杠命令:占位显示 + onCommandIntent 上抛 + 退出斜杠态',
        (tester) async {
      final h = _Harness();
      await _pump(tester, h);
      expect(find.byKey(_menuKey), findsNothing);

      await tester.enterText(find.byKey(_inputKey), '/');
      await tester.pump();
      expect(find.byKey(_menuKey), findsOneWidget); // 内置占位
      expect(h.intents, ['']);

      await tester.enterText(find.byKey(_inputKey), '/help');
      await tester.pump();
      expect(h.intents, ['', 'help']);
      // 占位条展示当前查询(限定在菜单槽内,避开输入框自身的 EditableText)。
      expect(
        find.descendant(
            of: find.byKey(_menuKey), matching: find.textContaining('/help')),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(_inputKey), 'plain');
      await tester.pump();
      expect(find.byKey(_menuKey), findsNothing);
      expect(h.intents.last, '');
    });

    testWidgets('斜杠命令:注入 commandMenu 替换内置占位', (tester) async {
      final h = _Harness();
      await _pump(
        tester,
        h,
        commandMenu: const SizedBox(
          key: ValueKey('injected-menu'),
          child: Text('FAKE MENU'),
        ),
      );
      await tester.enterText(find.byKey(_inputKey), '/plan');
      await tester.pump();
      expect(find.byKey(const ValueKey('injected-menu')), findsOneWidget);
      expect(find.byKey(_menuKey), findsOneWidget); // KeyedSubtree 包装
      expect(find.text('FAKE MENU'), findsOneWidget);
      expect(find.textContaining('待 W2-D 接入'), findsNothing);
    });

    testWidgets('附件:attachmentsSlot 注入展示,onPickImages 上抛;未注入不渲染',
        (tester) async {
      final h = _Harness();
      await _pump(
        tester,
        h,
        attachmentsSlot: const SizedBox(
          key: ValueKey('fake-rail'),
          height: 44,
          child: Text('RAIL'),
        ),
      );
      expect(find.byKey(const ValueKey('fake-rail')), findsOneWidget);
      expect(find.byKey(_attachKey), findsOneWidget);
      await tester.tap(find.byKey(_attachKey));
      await tester.pump();
      expect(h.picks, 1);

      final noPick = _Harness(withPick: false);
      await _pump(tester, noPick);
      expect(find.byKey(_attachKey), findsNothing);
    });

    testWidgets('错误内联:假 sender 抛 steer-unavailable → 映射文案 + 输入保留,再发成功清除',
        (tester) async {
      final h = _Harness(
        running: true,
        errors: [
          RpcBusinessError(RpcErrorSteerUnavailable(
              message: 'round already closed', details: {})),
        ],
      );
      await _pump(tester, h);
      await tester.enterText(find.byKey(_inputKey), 'steer me');
      await tester.pump();
      await tester.tap(find.byKey(_sendKey));
      await tester.pump();

      expect(h.sends, isEmpty); // 抛错不记账
      expect(find.byKey(_errorKey), findsOneWidget);
      expect(find.textContaining('无法插话'), findsOneWidget);
      expect(find.textContaining('round already closed'), findsOneWidget);
      expect(_inputText(tester), 'steer me'); // 保留可重试

      // 重试成功 → 错误清除 + 清空。
      await tester.tap(find.byKey(_sendKey));
      await tester.pump();
      expect(find.byKey(_errorKey), findsNothing);
      expect(_inputText(tester), isEmpty);
      // 发送恒走队列(steer:false)—— 插话入口在队列 Dock,不在 composer。
      expect(h.sends, [(text: 'steer me', steer: false)]);
    });

    testWidgets('错误:agent-busy 映射 + 重新输入即清除', (tester) async {
      final h = _Harness(errors: [
        RpcBusinessError(RpcErrorAgentBusy(message: 'busy now', details: {})),
      ]);
      await _pump(tester, h);
      await tester.enterText(find.byKey(_inputKey), 'again');
      await tester.pump();
      await tester.tap(find.byKey(_sendKey));
      await tester.pump();
      expect(find.textContaining('会话正忙'), findsOneWidget);
      expect(find.textContaining('busy now'), findsOneWidget);

      await tester.enterText(find.byKey(_inputKey), 'retry');
      await tester.pump();
      expect(find.byKey(_errorKey), findsNothing);
    });

    testWidgets('错误:非业务异常走兜底文案', (tester) async {
      final h = _Harness(errors: [StateError('boom')]);
      await _pump(tester, h);
      await tester.enterText(find.byKey(_inputKey), 'x');
      await tester.pump();
      await tester.tap(find.byKey(_sendKey));
      await tester.pump();
      expect(find.textContaining('发送失败'), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
    });

    testWidgets('移动端回车换行:回车不发送,输入保留', (tester) async {
      final h = _Harness();
      await _pump(tester, h);
      await tester.enterText(find.byKey(_inputKey), 'line one');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.pump();
      expect(h.sends, isEmpty);
      expect(_inputText(tester), contains('line one'));
    });

    testWidgets('发送中防抖:同一轮发送未完成时再点不重复触发', (tester) async {
      final gate = Completer<void>();
      final sends = <({String text, bool steer})>[];
      final h = _Harness();
      await _pump(
        tester,
        h,
        onSendOverride: (text, {required steer}) async {
          sends.add((text: text, steer: steer));
          await gate.future;
        },
      );
      await tester.enterText(find.byKey(_inputKey), 'once');
      await tester.pump();
      await tester.tap(find.byKey(_sendKey));
      await tester.pump();
      await tester.tap(find.byKey(_sendKey), warnIfMissed: false);
      await tester.pump();
      expect(sends, hasLength(1));

      gate.complete();
      await tester.pump();
      expect(_inputText(tester), isEmpty);
    });

    testWidgets('动作区触控目标 ≥48dp(移动可用性硬性)', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _Harness(running: true);
      await _pump(tester, h);
      expect(tester.getSize(find.byKey(_sendKey)).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byKey(_stopKey)).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byKey(_attachKey)).height, greaterThanOrEqualTo(48));
    });

    testWidgets('窄屏降级:权限/模型 chip 只显图标,工具行不溢出(用户诉求)',
        (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: UpgradeComposer(
              running: true,
              canSend: true,
              onSend: (text, {required steer}) async {},
              onCancel: () {},
              onPickImages: () {},
              onAddCommand: () {},
              permissionLabel: 'workspace-write',
              onSwitchPermission: () {},
              modelLabel: 'DeepSeek-V3.2',
              onPickModel: () {},
            ),
          ),
        ),
      ));
      await tester.pump();

      // 宽度不足:不得出现 RenderFlex 溢出(文本穿透按钮的根因)。
      expect(tester.takeException(), isNull, reason: '窄屏工具行不得溢出');
      // 降级:权限 chip 仅图标(文案让位),模型 chip 隐藏,发送收成图标。
      expect(find.byIcon(Icons.edit_note_outlined), findsOneWidget,
          reason: '权限图标仍在(仅图标形态)');
      expect(find.text('工作区可写'), findsNothing);
      expect(find.byIcon(Icons.memory), findsNothing, reason: '极窄:模型 chip 隐藏');
      expect(find.text('DeepSeek-V3.2'), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget, reason: '发送图标仍在');
      expect(find.text('发送'), findsNothing, reason: '极窄:发送收成图标');
      // 停止/图片/命令按钮不受降级影响。
      expect(find.byKey(_stopKey), findsOneWidget);
      expect(find.byKey(_attachKey), findsOneWidget);
    });

    testWidgets('中等宽度:chip 图标化但保留发送文案与模型 chip', (tester) async {
      tester.view.physicalSize = const Size(412, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: UpgradeComposer(
              running: true,
              canSend: true,
              onSend: (text, {required steer}) async {},
              onCancel: () {},
              onPickImages: () {},
              onAddCommand: () {},
              permissionLabel: 'workspace-write',
              onSwitchPermission: () {},
              modelLabel: 'DeepSeek-V3.2',
              onPickModel: () {},
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      // 余量不足以带文案(约 128 < 220)→ 图标化;但 ≥100 → 模型保留、发送带文案。
      expect(find.byIcon(Icons.edit_note_outlined), findsOneWidget);
      expect(find.text('工作区可写'), findsNothing);
      expect(find.byIcon(Icons.memory), findsOneWidget);
      expect(find.text('发送'), findsOneWidget);
    });

    testWidgets('宽屏:权限/模型 chip 带完整文案', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: UpgradeComposer(
              running: false,
              canSend: true,
              onSend: (text, {required steer}) async {},
              onPickImages: () {},
              onAddCommand: () {},
              permissionLabel: 'workspace-write',
              onSwitchPermission: () {},
              modelLabel: 'DeepSeek-V3.2',
              onPickModel: () {},
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('工作区可写'), findsOneWidget);
      expect(find.text('DeepSeek-V3.2'), findsOneWidget);
      expect(find.text('发送'), findsOneWidget);
      expect(find.byIcon(Icons.memory), findsOneWidget);
    });

    testWidgets('输入框形态:placeholder 单行省略,无左侧图标,停止与发送同为 48dp 填充按钮',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final h = _Harness(running: true);
      await _pump(tester, h);
      final input = tester.widget<TextField>(find.byKey(_inputKey));

      // placeholder 用 hint widget 强制单行(hintText 字符串会随 maxLines 折行)。
      final hint = input.decoration?.hint;
      expect(hint, isA<Text>());
      expect((hint as Text).maxLines, 1, reason: 'placeholder 恒单行,不撑高默认输入框');
      expect(hint.overflow, TextOverflow.ellipsis);
      expect(hint.data, '输入消息');

      // 左侧不放多余图标。
      expect(input.decoration?.prefixIcon, isNull);

      // 停止与发送同为 FilledButton 且等大(视觉协调)。
      expect(tester.widget<FilledButton>(find.byKey(_stopKey)), isNotNull);
      expect(tester.getSize(find.byKey(_stopKey)), const Size(48, 48));
      expect(tester.getSize(find.byKey(_sendKey)).height, 48);
      // 单行 placeholder 下空输入框高度收敛(两行 hint 曾把默认高度撑到 60+)。
      expect(tester.getSize(find.byKey(_inputKey)).height, lessThan(56));
    });
  });
}
