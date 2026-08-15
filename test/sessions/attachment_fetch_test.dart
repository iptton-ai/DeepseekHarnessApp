// AttachmentFetcher 域测试(W2-C):base64 解码、LRU 淘汰(张数/字节/访问序)、
// single-flight、错误传播、缓存命中零请求、session 隔离。
// 模式:自建最小假主机(只服务 POST /api/session.attachment),不 import 共享 helper。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/sessions/attachment_fetch.dart';

/// 最小假主机:只服务 /api/session.attachment;按 attachmentId 编程应答
/// (serve=成功值 / fail=业务错误 / 未登记=generic 业务错误)。
class _FakeHost {
  _FakeHost._(this._server);
  final HttpServer _server;
  final Map<String, Map<String, dynamic>?> _valueById = {};
  final Map<String, String> _errorCodeById = {};
  final List<String> requestedAttachmentIds = [];
  int requestCount = 0;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeHost._(server);
    server.listen((req) => host._handle(req));
    return host;
  }

  /// 登记成功应答:value = {attachment: ref, data: base64}。
  void serve(String attachmentId, String data,
      {int width = 1, int height = 1, String mediaType = 'image/png', String? name}) {
    _valueById[attachmentId] = <String, dynamic>{
      'attachment': <String, dynamic>{
        'attachmentId': attachmentId,
        'mediaType': mediaType,
        'bytes': data.length,
        'width': width,
        'height': height,
        if (name != null) 'name': name,
      },
      'data': data,
    };
    _errorCodeById.remove(attachmentId);
  }

  /// 登记业务失败应答。
  void fail(String attachmentId,
      {String code = 'session-not-found', String message = 'no such attachment'}) {
    _valueById.remove(attachmentId);
    _errorCodeById[attachmentId] = '$code\u0000$message';
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.method == 'POST' && req.uri.path == '/api/session.attachment') {
      requestCount += 1;
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      final attachmentId = payload['attachmentId'] as String;
      requestedAttachmentIds.add(attachmentId);
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      final value = _valueById[attachmentId];
      if (value != null) {
        req.response.write(jsonEncode(<String, dynamic>{
          'type': 'server-response',
          'rpcId': envelope['rpcId'],
          'result': <String, dynamic>{'ok': true, 'value': value},
        }));
      } else {
        final err = _errorCodeById[attachmentId] ?? 'session-not-found\u0000unknown attachment';
        final parts = err.split('\u0000');
        req.response.write(jsonEncode(<String, dynamic>{
          'type': 'server-response',
          'rpcId': envelope['rpcId'],
          'result': <String, dynamic>{
            'ok': false,
            'error': <String, dynamic>{
              'code': parts[0],
              'message': parts[1],
              'details': <String, dynamic>{},
            },
          },
        }));
      }
      await req.response.close();
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }
}

/// 'hello 123' 的 base64。
const String kHello64 = 'aGVsbG8gMTIz';
/// 'ABCDEF' 的 base64(6 字节)。
const String kSixBytes64 = 'QUJDREVG';
/// 'GHIJKL' 的 base64(6 字节)。
const String kSixBytes64b = 'R0hJSktM';

