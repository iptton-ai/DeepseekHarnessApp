// W3-C 移动可用性验收(360dp):ThemeModeRow 三选一切换回调 + ≥48dp 触控区 +
// 流驱动选中态 + CAS 冲突 SnackBar;WelcomeOnboarding 三步推进/不再提示/
// 移动全屏化/shouldShow 逻辑(假通道,不 import 共享 helper)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/theme_store.dart';
import 'package:singleman/ui/onboarding_sheet.dart';
import 'package:singleman/ui/theme_mode_row.dart';

// ---------------------------------------------------------------------------
// 假 ThemeStoreView(窄接口)。
// ---------------------------------------------------------------------------
class _FakeThemeStore implements ThemeStoreView {
  _FakeThemeStore(this._current);
  ThemePreference _current;
  final _ctrl = StreamController<ThemePreference>.broadcast();
  final writes = <ThemePreference>[];
  Object? nextError;

  @override
  Stream<ThemePreference> get preferences => _ctrl.stream;
  @override
  ThemePreference get current => _current;

  @override
  Future<void> setMode(ThemePreference mode) async {
    if (nextError != null) {
      final e = nextError!;
      nextError = null;
      throw e;
    }
    writes.add(mode);
    _current = mode;
    _ctrl.add(mode);
  }

  void emit(ThemePreference p) {
    _current = p;
    _ctrl.add(p);
  }

  Future<void> dispose() => _ctrl.close();
}

// ---------------------------------------------------------------------------
// 假 OnboardingChannel。
// ---------------------------------------------------------------------------
class _FakeOnboardingChannel implements OnboardingChannel {
  String? version;
  bool loadFails = false;
  bool writeFails = false;
  int writeCalls = 0;
  int loadCalls = 0;
  String? lastWritten;

  @override
  String? get welcomeVersion => version;

  @override
  Future<void> load() async {
    loadCalls += 1;
    if (loadFails) throw Exception('read failed');
  }

  @override
  Future<bool> setWelcomeVersion(String v) async {
    writeCalls += 1;
    lastWritten = v;
    if (writeFails) return false;
    version = v;
    return true;
  }
}

