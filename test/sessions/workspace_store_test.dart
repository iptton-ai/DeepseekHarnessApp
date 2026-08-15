// WorkspaceStore 域测试(W1-A):自建最小假主机(不 import 共享 helper)。
// 覆盖:list 装载分组、create/rename/delete/insertBefore/insertSessionBefore/
// archiveSession 的信封与落地(不等重取)、host 帧触发全量重取、
// 代际翻转重取、业务错误(title-invalid)传播。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 最小假主机:describe + 双 WS + workspace.* RPC(可编程业务错误)。
/// 所有信封回显 rpcId;workspace 变更方法在服务端侧真实落地,
/// 便于断言"本地落地 = 服务端权威"。
class FakeWorkspaceHost {
  FakeWorkspaceHost._(this._server);
  final HttpServer _server;
  final muxSockets = <WebSocket>[];
  final hostSockets = <WebSocket>[];
  int _frameNo = 0;

  int listCalls = 0;
  final createRequests = <Map<String, dynamic>>[];
  final renameRequests = <Map<String, dynamic>>[];
  final deleteRequests = <Map<String, dynamic>>[];
  final insertBeforeRequests = <Map<String, dynamic>>[];
  final insertSessionBeforeRequests = <Map<String, dynamic>>[];
  final archiveRequests = <Map<String, dynamic>>[];
  bool rejectRename = false; // true → title-invalid

  List<Map<String, dynamic>> workspaces = <Map<String, dynamic>>[
    <String, dynamic>{
      'workspaceId': 'ws-1',
      'path': '/tmp/a',
      'title': 'A',
      'sessionIds': <String>['s-1', 's-2'],
      'createdAt': '2026-08-14T00:00:00Z',
      'updatedAt': '2026-08-14T00:00:00Z',
    },
    <String, dynamic>{
      'workspaceId': 'ws-2',
      'path': '/tmp/b',
      'title': 'B',
      'sessionIds': <String>[],
      'createdAt': '2026-08-14T00:00:00Z',
      'updatedAt': '2026-08-14T00:00:00Z',
    },
  ];
  List<String> archivedSessionIds = <String>[];