void main() {
  late _FakeHost host;
  late ApiClient api;

  setUp(() async {
    host = await _FakeHost.start();
    api = ApiClient(baseUri: host.baseUri);
  });

  tearDown(() async {
    api.dispose();
    await host.stop();
  });

  test('base64 解码:字节内容与 host 提供的 data 一致', () async {
    host.serve('a1', kHello64);
    final fetcher = AttachmentFetcher(api: api);
    final got = await fetcher.fetch('s1', 'a1');
    expect(got.bytes, base64Decode(kHello64));
    expect(utf8.decode(got.bytes), 'hello 123');
  });

  test('ref 原样透传:attachmentId/mediaType/width/height/name', () async {
    host.serve('a2', kHello64,
        width: 320, height: 240, mediaType: 'image/jpeg', name: 'photo.jpg');
    final fetcher = AttachmentFetcher(api: api);
    final got = await fetcher.fetch('s1', 'a2');
    expect(got.ref.attachmentId, 'a2');
    expect(got.ref.mediaType, 'image/jpeg');
    expect(got.ref.width, 320);
    expect(got.ref.height, 240);
    expect(got.ref.name, 'photo.jpg');
    expect(got.ref.bytes, kHello64.length);
  });

  test('缓存命中零请求:同一 key 二次 fetch 不再发 RPC 且同一实例', () async {
    host.serve('a3', kHello64);
    final fetcher = AttachmentFetcher(api: api);
    final first = await fetcher.fetch('s1', 'a3');
    final second = await fetcher.fetch('s1', 'a3');
    expect(identical(first, second), isTrue);
    expect(host.requestCount, 1);
    expect(fetcher.cacheEntries, 1);
  });

  test('LRU 按张数淘汰:超上限逐出最旧,重取触发新请求', () async {
    final fetcher = AttachmentFetcher(api: api, maxCacheEntries: 2);
    host.serve('a1', kHello64);
    host.serve('a2', kHello64);
    host.serve('a3', kHello64);
    await fetcher.fetch('s1', 'a1');
    await fetcher.fetch('s1', 'a2');
    await fetcher.fetch('s1', 'a3'); // 逐出 a1
    expect(fetcher.cacheEntries, 2);
    expect(fetcher.cacheBytes, 2 * base64Decode(kHello64).length);
    await fetcher.fetch('s1', 'a1'); // a1 已逐出 → 新请求
    expect(host.requestCount, 4);
  });

  test('LRU 按字节淘汰:累计字节超上限逐出最旧', () async {
    final fetcher = AttachmentFetcher(api: api, maxCacheBytes: 10);
    host.serve('a1', kSixBytes64); // 6 字节
    host.serve('a2', kSixBytes64b); // 6 字节
    await fetcher.fetch('s1', 'a1');
    await fetcher.fetch('s1', 'a2'); // 12 > 10 → 逐出 a1
    expect(fetcher.cacheEntries, 1);
    expect(fetcher.cacheBytes, 6);
    await fetcher.fetch('s1', 'a1'); // 重新请求
    expect(host.requestCount, 3);
  });

  test('LRU 访问序刷新:命中条目不被逐出,未命中条目被逐出', () async {
    final fetcher = AttachmentFetcher(api: api, maxCacheEntries: 2);
    host.serve('a1', kHello64);
    host.serve('a2', kHello64);
    host.serve('a3', kHello64);
    await fetcher.fetch('s1', 'a1'); // 1
    await fetcher.fetch('s1', 'a2'); // 2
    await fetcher.fetch('s1', 'a1'); // 命中,刷新 a1 访问序(a1 最新)
    await fetcher.fetch('s1', 'a3'); // 3,逐出最旧的 a2 → 缓存 [a1, a3]
    expect(fetcher.cacheEntries, 2);
    await fetcher.fetch('s1', 'a1'); // 命中 → 零请求(最近访问的 a1 未被逐出)
    await fetcher.fetch('s1', 'a2'); // 4,已逐出 → 新请求
    expect(host.requestCount, 4);
  });

  test('single-flight:并发同 id 只发一次 RPC,共享结果', () async {
    host.serve('a1', kHello64);
    final fetcher = AttachmentFetcher(api: api);
    final results = await Future.wait(<Future<FetchedAttachment>>[
      fetcher.fetch('s1', 'a1'),
      fetcher.fetch('s1', 'a1'),
      fetcher.fetch('s1', 'a1'),
    ]);
    expect(host.requestCount, 1);
    expect(host.requestedAttachmentIds.length, 1);
    expect(results.map((r) => utf8.decode(r.bytes)).toSet(), <String>{'hello 123'});
    // 请求结束后缓存命中 → 仍零请求。
    final hit = await fetcher.fetch('s1', 'a1');
    expect(host.requestCount, 1);
    expect(identical(hit, results.first), isTrue);
  });

  test('错误传播:业务错误抛 RpcBusinessError,失败不缓存(重试重新请求)', () async {
    host.fail('a1', code: 'session-not-found');
    final fetcher = AttachmentFetcher(api: api);
    await expectLater(
        fetcher.fetch('s1', 'a1'), throwsA(isA<RpcBusinessError>()));
    // 失败未入缓存 → 再次 fetch 仍发请求(仍失败)。
    await expectLater(
        fetcher.fetch('s1', 'a1'), throwsA(isA<RpcBusinessError>()));
    expect(host.requestCount, 2);
    // 修复后 fetch 成功。
    host.serve('a1', kHello64);
    final got = await fetcher.fetch('s1', 'a1');
    expect(utf8.decode(got.bytes), 'hello 123');
    expect(host.requestCount, 3);
  });

  test('错误传播:非法 base64 抛 FormatException,不缓存', () async {
    host.serve('a1', '!!!not-base64!!!');
    final fetcher = AttachmentFetcher(api: api);
    await expectLater(fetcher.fetch('s1', 'a1'), throwsA(isA<FormatException>()));
    expect(fetcher.cacheEntries, 0);
    // 修复后重试成功。
    host.serve('a1', kHello64);
    final got = await fetcher.fetch('s1', 'a1');
    expect(utf8.decode(got.bytes), 'hello 123');
  });

  test('缓存 key 含 sessionId:同 attachmentId 不同会话各自拉取/各自命中', () async {
    host.serve('a1', kHello64);
    final fetcher = AttachmentFetcher(api: api);
    await fetcher.fetch('s1', 'a1');
    await fetcher.fetch('s2', 'a1');
    expect(host.requestCount, 2);
    await fetcher.fetch('s1', 'a1');
    await fetcher.fetch('s2', 'a1');
    expect(host.requestCount, 2); // 各命中各自缓存
    expect(fetcher.cacheEntries, 2);
  });

  test('single-flight 失败后 in-flight 清空:可再次发起新请求', () async {
    host.fail('a1');
    final fetcher = AttachmentFetcher(api: api);
    await expectLater(
        fetcher.fetch('s1', 'a1'), throwsA(isA<RpcBusinessError>()));
    // in-flight 表已清:修复后立即重试成功(不是复用失败 Future)。
    host.serve('a1', kHello64);
    final got = await fetcher.fetch('s1', 'a1');
    expect(utf8.decode(got.bytes), 'hello 123');
    expect(host.requestCount, 2);
  });

  test('缓存字节上限与张数上限同时生效:先到先清', () async {
    final fetcher = AttachmentFetcher(
        api: api, maxCacheBytes: 10, maxCacheEntries: 1);
    host.serve('a1', kHello64);
    host.serve('a2', kHello64);
    await fetcher.fetch('s1', 'a1');
    await fetcher.fetch('s1', 'a2'); // 张数上限 1 → 逐出 a1
    expect(fetcher.cacheEntries, 1);
    expect(fetcher.cacheBytes, base64Decode(kHello64).length);
    await fetcher.fetch('s1', 'a1');
    expect(host.requestCount, 3);
  });
}