/// 打开引导 sheet 的宿主(触发按钮)。
Widget _host(void Function(BuildContext) onOpen) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) => Center(
        child: ElevatedButton(
          onPressed: () => onOpen(ctx),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  group('ThemeModeRow(360dp)', () {
    testWidgets('三选一:点选即时回调 + 持久化 + ≥48dp 触控区', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = _FakeThemeStore(ThemePreference.system);
      ThemePreference? fired;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ThemeModeRow(store: store, onChanged: (p) => fired = p),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('theme-segment-light')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-segment-dark')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('theme-segment-system')),
        findsOneWidget,
      );

      // 触控区 ≥48dp。
      final size = tester.getSize(
        find.byKey(const ValueKey('theme-segment-dark')),
      );
      expect(size.height, greaterThanOrEqualTo(48));

      await tester.tap(find.byKey(const ValueKey('theme-segment-dark')));
      await tester.pump();
      expect(fired, ThemePreference.dark); // 即时回调上抛。
      await tester.pump();
      expect(store.writes, <ThemePreference>[ThemePreference.dark]); // 持久化。
    });

    testWidgets('preferences 流驱动选中态(失效重读回写)', (tester) async {
      final store = _FakeThemeStore(ThemePreference.system);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ThemeModeRow(store: store)),
        ),
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('theme-segment-system')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      store.emit(ThemePreference.light);
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('theme-segment-light')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('theme-segment-system')),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );
    });

    testWidgets('CAS 冲突 → SnackBar 提示(配置已在别处修改)', (tester) async {
      final store = _FakeThemeStore(ThemePreference.system)
        ..nextError = ThemeSettingsConflictError(
          'ui-theme',
          expectedRevision: 1.0,
          latestRevision: 5.0,
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ThemeModeRow(store: store)),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('theme-segment-dark')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('配置已在别处修改,已重新加载'), findsOneWidget);
    });
  });

  group('WelcomeOnboarding(360dp)', () {
    testWidgets('三步推进:欢迎 → 连接形态 → 完结;完成写 welcomeNoticeVersion', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ch = _FakeOnboardingChannel()..version = '2026-08-01.0'; // 旧公告。
      final controller = WelcomeOnboardingController(ch);
      await tester.pumpWidget(
        _host((ctx) => maybeShowWelcomeOnboarding(ctx, controller: controller)),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('欢迎使用 singleman'), findsOneWidget);
      // 进度点 3 个。
      expect(find.byKey(const ValueKey('onboarding-dot-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('onboarding-dot-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('onboarding-dot-2')), findsOneWidget);

      // 步骤二:连接形态。
      await tester.tap(find.byKey(const ValueKey('onboarding-next')));
      await tester.pumpAndSettle();
      expect(find.text('连接形态'), findsOneWidget);
      expect(find.textContaining('loopback'), findsWidgets);
      expect(find.textContaining('LAN'), findsWidgets);

      // 上一步回退。
      await tester.tap(find.byKey(const ValueKey('onboarding-back')));
      await tester.pumpAndSettle();
      expect(find.text('欢迎使用 singleman'), findsOneWidget);

      // 直达完结并完成。
      await tester.tap(find.byKey(const ValueKey('onboarding-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('onboarding-next')));
      await tester.pumpAndSettle();
      expect(find.text('开始使用'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('onboarding-next'))); // 完成。
      await tester.pumpAndSettle();
      expect(find.text('欢迎使用 singleman'), findsNothing); // sheet 已关。
      expect(ch.writeCalls, 1);
      expect(ch.lastWritten, kWelcomeNoticeVersion);
    });

    testWidgets('不再提示:写 settings + 关闭 + 本会话不再出现', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ch = _FakeOnboardingChannel(); // 读不到 → 降级本地:显示。
      final controller = WelcomeOnboardingController(ch);
      await tester.pumpWidget(
        _host((ctx) => maybeShowWelcomeOnboarding(ctx, controller: controller)),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('欢迎使用 singleman'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('onboarding-dismiss')));
      await tester.pumpAndSettle();
      expect(find.text('欢迎使用 singleman'), findsNothing);
      expect(ch.writeCalls, 1);
      expect(ch.lastWritten, kWelcomeNoticeVersion);
      expect(controller.isDismissed, isTrue);
      expect(await controller.shouldShow(), isFalse);
    });

    testWidgets('360dp 引导内容全屏化:sheet 高度 ≥ 屏高 80%', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ch = _FakeOnboardingChannel();
      final controller = WelcomeOnboardingController(ch);
      await tester.pumpWidget(
        _host((ctx) => maybeShowWelcomeOnboarding(ctx, controller: controller)),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final size = tester.getSize(
        find.byKey(const ValueKey('onboarding-sheet')),
      );
      expect(size.height, greaterThanOrEqualTo(800 * 0.8));
    });

    testWidgets('已看过(版本匹配)→ maybeShow 不弹', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ch = _FakeOnboardingChannel()..version = kWelcomeNoticeVersion;
      final controller = WelcomeOnboardingController(ch);
      await tester.pumpWidget(
        _host((ctx) => maybeShowWelcomeOnboarding(ctx, controller: controller)),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('欢迎使用 singleman'), findsNothing);
      expect(ch.loadCalls, 0); // 已读过,不发读请求。
    });
  });

  group('WelcomeOnboardingController.shouldShow 逻辑', () {
    test('已看过(版本匹配)→ false', () async {
      final ch = _FakeOnboardingChannel()..version = kWelcomeNoticeVersion;
      final c = WelcomeOnboardingController(ch);
      expect(await c.shouldShow(), isFalse);
    });

    test('旧公告版本 → true', () async {
      final ch = _FakeOnboardingChannel()..version = '2026-08-01.0';
      final c = WelcomeOnboardingController(ch);
      expect(await c.shouldShow(), isTrue);
    });

    test('读不到(降级本地)→ true', () async {
      final ch = _FakeOnboardingChannel(); // version null。
      final c = WelcomeOnboardingController(ch);
      expect(await c.shouldShow(), isTrue);
      expect(ch.loadCalls, 1); // null → 先显式 load 再判定。
    });

    test('读失败(LAN 403 类)→ 降级本地 true,不抛', () async {
      final ch = _FakeOnboardingChannel()..loadFails = true;
      final c = WelcomeOnboardingController(ch);
      expect(await c.shouldShow(), isTrue);
    });

    test('写失败 → 本地标记兜底,本会话不再出现', () async {
      final ch = _FakeOnboardingChannel()..writeFails = true;
      final c = WelcomeOnboardingController(ch);
      expect(await c.dismiss(), isFalse); // 写失败。
      expect(c.isDismissed, isTrue); // 本地标记兜底。
      expect(await c.shouldShow(), isFalse);
    });
  });
}
