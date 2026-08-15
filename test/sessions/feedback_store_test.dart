// FeedbackStore 域测试(W3-B):双层信封解析、CAS 冲突自动重读、
// 幂等删除、枚举校验、缓存/广播、重连代际失效 + onInvalidated。
// 模式:自建最小假主机(describe + messageFeedback/* + 双 WS 下行),
// 不 import 共享 helper。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/feedback_store.dart';

enum _ListMode { ok, innerError, outerError }

enum _PutMode { ok, versionConflict, noteTooLarge, innerError }

enum _DeleteMode { okAbsent, okDeleted, innerError }

/// 最小假主机:describe + messageFeedback/list|put|delete + 双 WS。
class _FakeHost {
  _FakeHost._(this._server);
  final HttpServer _server;
  final List<WebSocket> _mux = <WebSocket>[];
  final List<WebSocket> _host = <WebSocket>[];

  _ListMode listMode = _ListMode.ok;
  List<Map<String, dynamic>> listItems = <Map<String, dynamic>>[];
  Map<String, dynamic>? lastListPayload;
  _PutMode putMode = _PutMode.ok;
  Map<String, dynamic> putResult = <String, dynamic>{};
  Map<String, dynamic>? lastPutPayload;
  _DeleteMode deleteMode = _DeleteMode.okDeleted;
  Map<String, dynamic>? lastDeletePayload;

  Uri get baseUri => Uri.parse('http://127.0.0.1:' + _server.port.toString());

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost._(server);
    server.listen((req) => host._handle(req));
    return host;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/api/host.describe') {
      final envelope = await _readJson(req);
      await _respond(req, {
        'type': 'server-response',
        'rpcId': envelope['rpcId'],
        'result': {
          'ok': true,
          'value': {
            'version': '0.0.1-fake',
            'cwd': '/tmp/fake',
            'provider': 'fake',
            'model': 'fake-model',
            'attachedSessions': 0,
            'canOpenPath': false,
          },
        },
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/messageFeedback/list') {
      final envelope = await _readJson(req);
      lastListPayload = envelope['payload'] as Map<String, dynamic>;
      switch (listMode) {
        case _ListMode.ok:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': true,
              'value': {
                'ok': true,
                'value': <String, dynamic>{'items': listItems},
              },
            },
          });
        case _ListMode.innerError:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': true,
              'value': {
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'session-not-found',
                  'message': 'no such session',
                },
              },
            },
          });
        case _ListMode.outerError:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': false,
              'error': <String, dynamic>{
                'code': 'session-not-found',
                'message': 'no such session',
                'details': <String, dynamic>{},
              },
            },
          });
      }
      return;
    }
    if (req.method == 'POST' && path == '/api/messageFeedback/put') {
      final envelope = await _readJson(req);
      lastPutPayload = envelope['payload'] as Map<String, dynamic>;
      switch (putMode) {
        case _PutMode.ok:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': true,
              'value': {'ok': true, 'value': putResult},
            },
          });
        case _PutMode.versionConflict:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': true,
              'value': {
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'version-conflict',
                  'message': 'stale version',
                },
              },
            },
          });
        case _PutMode.noteTooLarge:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': true,
              'value': {
                'ok': false,
                'error': <String, dynamic>{
                  'code': 'note-too-large',
                  'message': 'note too large',
                },
              },
            },
          });
        case _PutMode.innerError:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': true,
              'value': {
                'ok': false,
                'error': <String, dynamic>{'code': 'boom', 'message': 'x'},
              },
            },
          });
      }
      return;
    }
    if (req.method == 'POST' && path == '/api/messageFeedback/delete') {
      final envelope = await _readJson(req);
      lastDeletePayload = envelope['payload'] as Map<String, dynamic>;
      switch (deleteMode) {
        case _DeleteMode.okAbsent:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': true,
              'value': {'ok': true, 'value': <String, dynamic>{'absent': true}},
            },
          });
        case _DeleteMode.okDeleted:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': true,
              'value': {'ok': true, 'value': <String, dynamic>{'absent': false}},
            },
          });
        case _DeleteMode.innerError:
          await _respond(req, {
            'type': 'server-response',
            'rpcId': envelope['rpcId'],
            'result': {
              'ok': true,
              'value': {
                'ok': false,
                'error': <String, dynamic>{'code': 'boom', 'message': 'x'},
              },
            },
          });
      }
      return;
    }
    if (path == '/api/events.mux' || path == '/api/events.host') {
      final ws = await WebSocketTransformer.upgrade(req);
      (path.endsWith('mux') ? _mux : _host).add(ws);
      ws.listen((_) {}, onDone: () {});
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<void> _respond(HttpRequest req, Map<String, dynamic> body) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> stop() async {
    for (final ws in [..._mux, ..._host]) {
      try {
        await ws.close();
      } catch (_) {}
    }
    await _server.close(force: true);
  }
}

