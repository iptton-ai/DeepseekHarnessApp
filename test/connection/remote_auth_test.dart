// 远程鉴权测试(M6):登录成功/失败折叠 + 启动计划决策。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/remote_auth.dart';

void main() {
  late HttpServer gateway;
  late RemoteAuthClient auth;

  setUp(() async {
    gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    auth = RemoteAuthClient();
  });

  tearDown(() async {
    auth.dispose();
    await gateway.close(force: true);
  });

  void serveLogin({
    String password = 'hunter2',
    int okStatus = 200,
  }) {
    gateway.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join())
          as Map<String, dynamic>;
      if (req.uri.path == '/auth/login') {
        if (body['password'] != password) {
          req.response.statusCode = 401;
          req.response.write('{"error":"Unauthorized"}');
          await req.response.close();
          return;
        }
        req.response.statusCode = okStatus;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"token":"jwt-abc","expires_at":1999999999}');
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  }

  Uri base() => Uri.parse('http://127.0.0.1:${gateway.port}');

  test('login success returns token', () async {
    serveLogin();
    final success = await auth.login(base(), 'hunter2', device: 'test');
    expect(success.token, 'jwt-abc');
    expect(success.baseUri, base());
  });

  test('wrong password folds to friendly message', () async {
    serveLogin();
    await expectLater(
      auth.login(base(), 'nope'),
      throwsA(isA<RemoteLoginFailure>()
          .having((e) => e.message, 'message', contains('密码'))),
    );
  });

  test('rate limited (409) folds to friendly message', () async {
    serveLogin();
    gateway.close(force: true);
    gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    gateway.listen((req) async {
      await utf8.decoder.bind(req).join();
      req.response.statusCode = 409;
      await req.response.close();
    });
    await expectLater(
      auth.login(base(), 'x'),
      throwsA(isA<RemoteLoginFailure>()
          .having((e) => e.message, 'message', contains('频繁'))),
    );
  });

  test('non-json body folds to friendly message', () async {
    gateway.listen((req) async {
      await utf8.decoder.bind(req).join();
      req.response.statusCode = 200;
      req.response.write('<html>');
      await req.response.close();
    });
    await expectLater(
      auth.login(base(), 'x'),
      throwsA(isA<RemoteLoginFailure>()),
    );
  });

  group('planFromCredentials', () {
    test('no stored credentials → loopback default, no login', () async {
      final plan = await planFromCredentials(MemoryCredentialStore());
      expect(plan.baseUri, Uri.parse('http://127.0.0.1:3080'));
      expect(plan.needsLogin, isFalse);
      expect(plan.tokenProvider.hasToken, isFalse);
    });

    test('mobileFirst: no credentials → gateway login plan (loopback 永不可达)',
        () async {
      final plan = await planFromCredentials(
        MemoryCredentialStore(),
        mobileFirst: true,
      );
      expect(plan.baseUri, Uri.parse(kDefaultGatewayBase));
      expect(plan.needsLogin, isTrue,
          reason: '手机首启必须直接见到密码输入页');
      expect(plan.tokenProvider.hasToken, isFalse);
    });

    test('mobileFirst: 已存凭证不受影响(静默连/loopback 语义不变)', () async {
      final remote = MemoryCredentialStore()
        .._saveSync(StoredCredentials(
          baseUri: Uri.parse('https://dsh.example.com'),
          token: 'tok',
        ));
      final planRemote = await planFromCredentials(remote, mobileFirst: true);
      expect(planRemote.needsLogin, isFalse);

      final loop = MemoryCredentialStore()
        .._saveSync(StoredCredentials(
          baseUri: Uri.parse('http://127.0.0.1:3080'),
        ));
      final planLoop = await planFromCredentials(loop, mobileFirst: true);
      expect(planLoop.needsLogin, isFalse);
      expect(planLoop.baseUri, Uri.parse('http://127.0.0.1:3080'));
    });

    test('loopback stored (even with token) → no login, token dropped',
        () async {
      final store = MemoryCredentialStore()
        .._saveSync(StoredCredentials(
          baseUri: Uri.parse('http://localhost:3080'),
          token: 'stale',
        ));
      final plan = await planFromCredentials(store);
      expect(plan.needsLogin, isFalse);
      expect(plan.tokenProvider.hasToken, isFalse,
          reason: 'loopback 直连不带令牌头');
    });

    test('remote without token → needs login', () async {
      final store = MemoryCredentialStore()
        .._saveSync(StoredCredentials(
          baseUri: Uri.parse('https://dsh.example.com'),
        ));
      final plan = await planFromCredentials(store);
      expect(plan.needsLogin, isTrue);
      expect(plan.baseUri, Uri.parse('https://dsh.example.com'));
    });

    test('remote with token → silent connect', () async {
      final store = MemoryCredentialStore()
        .._saveSync(StoredCredentials(
          baseUri: Uri.parse('https://dsh.example.com'),
          token: 'tok',
        ));
      final plan = await planFromCredentials(store);
      expect(plan.needsLogin, isFalse);
      expect(plan.tokenProvider.hasToken, isTrue);
    });
  });
}

/// 测试便利:同步塞入内存凭证(store.save 是异步但内存实现即时生效)。
extension on MemoryCredentialStore {
  void _saveSync(StoredCredentials c) => save(c);
}
