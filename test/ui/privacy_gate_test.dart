// 隐私门页测试(OHOS 首启):关键文案可见/同意回调/不同意二次确认
// (再想想不退出、坚持退出才回调)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/ui/privacy_gate.dart';

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required Future<void> Function() onAgree,
    required VoidCallback onExit,
  }) async {
    await tester.pumpWidget(
      MaterialApp(home: PrivacyConsentPage(onAgree: onAgree, onExit: onExit)),
    );
  }

  testWidgets('关键文案与按钮可见(摘要卡/同意/不同意/政策 URL)', (tester) async {
    await pumpPage(
      tester,
      onAgree: () async {},
      onExit: () {},
    );

    expect(find.text('欢迎使用 DshAPP'), findsOneWidget);
    expect(find.text('使用前,请阅读并同意《隐私政策》'), findsOneWidget);
    expect(find.byKey(const ValueKey('privacy-summary')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacy-agree')), findsOneWidget);
    expect(find.byKey(const ValueKey('privacy-decline')), findsOneWidget);
    // 未注入 dart-define 时显示占位符默认值(真实地址发布构建注入,不入仓库)。
    expect(find.textContaining('dsh.example.com/dshapp/privacy.html'),
        findsOneWidget);
    // 全量正文章节标题都在。
    expect(find.text('一、我们如何收集和使用信息'), findsOneWidget);
    expect(find.text('六、政策更新与联系我们'), findsOneWidget);
  });

  testWidgets('点「同意并继续」触发 onAgree', (tester) async {
    var agreed = false;
    await pumpPage(
      tester,
      onAgree: () async => agreed = true,
      onExit: () {},
    );

    await tester.tap(find.byKey(const ValueKey('privacy-agree')));
    await tester.pumpAndSettle();

    expect(agreed, isTrue);
  });

  testWidgets('不同意 → 二次确认;「再想想」不退出', (tester) async {
    var exited = false;
    await pumpPage(
      tester,
      onAgree: () async {},
      onExit: () => exited = true,
    );

    await tester.tap(find.byKey(const ValueKey('privacy-decline')));
    await tester.pumpAndSettle();
    expect(find.text('不同意并退出?'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('privacy-exit-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('不同意并退出?'), findsNothing);
    expect(exited, isFalse);
  });

  testWidgets('不同意 → 坚持退出才触发 onExit', (tester) async {
    var exited = false;
    await pumpPage(
      tester,
      onAgree: () async {},
      onExit: () => exited = true,
    );

    await tester.tap(find.byKey(const ValueKey('privacy-decline')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('privacy-exit-confirm')));
    await tester.pumpAndSettle();

    expect(exited, isTrue);
  });
}