Map<String, dynamic> _item(
  String messageId,
  String rating, {
  String? note,
  Object? version = 'v1',
  String createdAt = '2026-08-15T00:00:00Z',
  String updatedAt = '2026-08-15T00:00:00Z',
}) =>
    <String, dynamic>{
      'messageId': messageId,
      'rating': rating,
      if (note != null) 'note': note,
      'version': version,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };

void main() {
  group('FeedbackStore 域', () {
    late _FakeHost host;
    late ConnectionController controller;
    late ApiClient api;
    late FeedbackStore store;

    setUp(() async {
      host = await _FakeHost.start();
      controller = ConnectionController(
        baseUri: host.baseUri,
        initialBackoff: const Duration(milliseconds: 30),
        maxBackoff: const Duration(milliseconds: 150),
        probeTimeout: const Duration(milliseconds: 400),
      );
      api = ApiClient(
        baseUri: host.baseUri,
        defaultTimeout: const Duration(milliseconds: 300),
      );
      store = FeedbackStore(api: api, connection: controller);
      controller.start();
      await controller.snapshots
          .firstWhere((s) => s.phase == ConnectionPhase.ready)
          .timeout(const Duration(seconds: 3));
    });

    tearDown(() async {
      await store.dispose();
      await controller.dispose();
      api.dispose();
      await host.stop();
    });

    test('list 双层信封:items 模型解析 + payload {args:{request:{sessionId}}}',
        () async {
      host.listItems = [
        _item('m1', 'positive', note: '细节不错', version: 'v1'),
        _item('m2', 'negative'),
      ];
      final items = await store.list('session-s1');
      expect(items, hasLength(2));
      expect(items[0].messageId, 'm1');
      expect(items[0].rating, FeedbackRating.positive);
      expect(items[0].note, '细节不错');
      expect(items[0].version, 'v1');
      expect(items[0].createdAt, '2026-08-15T00:00:00Z');
      expect(items[0].updatedAt, '2026-08-15T00:00:00Z');
      expect(items[1].rating, FeedbackRating.negative);
      expect(items[1].note, isNull);
      expect(host.lastListPayload, <String, dynamic>{
        'args': <String, dynamic>{
          'request': <String, dynamic>{'sessionId': 'session-s1'},
        },
      });
      expect(store.listCalls, 1);
    });

    test('list 内层错误(session-not-found)→ FeedbackStoreException(code)',
        () async {
      host.listMode = _ListMode.innerError;
      await expectLater(
        store.list('session-s1'),
        throwsA(isA<FeedbackStoreException>()
            .having((e) => e.code, 'code', 'session-not-found')),
      );
      // 失败不缓存:再次调用仍走 HTTP。
      await expectLater(store.list('session-s1'),
          throwsA(isA<FeedbackStoreException>()));
      expect(store.listCalls, 2);
    });

    test('list 外层 RpcResult ok:false → FeedbackStoreException', () async {
      host.listMode = _ListMode.outerError;
      await expectLater(store.list('session-s1'),
          throwsA(isA<FeedbackStoreException>()));
    });

    test('缓存 per-session:同会话二次命中,异会话独立,force 重取', () async {
      host.listItems = [_item('m1', 'positive')];
      await store.list('session-s1');
      await store.list('session-s1');
      expect(store.listCalls, 1);
      await store.list('session-s2');
      expect(store.listCalls, 2);
      await store.list('session-s1', force: true);
      expect(store.listCalls, 3);
    });

    test('put CAS 成功:payload 形状 + 本地条目更新 + 广播', () async {
      host.listItems = [_item('m1', 'positive', note: 'x', version: 'v1')];
      await store.list('session-s1');
      var emissions = 0;
      final sub = store.changed.listen((_) => emissions++);
      host.putMode = _PutMode.ok;
      host.putResult = _item('m1', 'negative', note: 'y', version: 'v2');
      final item = await store.put('session-s1', 'm1', FeedbackRating.negative,
          note: 'y', ifVersion: 'v1');
      expect(item.rating, FeedbackRating.negative);
      expect(item.version, 'v2');
      expect(host.lastPutPayload, <String, dynamic>{
        'args': <String, dynamic>{
          'request': <String, dynamic>{
            'sessionId': 'session-s1',
            'messageId': 'm1',
            'rating': 'negative',
            'note': 'y',
            'ifVersion': 'v1',
          },
        },
      });
      expect(store.itemsFor('session-s1').single.rating,
          FeedbackRating.negative);
      expect(store.putCalls, 1);
      // 广播投递是异步微任务,先让事件循环 flush 再断言计数。
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(emissions, 1);
      await sub.cancel();
    });

    test('put ifVersion 缺席(创建语义):payload 无 ifVersion 字段', () async {
      host.putMode = _PutMode.ok;
      host.putResult = _item('m1', 'positive', version: 'v9');
      final item = await store.put('session-s1', 'm1', FeedbackRating.positive);
      expect(item.version, 'v9');
      final request =
          (host.lastPutPayload!['args'] as Map<String, dynamic>)['request']
              as Map<String, dynamic>;
      expect(request.containsKey('ifVersion'), isFalse);
      expect(request['rating'], 'positive');
      expect(request.containsKey('note'), isFalse);
    });

    test('put version-conflict → 自动重读 list + typed 异常携带权威条目',
        () async {
      host.listItems = [_item('m1', 'positive', version: 'v1')];
      await store.list('session-s1');
      final listCallsBefore = store.listCalls;
      host.putMode = _PutMode.versionConflict;
      // 冲突后权威条目:另一侧已评 + 新版本。
      host.listItems = [_item('m1', 'negative', version: 'v2')];
      await expectLater(
        store.put('session-s1', 'm1', FeedbackRating.positive, ifVersion: 'v1'),
        throwsA(isA<FeedbackVersionConflictException>()
            .having((e) => e.authoritative?.rating, 'rating',
                FeedbackRating.negative)
            .having((e) => e.authoritative?.version, 'version', 'v2')),
      );
      // 自动重读:list 再打一次,缓存刷新为权威条目。
      expect(store.listCalls, listCallsBefore + 1);
      expect(store.itemsFor('session-s1').single.rating,
          FeedbackRating.negative);
    });

    test('put note-too-large → FeedbackNoteTooLargeException', () async {
      host.putMode = _PutMode.noteTooLarge;
      await expectLater(
        store.put('session-s1', 'm1', FeedbackRating.positive,
            note: 'x' * 9000, ifVersion: 'v1'),
        throwsA(isA<FeedbackNoteTooLargeException>()),
      );
    });

    test('put 其他内层错误 → FeedbackStoreException(code)', () async {
      host.putMode = _PutMode.innerError;
      await expectLater(
        store.put('session-s1', 'm1', FeedbackRating.positive),
        throwsA(isA<FeedbackStoreException>()
            .having((e) => e.code, 'code', 'boom')),
      );
    });

    test('delete 幂等:absent:false 删除成功 + 缓存清除;absent:true 返回 true',
        () async {
      host.listItems = [_item('m1', 'positive', version: 'v1')];
      await store.list('session-s1');
      expect(store.itemsFor('session-s1'), hasLength(1));

      host.deleteMode = _DeleteMode.okDeleted;
      final deleted = await store.delete('session-s1', 'm1', ifVersion: 'v1');
      expect(deleted, isFalse); // 本次删除了既有条目。
      expect(host.lastDeletePayload, <String, dynamic>{
        'args': <String, dynamic>{
          'request': <String, dynamic>{
            'sessionId': 'session-s1',
            'messageId': 'm1',
            'ifVersion': 'v1',
          },
        },
      });
      expect(store.itemsFor('session-s1'), isEmpty);
      expect(store.deleteCalls, 1);

      // 幂等:条目已缺席 → absent:true(ifVersion 被忽略,仍可发)。
      host.deleteMode = _DeleteMode.okAbsent;
      final absent = await store.delete('session-s1', 'm1', ifVersion: 'v1');
      expect(absent, isTrue);
      expect(store.deleteCalls, 2);
    });

    test('delete 内层错误 → FeedbackStoreException', () async {
      host.deleteMode = _DeleteMode.innerError;
      await expectLater(
        store.delete('session-s1', 'm1'),
        throwsA(isA<FeedbackStoreException>()),
      );
    });

    test('代际翻转(重连)→ 缓存清空 + onInvalidated 回调', () async {
      var invalidated = 0;
      final s2 = FeedbackStore(
        api: api,
        connection: controller,
        onInvalidated: () => invalidated++,
      );
      addTearDown(s2.dispose);
      host.listItems = [_item('m1', 'positive', version: 'v1')];
      await s2.list('session-s1');
      expect(s2.itemsFor('session-s1'), hasLength(1));

      final gen = controller.current!.generation;
      controller.debugDropDownlinks();
      await controller.snapshots
          .firstWhere((s) =>
              s.phase == ConnectionPhase.ready && s.generation > gen)
          .timeout(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(invalidated, greaterThan(0));
      expect(s2.itemsFor('session-s1'), isEmpty);

      // 重连后重拉:缓存已清 → 走 HTTP。
      host.listItems = [_item('m1', 'negative', version: 'v2')];
      final items = await s2.list('session-s1');
      expect(items.single.rating, FeedbackRating.negative);
    });

    test('枚举校验:非法/缺失 rating → FeedbackItem.fromJson 抛 FormatException',
        () {
      expect(() => FeedbackItem.fromJson(_item('m1', 'like')),
          throwsFormatException);
      expect(
        () => FeedbackItem.fromJson(<String, dynamic>{
          'messageId': 'm1',
          'version': 1,
          'createdAt': 'c',
          'updatedAt': 'u',
        }),
        throwsFormatException,
      );
      // 合法枚举照常解析。
      final item = FeedbackItem.fromJson(_item('m1', 'positive', version: 3));
      expect(item.rating, FeedbackRating.positive);
      expect(item.version, 3);
    });
  });
}
