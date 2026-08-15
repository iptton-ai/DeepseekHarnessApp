// M6 远程网关形态:鉴权头注入 + 401 停链重登语义。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/connection/remote_auth.dart';

import '../helpers/fake_dsh_host.dart';

void main() {
  late FakeDshHost host;
  final tokens = MutableTokenProvider();

  setUp(() async {
    host = await FakeDshHost.start();
    host.requireBearerToken = 'valid-token';
    tokens.token = null;
  });

  tearDown(() async {
    await host.stop();
  });

  test('unauthorized: describe 401 → authBlocked, no retry loop', () async {
    tokens.token = 'revoked-token';
    final controller = ConnectionController(
      baseUri: host.baseUri,
      authHeaders: tokens.authHeaders,
      initialBackoff: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 80),
    );
    addTearDown(() => controller.dispose());

    controller.start();
    final snap = await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.down)
        .timeout(const Duration(seconds: 3));
    expect(snap.failureReason, 'unauthorized');
    expect(controller.authBlocked, isTrue);

    // 停链语义:不再有新代际(等若干个退避周期验证)。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(controller.current!.generation, 1,
        reason: '401 后不得继续重试握手');
  });

  test('resume after re-login: fresh token connects', () async {
    tokens.token = 'revoked-token';
    final controller = ConnectionController(
      baseUri: host.baseUri,
      authHeaders: tokens.authHeaders,
      initialBackoff: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 80),
    );
    addTearDown(() => controller.dispose());

    controller.start();
    await controller.snapshots
        .firstWhere((s) =>
            s.phase == ConnectionPhase.down && s.failureReason == 'unauthorized')
        .timeout(const Duration(seconds: 3));

    // 重新登录(原地刷新令牌供给)→ resume。
    tokens.token = 'valid-token';
    controller.resume();
    final ready = await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 3));
    expect(ready.describe, isNotNull);
    expect(controller.authBlocked, isFalse);
  });

  test('authorized headers reach describe and WS upgrade', () async {
    tokens.token = 'valid-token';
    final controller = ConnectionController(
      baseUri: host.baseUri,
      authHeaders: tokens.authHeaders,
    );
    addTearDown(() => controller.dispose());

    controller.start();
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 3));

    // describe(POST)+ mux/host WS upgrade 各自带上了 Bearer。
    expect(host.seenAuthorizations, containsAll(<String>[
      'Bearer valid-token',
      'Bearer valid-token',
      'Bearer valid-token',
    ]));
  });

  test('gateway disabled (direct form): no Authorization header sent',
      () async {
    host.requireBearerToken = null;
    tokens.token = null;
    final controller = ConnectionController(
      baseUri: host.baseUri,
      authHeaders: tokens.authHeaders,
    );
    addTearDown(() => controller.dispose());

    controller.start();
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 3));
    expect(host.seenAuthorizations, everyElement(''),
        reason: '直连形态不携带 Authorization');
  });
}
