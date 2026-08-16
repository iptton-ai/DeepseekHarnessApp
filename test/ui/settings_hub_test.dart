// 设置中心重构验收:模型选择/发起配对作为子菜单;
// 入口常驻(非特权也可见),特权分区(提供方/通用)在页内按 PrivilegeScope 隐藏。
// 多主机(方案 A):注入 hosts 后「连接」分区 = 主机列表 + 切换/删除/重连。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/host_info.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/theme_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/ui/settings_screen.dart';
import 'package:singleman/ui/theme_mode_row.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 可播种 providers 的假 settings store。
class _FakeSettingsStore implements SettingsStoreView {
  _FakeSettingsStore({SettingsSnapshot snapshot = SettingsSnapshot.empty})
      : _snapshot = snapshot;

  final _ctrl = StreamController<SettingsSnapshot>.broadcast();
  final SettingsSnapshot _snapshot;

  @override
  Stream<SettingsSnapshot> get snapshots => _ctrl.stream;

  @override
  SettingsSnapshot get current => _snapshot;

  /// schema 缺席 → null(UI 隐藏权限预设行,web 同款降级)。
  @override
  List<String>? get permissionPresetOptions => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeThemeStore implements ThemeStoreView {
  final _ctrl = StreamController<ThemePreference>.broadcast();
  ThemePreference _cur = ThemePreference.system;

  @override
  Stream<ThemePreference> get preferences => _ctrl.stream;

  @override
  ThemePreference get current => _cur;

  @override
  Future<void> setMode(ThemePreference mode) async {
    _cur = mode;
    _ctrl.add(mode);
  }
}

class _EmptySessionView implements SessionStoreView {
  @override
  Stream<List<SessionSummary>> get summaries => const Stream.empty();

  @override
  List<SessionSummary> get currentSummaries => const <SessionSummary>[];

  @override
  SessionLog logFor(String sessionId) => SessionLog(sessionId);

  @override
  Future<void> loadHistory(String sessionId) async {}

  @override
  Future<void> loadOlder(String sessionId) async {}