  static Future<FakeWorkspaceHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = FakeWorkspaceHost._(server);
    server.listen((req) => host._handle(req));
    return host;
  }

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    // WS 升级优先处理(读取 body 会破坏 upgrade)。
    if (path == '/api/events.mux' || path == '/api/events.host') {
      final ws = await WebSocketTransformer.upgrade(req);
      final sink = path.endsWith('mux') ? muxSockets : hostSockets;
      sink.add(ws);
      ws.listen((_) {}, onDone: () => sink.remove(ws));
      return;
    }
    final body = await utf8.decoder.bind(req).join();
    final envelope = jsonDecode(body) as Map<String, dynamic>;
    final rpcId = envelope['rpcId'] as String;
    final payload =
        (envelope['payload'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    switch (path) {
      case '/api/host.describe':
        await _ok(req, rpcId, <String, dynamic>{
          'version': '0.0.1-fake',
          'cwd': '/tmp/fake',
          'provider': 'fake',
          'model': 'fake-model',
          'attachedSessions': 0,
          'canOpenPath': false,
        });
        return;
      case '/api/workspace.list':
        listCalls += 1;
        await _ok(req, rpcId, <String, dynamic>{
          'items': workspaces,
          'archivedSessionIds': archivedSessionIds,
        });
        return;
      case '/api/workspace.create':
        createRequests.add(payload);
        final ws = <String, dynamic>{
          'workspaceId': 'ws-new',
          'path': payload['path'],
          'title': (payload['path'] as String).split('/').last,
          'sessionIds': <String>[],
          'createdAt': '2026-08-15T00:00:00Z',
          'updatedAt': '2026-08-15T00:00:00Z',
        };
        workspaces = List<Map<String, dynamic>>.of(workspaces)..add(ws);
        await _ok(req, rpcId, <String, dynamic>{
          'workspace': ws,
          'created': true,
        });
        return;
      case '/api/workspace.rename':
        renameRequests.add(payload);
        final title = (payload['title'] as String).trim();
        if (title.isEmpty || rejectRename) {
          await _bizError(req, rpcId, 'title-invalid', <String, dynamic>{});
          return;
        }
        final updated = <String, dynamic>{
          ..._workspaceById(payload['workspaceId'] as String),
          'title': title,
        };
        _replace(updated);
        await _ok(req, rpcId, <String, dynamic>{'workspace': updated});
        return;
      case '/api/workspace.delete':
        deleteRequests.add(payload);
        workspaces = <Map<String, dynamic>>[
          for (final w in workspaces)
            if (w['workspaceId'] != payload['workspaceId']) w,
        ];
        await _ok(req, rpcId, <String, dynamic>{'deleted': true});
        return;
      case '/api/workspace.insertBefore':
        insertBeforeRequests.add(payload);
        final ids = <String>[for (final w in workspaces) w['workspaceId'] as String];
        ids.remove(payload['workspaceId'] as String);
        final before = payload['beforeWorkspaceId'] as String?;
        if (before != null && ids.contains(before)) {
          ids.insert(ids.indexOf(before), payload['workspaceId'] as String);
        } else {
          ids.insert(0, payload['workspaceId'] as String);
        }
        await _ok(req, rpcId, <String, dynamic>{'workspaceIds': ids});
        return;
      case '/api/workspace.insertSessionBefore':
        insertSessionBeforeRequests.add(payload);
        final updated = <String, dynamic>{
          ..._workspaceById(payload['workspaceId'] as String),
        };
        final sids = List<String>.from(updated['sessionIds'] as List);
        sids.remove(payload['sessionId'] as String);
        final beforeSid = payload['beforeSessionId'] as String?;
        if (beforeSid != null && sids.contains(beforeSid)) {
          sids.insert(sids.indexOf(beforeSid), payload['sessionId'] as String);
        } else {
          sids.add(payload['sessionId'] as String);
        }
        updated['sessionIds'] = sids;
        _replace(updated);
        await _ok(req, rpcId, <String, dynamic>{'workspace': updated});
        return;
      case '/api/workspace.archiveSession':
        archiveRequests.add(payload);
        final sid = payload['sessionId'] as String;
        if (!archivedSessionIds.contains(sid)) {
          archivedSessionIds = List<String>.of(archivedSessionIds)..add(sid);
        }
        await _ok(req, rpcId,
            <String, dynamic>{'archivedSessionIds': archivedSessionIds});
        return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  Map<String, dynamic> _workspaceById(String id) {
    return workspaces.firstWhere((w) => w['workspaceId'] == id);
  }

  void _replace(Map<String, dynamic> updated) {
    workspaces = <Map<String, dynamic>>[
      for (final w in workspaces)
        w['workspaceId'] == updated['workspaceId'] ? updated : w,
    ];
  }

  Future<void> _ok(HttpRequest req, String rpcId, Map<String, dynamic> value) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(<String, dynamic>{
      'type': 'server-response',
      'rpcId': rpcId,
      'result': <String, dynamic>{'ok': true, 'value': value},
    }));
    await req.response.close();
  }

  Future<void> _bizError(HttpRequest req, String rpcId, String code,
      Map<String, dynamic> details) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(<String, dynamic>{
      'type': 'server-response',
      'rpcId': rpcId,
      'result': <String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': code,
          'message': code,
          'details': details,
        },
      },
    }));
    await req.response.close();
  }

  /// 从 host 流推一帧(server-request 信封)。
  void sendHostFrame(Map<String, dynamic> payload) {
    _frameNo += 1;
    for (final ws in hostSockets) {
      ws.add(jsonEncode(<String, dynamic>{
        'type': 'server-request',
        'rpcId': 'host-frame-$_frameNo',
        'method': payload['type'] as String,
        'payload': payload,
      }));
    }
  }

  /// 只关 mux socket(留 host 存活),触发代际重建。
  void unplugMux() {
    for (final ws in muxSockets.toList()) {
      ws.close(1001, 'unplugged');
    }
    muxSockets.clear();
  }

  Future<void> stop() async {
    for (final ws in <WebSocket>[...muxSockets, ...hostSockets]) {
      try {
        await ws.close();
      } catch (_) {}
    }
    muxSockets.clear();
    hostSockets.clear();
    await _server.close(force: true);
  }
}

