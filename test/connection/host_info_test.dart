// HostStatusController 单元:连接就绪 → GET /pair/api/host 探测机器名;
// 失败静默保持种子;authed 动态刷新;seed 注入。
// 本地 HttpServer 扮 dsh-mobile plugin(/pair/api/host),真实 ApiClient 直连。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/connection/host_info.dart';

void main() {
  late HttpServer server;
  late ApiClient api;
  String? respondWith;
  int hits = 0;

  setUp(() async {
    hits = 0;
    respondWith = jsonEncode({
      'ok': true,
      'label': '书房的 Mac mini',
      'hostname': 'mac-mini.local',
      'port': 13100,
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      hits += 1;
      if (req.uri.path == '/pair/api/host' && respondWith != null) {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(respondWith)
          ..close();
      } else {
        req.response
          ..statusCode = HttpStatus.notFound
          ..close();
      }
    });
    api = ApiClient(baseUri: Uri.parse('http://127.0.0.1:${server.port}'));
  });

  tearDown(() async {
    api.dispose();
    await server.close(force: true);
  });

  HostStatusController make({
    required StreamController<ConnectionSnapshot> snaps,
    required bool authed,
    String seed = '',
  }) {
    return HostStatusController(
      snapshots: snaps.stream,
      current: () => null,
      api: api,
      authed: () => authed,
      seedMachine: seed,
    );
  }

  test('就绪 → 探测 label;重连同代只探一次', () async {
    final snaps = StreamController<ConnectionSnapshot>.broadcast();
    final c = make(snaps: snaps, authed: true)..start();
    addTearDown(() => c.dispose());

    snaps.add(const ConnectionSnapshot(generation: 1, phase: ConnectionPhase.connecting));
    await Future<void>.delayed(Duration.zero);
    expect(c.status.value.up, isFalse);

    snaps.add(const ConnectionSnapshot(generation: 1, phase: ConnectionPhase.ready));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.status.value.up, isTrue);
    expect(c.status.value.machine, '书房的 Mac mini');

    // 同代重复 ready 快照不重复探测。
    final before = hits;
    snaps.add(const ConnectionSnapshot(generation: 1, phase: ConnectionPhase.ready));
    await Future<void>.delayed(Duration.zero);
    expect(hits, before);
  });

  test('换代重连会重探(宿主可能改过名)', () async {
    final snaps = StreamController<ConnectionSnapshot>.broadcast();
    final c = make(snaps: snaps, authed: true)..start();
    addTearDown(() => c.dispose());

    snaps.add(const ConnectionSnapshot(generation: 1, phase: ConnectionPhase.ready));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    respondWith = jsonEncode({
      'ok': true,
      'label': '改名后的 Mac',
      'hostname': 'mac-mini.local',
      'port': 13100,
    });
    snaps.add(const ConnectionSnapshot(generation: 2, phase: ConnectionPhase.ready));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.status.value.machine, '改名后的 Mac');
  });

  test('plugin 缺席(404)静默保持种子;label 空回落 hostname', () async {
    final snaps = StreamController<ConnectionSnapshot>.broadcast();
    respondWith = null; // 404
    final c = make(snaps: snaps, authed: true, seed: '凭证快照名')..start();
    addTearDown(() => c.dispose());

    snaps.add(const ConnectionSnapshot(generation: 1, phase: ConnectionPhase.ready));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.status.value.machine, '凭证快照名');

    // label 空但 hostname 有 → 用 hostname 短名。
    respondWith = jsonEncode(
        {'ok': true, 'label': '', 'hostname': 'mac-mini.local', 'port': 13100});
    snaps.add(const ConnectionSnapshot(generation: 2, phase: ConnectionPhase.ready));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.status.value.machine, 'mac-mini');
  });

  test('refreshAuthed / seedMachine 更新通知', () async {
    final snaps = StreamController<ConnectionSnapshot>.broadcast();
    var authed = false;
    final c = HostStatusController(
      snapshots: snaps.stream,
      current: () => null,
      api: api,
      authed: () => authed,
    )..start();
    addTearDown(() => c.dispose());

    expect(c.status.value.authed, isFalse);
    authed = true;
    c.refreshAuthed();
    expect(c.status.value.authed, isTrue);

    c.seedMachine('配对回显');
    expect(c.status.value.machine, '配对回显');
    c.seedMachine(''); // 空种子忽略
    expect(c.status.value.machine, '配对回显');
  });
}