  @override
  Future<String> fork(String sessionId, {int? atSeq}) async => 'forked';

}

SettingsSnapshot _snapshotWithProvider() {
  const view = ConfigurableProviderView(
    provider: 'zai',
    displayName: 'Z.ai',
    settingsNs: 'llm',
    settingsPath: ['providers', 'zai'],
    active: true,
  );
  return SettingsSnapshot(
    providers: [
      ProviderEntry(
        view: view,
        config: const {},
        credentialRef: 'ZAI_API_KEY',
        credentialStatus: CredentialStatus.configured,
        namespace: 'llm',
        settingsPath: const ['providers', 'zai'],
        revision: 1,
      ),
    ],
    namespaces: const {},
    credentials: const {},
    writable: true,
    hasDocument: true,
  );
}

Future<void> _pumpHub(
  WidgetTester tester, {
  required SettingsStoreView store,
  required PrivilegeScope scope,
  VoidCallback? onPickModel,
  VoidCallback? onOpenPairing,
  ValueListenable<HostStatus>? hostStatus,
  ValueListenable<HostBook>? hosts,
  Future<void> Function(String hostId)? onSwitchHost,
  Future<void> Function(String hostId)? onRemoveHost,
  VoidCallback? onReconnect,
  ValueListenable<String?>? deviceName,
  Future<bool> Function(String)? onSetDeviceName,
  ThemeStoreView? theme,
}) {
  return tester.pumpWidget(MaterialApp(
    home: SettingsScreen(
      store: store,
      scope: scope,
      onPickModel: onPickModel,
      onOpenPairing: onOpenPairing,
      hostStatus: hostStatus,
      hosts: hosts,
      onSwitchHost: onSwitchHost,
      onRemoveHost: onRemoveHost,
      onReconnect: onReconnect,
      deviceName: deviceName,
      onSetDeviceName: onSetDeviceName,
      theme: theme,
    ),
  ));
}

void main() {
  testWidgets('非特权(LAN)形态:子菜单渲染,特权分区隐藏,刷新按钮隐藏', (tester) async {
    await _pumpHub(
      tester,
      store: _FakeSettingsStore(),
      scope: scopeFor(Uri.parse('http://192.168.1.5:3080')),
      onPickModel: () {},
      onOpenPairing: () {},
      theme: _FakeThemeStore(),
    );
    await tester.pump();

    // 会话/连接/外观分区常驻。
    expect(find.text('模型选择'), findsOneWidget);
    expect(find.text('发起配对'), findsOneWidget);
    expect(find.text('密码登录'), findsNothing, reason: '密码登录入口已移除(仅配对)');
    expect(find.byType(ThemeModeRow), findsOneWidget);

    // 特权分区整段隐藏 + 锁说明;刷新只对特权数据有意义,一并隐藏。
    expect(find.text('模型提供方'), findsNothing);
    expect(find.text('打开配置文件'), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('本机名称:展示当前值,编辑对话框保存回调', (tester) async {
    final name = ValueNotifier<String?>('Android-Pixel8');
    var saved = '';
    await _pumpHub(
      tester,
      store: _FakeSettingsStore(),
      scope: scopeFor(Uri.parse('https://dsh.example.com')),
      onOpenPairing: () {},
      deviceName: name,
      onSetDeviceName: (raw) async {
        saved = raw;
        name.value = raw;
        return true;
      },
    );
    await tester.pump();

    expect(find.text('本机名称 · Android-Pixel8'), findsOneWidget);
    await tester.tap(find.text('本机名称 · Android-Pixel8'));
    await tester.pumpAndSettle();
    expect(find.text('本机名称'), findsOneWidget); // 对话框标题

    final field = find.byType(TextField);
    await tester.enterText(field, '我的手机');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved, '我的手机');
    expect(find.text('本机名称 · 我的手机'), findsOneWidget);
  });

  testWidgets('已配对(hostStatus.authed):发起配对让位给「已连接 · 机器名」',
      (tester) async {
    final status = ValueNotifier<HostStatus>(
      const HostStatus(authed: true, up: true, machine: 'devs-MacBook-Pro'),
    );
    await _pumpHub(
      tester,
      store: _FakeSettingsStore(),
      scope: scopeFor(Uri.parse('https://dsh.example.com')),
      onOpenPairing: () {},
      hostStatus: status,
    );
    await tester.pump();

    expect(find.text('发起配对'), findsNothing, reason: '已连着宿主不再发起新配对');
    expect(find.text('已连接 · devs-MacBook-Pro'), findsOneWidget);
    expect(find.text('DSH 服务在线,会话可用'), findsOneWidget);

    // 相位翻转:WS 断开 → 未连接文案(机器名保留,凭证种子)。
    status.value =
        const HostStatus(authed: true, up: false, machine: 'devs-MacBook-Pro');
    await tester.pump();
    expect(find.text('devs-MacBook-Pro · 未连接'), findsOneWidget);
    expect(find.text('连接中断,自动重连中'), findsOneWidget);
  });

  testWidgets('未配对(authed=false):发起配对保持旧行为', (tester) async {
    final status = ValueNotifier<HostStatus>(
      const HostStatus(authed: false, up: false),
    );
    await _pumpHub(
      tester,
      store: _FakeSettingsStore(),
      scope: scopeFor(Uri.parse('https://dsh.example.com')),
      onOpenPairing: () {},
      hostStatus: status,
    );
    await tester.pump();
    expect(find.text('发起配对'), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsNothing);
  });

  testWidgets('两个子菜单各自触发回调', (tester) async {
    var model = 0, pair = 0;
    await _pumpHub(
      tester,
      store: _FakeSettingsStore(),
      scope: scopeFor(Uri.parse('http://192.168.1.5:3080')),
      onPickModel: () => model++,
      onOpenPairing: () => pair++,
    );
    await tester.pump();

    await tester.tap(find.text('模型选择'));
    await tester.tap(find.text('发起配对'));
    await tester.pump();
    expect(model, 1);
    expect(pair, 1);
  });

  testWidgets('特权(loopback)形态:提供方与通用分区渲染,快照为空仅分区内部转圈', (tester) async {
    await _pumpHub(
      tester,
      store: _FakeSettingsStore(), // empty snapshot → 未装载
      scope: scopeFor(Uri.parse('http://127.0.0.1:3080')),
    );
    await tester.pump();

    // 页面主体立即渲染(非全屏 spinner):子菜单分区照常在。
    expect(find.text('模型选择'), findsOneWidget);
    expect(find.text('模型提供方'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('特权(loopback)形态:提供方目录渲染', (tester) async {
    await _pumpHub(
      tester,
      store: _FakeSettingsStore(snapshot: _snapshotWithProvider()),
      scope: scopeFor(Uri.parse('http://127.0.0.1:3080')),
    );
    await tester.pump();

    expect(find.text('模型提供方'), findsOneWidget);
    expect(find.text('Z.ai'), findsOneWidget);
    expect(find.text('通用'), findsOneWidget);
    expect(find.text('打开配置文件'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsNothing);
  });

  testWidgets('theme 缺席时外观分区不渲染', (tester) async {
    await _pumpHub(
      tester,
      store: _FakeSettingsStore(),
      scope: scopeFor(Uri.parse('http://127.0.0.1:3080')),
    );
    await tester.pump();
    expect(find.text('外观'), findsNothing);
    expect(find.byType(ThemeModeRow), findsNothing);
  });

  testWidgets('ChatScreen 集成:未选会话点「模型选择」提示,选中后回调触发', (tester) async {
    final sessions = _EmptySessionView();
    final vm = ChatViewModel(store: sessions, connection: null);
    var picked = 0;
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        vm: vm,
        settings: _FakeSettingsStore(),
        scope: scopeFor(Uri.parse('http://192.168.1.5:3080')),
        actions: SessionActions(onPickModel: () => picked++),
      ),
    ));
    await tester.pump();

    // 侧栏「设置」入口 → 设置中心(LAN 形态;特权空快照的转圈会让
    // pumpAndSettle 永不收敛,本测试不关心特权分区)。
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    // 未选会话:提示而非静默无效。
    await tester.tap(find.text('模型选择'));
    await tester.pump();
    expect(find.text('请先选择一个会话'), findsOneWidget);
    expect(picked, 0);
  });

  group('多主机「连接」分区(方案 A)', () {
    final gw1 = StoredCredentials(
      id: 'https://gw1.example.com:443',
      baseUri: Uri.parse('https://gw1.example.com'),
      token: 't1',
      hostLabel: 'MacA',
    );
    final gw2 = StoredCredentials(
      id: 'https://gw2.example.com:443',
      baseUri: Uri.parse('https://gw2.example.com'),
      token: 't2',
    );

    testWidgets('主机列表:活动行实时相位 + 其他主机行 + 添加主机常驻',
        (tester) async {
      final hosts = ValueNotifier(HostBook(hosts: [gw1, gw2], activeId: gw1.id));
      final status = ValueNotifier<HostStatus>(
        const HostStatus(authed: true, up: true, machine: 'MacA-实时'),
      );
      await _pumpHub(
        tester,
        store: _FakeSettingsStore(),
        scope: scopeFor(Uri.parse('https://dsh.example.com')),
        onOpenPairing: () {},
        hostStatus: status,
        hosts: hosts,
        onSwitchHost: (_) async {},
        onRemoveHost: (_) async {},
        onReconnect: () {},
      );
      await tester.pump();

      expect(find.text('已连接 · MacA-实时'), findsOneWidget);
      // 其他主机行:无机器名回落 authority,副标题提示可切换。
      expect(find.text('gw2.example.com'), findsOneWidget);
      expect(find.text('点击切换到此主机'), findsOneWidget);
      // 添加主机常驻(不再被状态行替换)。
      expect(find.text('添加主机(配对)'), findsOneWidget);
      // 每行都有删除按钮。
      expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
      // 已连接的活动行没有重连按钮(绿点 + 删除即可)。
      expect(find.byTooltip('重连'), findsNothing);
    });

    testWidgets('未连接的活动行:重连按钮真实可点(修「点了没反应」)',
        (tester) async {
      final hosts = ValueNotifier(HostBook(hosts: [gw1], activeId: gw1.id));
      final status = ValueNotifier<HostStatus>(
        const HostStatus(authed: true, up: false, machine: 'MacA'),
      );
      var reconnected = 0;
      await _pumpHub(
        tester,
        store: _FakeSettingsStore(),
        scope: scopeFor(Uri.parse('https://dsh.example.com')),
        onOpenPairing: () {},
        hostStatus: status,
        hosts: hosts,
        onRemoveHost: (_) async {},
        onReconnect: () => reconnected++,
      );
      await tester.pump();

      expect(find.text('MacA · 未连接'), findsOneWidget);
      final btn = find.byTooltip('重连');
      expect(btn, findsOneWidget);
      await tester.tap(btn);
      await tester.pump();
      expect(reconnected, 1, reason: '刷新按钮必须触发 onReconnect(此前是纯展示图标)');

      // 相位恢复在线后按钮消失。
      status.value = const HostStatus(authed: true, up: true, machine: 'MacA');
      await tester.pump();
      expect(find.byTooltip('重连'), findsNothing);
    });

    testWidgets('点击其他主机行触发切换回调', (tester) async {
      final hosts = ValueNotifier(HostBook(hosts: [gw1, gw2], activeId: gw1.id));
      String? switched;
      await _pumpHub(
        tester,
        store: _FakeSettingsStore(),
        scope: scopeFor(Uri.parse('https://dsh.example.com')),
        onOpenPairing: () {},
        hostStatus: ValueNotifier<HostStatus>(
            const HostStatus(authed: true, up: true, machine: 'MacA')),
        hosts: hosts,
        onSwitchHost: (id) async => switched = id,
        onRemoveHost: (_) async {},
      );
      await tester.pump();

      await tester.tap(find.text('gw2.example.com'));
      await tester.pump();
      expect(switched, gw2.id);
    });

    testWidgets('删除主机走确认弹窗:取消不动簿,确认触发回调', (tester) async {
      final hosts = ValueNotifier(HostBook(hosts: [gw1, gw2], activeId: gw1.id));
      final removed = <String>[];
      await _pumpHub(
        tester,
        store: _FakeSettingsStore(),
        scope: scopeFor(Uri.parse('https://dsh.example.com')),
        onOpenPairing: () {},
        hostStatus: ValueNotifier<HostStatus>(
            const HostStatus(authed: true, up: true, machine: 'MacA')),
        hosts: hosts,
        onRemoveHost: (id) async => removed.add(id),
      );
      await tester.pump();

      // 删除非活动主机(gw2 行尾的删除钮)。
      await tester.tap(find.byIcon(Icons.delete_outline).last);
      await tester.pumpAndSettle();
      expect(find.text('删除主机'), findsOneWidget);
      expect(find.textContaining('此操作不可撤销'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(removed, isEmpty);

      await tester.tap(find.byIcon(Icons.delete_outline).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(removed, [gw2.id]);

      // 删除活动主机文案带切换去向说明。
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('当前连接会切换到其他已配对主机'), findsOneWidget);
    });

    testWidgets('簿经 notifier 变化即时重建(删行消失/空簿回落发起配对)',
        (tester) async {
      final hosts = ValueNotifier(HostBook(hosts: [gw1, gw2], activeId: gw1.id));
      await _pumpHub(
        tester,
        store: _FakeSettingsStore(),
        scope: scopeFor(Uri.parse('https://dsh.example.com')),
        onOpenPairing: () {},
        hostStatus: ValueNotifier<HostStatus>(
            const HostStatus(authed: true, up: true, machine: 'MacA')),
        hosts: hosts,
        onRemoveHost: (_) async {},
      );
      await tester.pump();
      expect(find.text('gw2.example.com'), findsOneWidget);

      hosts.value = HostBook(hosts: [gw1], activeId: gw1.id);
      await tester.pump();
      expect(find.text('gw2.example.com'), findsNothing);

      hosts.value = const HostBook();
      await tester.pump();
      expect(find.text('发起配对'), findsOneWidget, reason: '删空回落首启形态');
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('未注入 hosts 保持旧形态(向后兼容)', (tester) async {
      final status = ValueNotifier<HostStatus>(
        const HostStatus(authed: true, up: true, machine: '旧形态Mac'),
      );
      await _pumpHub(
        tester,
        store: _FakeSettingsStore(),
        scope: scopeFor(Uri.parse('https://dsh.example.com')),
        onOpenPairing: () {},
        hostStatus: status,
      );
      await tester.pump();
      expect(find.text('已连接 · 旧形态Mac'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNothing,
          reason: '旧形态不出现主机管理按钮');
      expect(find.text('添加主机(配对)'), findsNothing);
    });
  });
}