/// 轮询等待条件成立(刷新/重取是异步的)。
Future<void> waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late FakeWorkspaceHost host;
  late ConnectionController controller;
  late ApiClient api;
  late WorkspaceStore store;

  setUp(() async {
    host = await FakeWorkspaceHost.start();
    controller = ConnectionController(
      baseUri: host.baseUri,
      initialBackoff: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 150),
      probeTimeout: const Duration(milliseconds: 400),
    );
    api = ApiClient(baseUri: host.baseUri);
    store = WorkspaceStore(api: api, connection: controller);
  });

  tearDown(() async {
    await store.dispose();
    await controller.dispose();
    api.dispose();
    await host.stop();
  });

  test('ready → workspace.list 装载分组与归档集合', () async {
    controller.start();
    store.start();
    final list = await store.workspaces.first.timeout(const Duration(seconds: 3));
    expect(list, hasLength(2));
    expect(list.first.workspaceId, 'ws-1');
    expect(list.first.sessionIds, <String>['s-1', 's-2']);
    expect(list.first.title, 'A');
    expect(store.currentWorkspaces, hasLength(2));
    expect(store.currentArchivedSessionIds, isEmpty);
    expect(store.listCalls, greaterThanOrEqualTo(1));
  });

  test('create:信封正确,响应落地并广播,不等重取', () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final before = store.listCalls;
    final next = store.workspaces.first.timeout(const Duration(seconds: 3));
    final value = await store.create('/tmp/c');
    expect(value.created, isTrue);
    expect(value.workspace.workspaceId, 'ws-new');
    expect(value.workspace.title, 'c');
    expect(host.createRequests, hasLength(1));
    expect(host.createRequests.single['path'], '/tmp/c');
    // 落地:currentWorkspaces 立即可见,且未触发重取。
    expect(store.currentWorkspaces.map((w) => w.workspaceId), contains('ws-new'));
    expect(store.listCalls, before);
    final list = await next;
    expect(list.map((w) => w.workspaceId), contains('ws-new'));
  });

  test('rename:信封正确,title 落地替换并广播', () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final next = store.workspaces.first.timeout(const Duration(seconds: 3));
    final value = await store.rename('ws-1', 'Alpha');
    expect(value.workspace.title, 'Alpha');
    expect(host.renameRequests, hasLength(1));
    expect(host.renameRequests.single, <String, dynamic>{
      'workspaceId': 'ws-1',
      'title': 'Alpha',
    });
    final list = await next;
    expect(
        list.firstWhere((w) => w.workspaceId == 'ws-1').title, 'Alpha');
  });

  test('delete:信封正确,本地移除并广播', () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final next = store.workspaces.first.timeout(const Duration(seconds: 3));
    final value = await store.delete('ws-2');
    expect(value.deleted, isTrue);
    expect(host.deleteRequests, hasLength(1));
    expect(host.deleteRequests.single['workspaceId'], 'ws-2');
    final list = await next;
    expect(list.map((w) => w.workspaceId), isNot(contains('ws-2')));
  });

  test('insertBefore:信封正确,按响应排序落地并广播', () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final next = store.workspaces.first.timeout(const Duration(seconds: 3));
    final value = await store.insertBefore('ws-2', beforeWorkspaceId: 'ws-1');
    expect(value.workspaceIds, <String>['ws-2', 'ws-1']);
    expect(host.insertBeforeRequests, hasLength(1));
    expect(host.insertBeforeRequests.single, <String, dynamic>{
      'workspaceId': 'ws-2',
      'beforeWorkspaceId': 'ws-1',
    });
    final list = await next;
    expect(list.map((w) => w.workspaceId).toList(), <String>['ws-2', 'ws-1']);
  });

  test('insertSessionBefore:信封正确,响应 WorkspaceView 落地(sessionIds 重排)',
      () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final next = store.workspaces.first.timeout(const Duration(seconds: 3));
    final value = await store.insertSessionBefore('ws-1', 's-2',
        beforeSessionId: 's-1');
    expect(value.workspace.sessionIds, <String>['s-2', 's-1']);
    expect(host.insertSessionBeforeRequests, hasLength(1));
    expect(host.insertSessionBeforeRequests.single, <String, dynamic>{
      'workspaceId': 'ws-1',
      'sessionId': 's-2',
      'beforeSessionId': 's-1',
    });
    final list = await next;
    expect(
        list.firstWhere((w) => w.workspaceId == 'ws-1').sessionIds,
        <String>['s-2', 's-1']);
  });

  test('archiveSession:信封正确,归档集合更新并广播', () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final next = store.archivedSessionIds.first.timeout(const Duration(seconds: 3));
    final value = await store.archiveSession('s-1');
    expect(value.archivedSessionIds, contains('s-1'));
    expect(host.archiveRequests, hasLength(1));
    expect(host.archiveRequests.single['sessionId'], 's-1');
    final ids = await next;
    expect(ids, contains('s-1'));
    expect(store.isArchived('s-1'), isTrue);
    expect(store.isArchived('s-2'), isFalse);
  });

  test('host/workspace-changed 帧触发全量重取并落地新状态', () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final before = store.listCalls;
    // 主机侧改数据后推帧;客户端应重取到新标题。
    final updated = <String, dynamic>{
      ...host.workspaces.first,
      'title': 'A2',
    };
    host.workspaces = <Map<String, dynamic>>[
      updated,
      ...host.workspaces.skip(1),
    ];
    host.sendHostFrame(<String, dynamic>{
      'type': 'host/workspace-changed',
      'workspace': updated,
    });
    await waitFor(() => host.listCalls > before);
    expect(host.listCalls, greaterThan(before));
    await waitFor(() => store.currentWorkspaces.first.title == 'A2');
    expect(store.currentWorkspaces.first.title, 'A2');
  });

  test('host/archived-sessions-changed 帧触发重取并更新归档集合', () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final before = store.listCalls;
    host.archivedSessionIds = <String>['s-9'];
    host.sendHostFrame(<String, dynamic>{
      'type': 'host/archived-sessions-changed',
      'archivedSessionIds': <String>['s-9'],
    });
    await waitFor(() => host.listCalls > before);
    await waitFor(() => store.isArchived('s-9'));
    expect(store.isArchived('s-9'), isTrue);
    expect(store.currentArchivedSessionIds, contains('s-9'));
  });

  test('rename 业务错误:title-invalid 抛出且本地状态不变', () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final beforeTitle = store.currentWorkspaces.first.title;
    await expectLater(
      store.rename('ws-1', ''),
      throwsA(isA<RpcBusinessError>()
          .having((e) => e.error, 'error', isA<RpcErrorTitleInvalid>())),
    );
    // 失败不落地:状态不变,也不广播。
    expect(store.currentWorkspaces.first.title, beforeTitle);
    expect(host.renameRequests, hasLength(1));
  });

  test('代际翻转:新代 ready 后全量重取(无 since 续传)', () async {
    controller.start();
    store.start();
    await store.workspaces.first.timeout(const Duration(seconds: 3));
    final before = store.listCalls;
    // 拔线 → 新代 ready → workspace.list 必须再打一次。
    host.unplugMux();
    await controller.snapshots
        .firstWhere((s) => s.phase == ConnectionPhase.ready && s.generation >= 2)
        .timeout(const Duration(seconds: 5));
    await waitFor(() => store.listCalls > before);
    expect(store.listCalls, greaterThan(before));
    // 断网重连不丢状态:本地分组仍在。
    expect(store.currentWorkspaces, hasLength(2));
  });
}
