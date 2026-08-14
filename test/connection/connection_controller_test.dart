// ConnectionController 故障注入测试(PLAN M1 验收:拔线/杀主机/超时)。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

import '../helpers/fake_dsh_host.dart';

void main() {
  late FakeDshHost host;
  late ConnectionController controller;

  setUp(() async {
    host = await FakeDshHost.start();
    controller = ConnectionController(
      baseUri: host.baseUri,
      initialBackoff: const Duration(milliseconds: 40),
      maxBackoff: const Duration(milliseconds: 200),
      probeTimeout: const Duration(milliseconds: 400),
    );
  });

  tearDown(() async {
    await controller.dispose();
    await host.stop();
  });

  test('ready handshake: both sockets + describe → ready snapshot', () async {
    controller.start();
    final snap = await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 3));
    expect(snap.describe, isNotNull);
    expect(snap.describe!.version, '0.0.1-fake');
    expect(snap.generation, 1);
  });

  test('frames flow: fake mux frame reaches muxFrames broadcast', () async {
    controller.start();
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 3));
    final frameFuture = controller.muxFrames.first.timeout(const Duration(seconds: 3));
    host.sendMuxFrame({
      'type': 'session/subscribed',
      'sessionId': 'session-frame-test',
      'lastSeq': 7,
    });
    final frame = await frameFuture;
    expect(frame, isA<MuxFrameSessionSubscribed>());
    expect((frame as MuxFrameSessionSubscribed).lastSeq, 7);
  });

  test('unplug one socket: generation invalidates and rebuilds', () async {
    controller.start();
    final ready1 = await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 3));
    expect(ready1.generation, 1);

    // 拔 mux 线:必须先 down(同一代),再 ready(新代,gen=2)。
    final downFuture = controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.down)
        .timeout(const Duration(seconds: 3));
    final ready2Future = controller.snapshots
        .firstWhere((s) => s.generation > ready1.generation && s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 5));
    host.unplugMux();
    final down = await downFuture;
    expect(down.generation, 1);
    expect(down.failureReason, contains('mux'));
    final ready2 = await ready2Future;
    expect(ready2.generation, 2);
    expect(ready2.describe, isNotNull);
  });

  test('host killed: down + retry; host back: ready again', () async {
    controller.start();
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 3));
    final port = host.port;
    await host.stop();

    final down = await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.down)
        .timeout(const Duration(seconds: 5));
    expect(down.failureReason, isNotNull);

    // 主机在同一个端口复活;控制器应靠退避重试拿到新代 ready。
    host = await FakeDshHost.startOnPort(port);
    final ready = await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready && s.generation > down.generation)
        .timeout(const Duration(seconds: 10));
    expect(ready.describe!.version, '0.0.1-fake');
  });

  test('handshake timeout counts as invalidation and retries', () async {
    host.hangDescribe = true;
    controller.start();
    // describe 挂起 → 握手不成功 → 永远不 ready;停止挂起后应转 ready。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final connecting = controller.current;
    expect(connecting, isNotNull);
    expect(connecting!.phase == ConnectionPhase.connecting || connecting.phase == ConnectionPhase.down, isTrue);
    host.hangDescribe = false;
    final ready = await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready)
        .timeout(const Duration(seconds: 10));
    expect(ready.describe, isNotNull);
  });
}
