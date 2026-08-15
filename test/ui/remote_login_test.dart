// 登录页 widget 测试(M6):表单校验/成功回调/失败内联。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/remote_auth.dart';
import 'package:singleman/ui/remote_login.dart';

class _FakeAuth implements RemoteAuthenticator {
  _FakeAuth(this.behavior);
  final Future<RemoteLoginSuccess> Function(Uri base, String password)
      behavior;

  @override
  Future<RemoteLoginSuccess> login(Uri baseUri, String password,
      {String device = 'singleman'}) {
    return behavior(baseUri, password);
  }
}

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required RemoteAuthenticator auth,
    required Future<void> Function(RemoteLoginSuccess) onDone,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: RemoteLoginPage(auth: auth, onDone: onDone),
    ));
  }

  testWidgets('bad URL shows inline error without calling login',
      (tester) async {
    var called = false;
    await pumpPage(
      tester,
      auth: _FakeAuth((_, __) async {
        called = true;
        throw const RemoteLoginFailure('unexpected');
      }),
      onDone: (_) async {},
    );
    await tester.enterText(
        find.byType(TextField).at(0), 'not a url');
    await tester.enterText(find.byType(TextField).at(1), 'pw');
    await tester.tap(find.text('登录并连接'));
    await tester.pump();
    expect(called, isFalse);
    expect(find.textContaining('地址格式'), findsOneWidget);
  });

  testWidgets('success: onDone receives base+token, page pops',
      (tester) async {
    RemoteLoginSuccess? received;
    await pumpPage(
      tester,
      auth: _FakeAuth((base, pw) async =>
          RemoteLoginSuccess(baseUri: base, token: 'tok-$pw')),
      onDone: (s) async => received = s,
    );
    await tester.enterText(
        find.byType(TextField).at(0), 'https://dsh.example.com');
    await tester.enterText(find.byType(TextField).at(1), 'secret');
    await tester.tap(find.text('登录并连接'));
    await tester.pumpAndSettle();
    expect(received!.token, 'tok-secret');
    expect(received!.baseUri, Uri.parse('https://dsh.example.com'));
    expect(find.text('登录并连接'), findsNothing, reason: '成功后页面退出');
  });

  testWidgets('failure: friendly message shown, retry possible',
      (tester) async {
    var attempts = 0;
    await pumpPage(
      tester,
      auth: _FakeAuth((_, __) async {
        attempts++;
        throw const RemoteLoginFailure('密码不正确');
      }),
      onDone: (_) async {},
    );
    await tester.enterText(
        find.byType(TextField).at(0), 'https://dsh.example.com');
    await tester.enterText(find.byType(TextField).at(1), 'wrong');
    await tester.tap(find.text('登录并连接'));
    await tester.pump();
    expect(find.text('密码不正确'), findsOneWidget);
    expect(attempts, 1);
    // 可重试:按钮回到可用态。
    await tester.tap(find.text('登录并连接'));
    await tester.pump();
    expect(attempts, 2);
  });
}
