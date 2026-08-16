// M4 域测试:模型选择、搜索、fork、rename 投影落格、导出 ZIP。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/session_store.dart';

import '../helpers/fake_dsh_host.dart';

void main() {
  late FakeDshHost host;
  late ConnectionController controller;
  late ApiClient api;
  late SessionStore store;

  setUp(() async {
    host = await FakeDshHost.start();
    host.summaries.add(<String, dynamic>{
      'sessionId': 'session-s1',
      'updatedAt': 1786723600000,
      'running': false,
      'blank': false,
      'cwd': '/tmp/alpha',
    });
    host.summaries.add(<String, dynamic>{
      'sessionId': 'session-s2',
      'updatedAt': 1786723600001,
      'running': false,
      'blank': false,
      'cwd': '/tmp/beta',
    });
    host.sessions['session-s1'] = <Map<String, dynamic>>[];
    controller = ConnectionController(
      baseUri: host.baseUri,
      initialBackoff: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 150),
      probeTimeout: const Duration(milliseconds: 400),
    );
    api = ApiClient(baseUri: host.baseUri);
    store = SessionStore(api: api, connection: controller);
    controller.start();
    store.start();
    await store.summaries.first.timeout(const Duration(seconds: 3));
  });

  tearDown(() async {
    await store.dispose();
    await controller.dispose();
    api.dispose();
    await host.stop();
  });

  test('sessionModels parses catalog with reasoning efforts', () async {
    final value = await store.sessionModels('session-s1');
    expect(value.routable, isTrue);
    expect(value.current.provider, 'fake');
    expect(value.groups, hasLength(1));
    final group = value.groups.single;
    expect(group.models, hasLength(2));
    final first = group.models.first;
    expect(first.reasoning, isNotNull);
    expect(first.reasoning!.efforts.map((e) => e.id), containsAll(['low', 'high']));
    expect(first.reasoning!.defaultEffort, 'high');
  });

  test('selectModel round trips with optional reasoningEffort', () async {
    final v1 = await store.selectModel('session-s1', provider: 'fake', model: 'fake-mini');
    expect(v1.selected.model, 'fake-mini');
    expect(v1.selected.reasoningEffort, isNull);
    final v2 = await store.selectModel('session-s1',
        provider: 'fake', model: 'fake-model', reasoningEffort: 'high');
    expect(v2.selected.reasoningEffort, 'high');
  });

  test('search matches by query and returns snippets', () async {
    final value = await store.sessionSearch('alpha');
    expect(value.items, hasLength(1));
    expect(value.items.single.sessionId, 'session-s1');
    expect(value.hasMore, isFalse);
  });

  test('fork clones into a new session id', () async {
    final value = await store.forkSession('session-s1');
    expect(value.sessionId, startsWith('session-fake-fork-'));
    // fork 后 refresh 已触发(异步):等列表长出来。
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (store.currentSummaries.length < 3 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(store.currentSummaries.length, greaterThanOrEqualTo(3));
  });

  test('rename writes normalized title into projection slot', () async {
    final value = await store.renameSession('session-s1', '  我的新标题  ');
    // 假主机 trim 规范化。
    expect(value.title, '我的新标题');
    final log = store.logFor('session-s1');
    // title 投影值是纯字符串(rc.6 wire 契约,非嵌套 map)。
    expect(log.projections['title'], '我的新标题');
    expect(log.projectionWatermark, 999);
  });

  test('exportSessionZip streams a ZIP to disk', () async {
    final tmp = Directory.systemTemp.createTempSync('singleman-export');
    final path = tmp.path + '/s1.zip';
    await store.exportSessionZip('session-s1', path);
    final bytes = File(path).readAsBytesSync();
    expect(bytes.length, greaterThanOrEqualTo(22));
    // EOCD 魔数 PK\x05\x06。
    expect(bytes[0], 0x50);
    expect(bytes[1], 0x4b);
    tmp.deleteSync(recursive: true);
  });
}
