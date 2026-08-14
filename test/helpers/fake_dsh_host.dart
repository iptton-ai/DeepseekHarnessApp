// 测试用假 DSH 主机:最小 describe + 双 WS 下行,可编程故障。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class FakeDshHost {
  FakeDshHost._(this._server, this.sockets);
  final HttpServer _server;
  final Set<WebSocket> sockets;
  final muxSockets = <WebSocket>[];
  final hostSockets = <WebSocket>[];

  int describeCalls = 0;
  bool hangDescribe = false;
  bool wrongRpcIdEcho = false;
  bool businessError = false;

  static Future<FakeDshHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _serve(server);
  }

  static Future<FakeDshHost> startOnPort(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    return _serve(server);
  }

  static Future<FakeDshHost> _serve(HttpServer server) {
    final host = FakeDshHost._(server, <WebSocket>{});
    server.listen((req) => host._handle(req));
    return Future.value(host);
  }

  int get port => _server.port;
  Uri get baseUri => Uri.parse('http://127.0.0.1:' + port.toString());

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'POST' && path == '/api/host.describe') {
      describeCalls += 1;
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      if (hangDescribe) {
        // 永不响应:挂起请求,让客户端超时。
        return;
      }
      final rpcId = wrongRpcIdEcho ? 'wrong-rpc-id' : envelope['rpcId'] as String;
      final result = businessError
          ? {'ok': false, 'error': {'code': 'bad-request', 'message': 'test', 'details': {'issues': []}}}
          : {
              'ok': true,
              'value': {
                'version': '0.0.1-fake',
                'cwd': '/tmp/fake',
                'provider': 'fake',
                'model': 'fake-model',
                'attachedSessions': 0,
                'canOpenPath': false,
              }
            };
      req.response.write(jsonEncode({
        'type': 'server-response',
        'rpcId': rpcId,
        'result': result,
      }));
      await req.response.close();
      return;
    }
    if (path == '/api/events.mux' || path == '/api/events.host') {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      (path.endsWith('mux') ? muxSockets : hostSockets).add(ws);
      ws.listen((_) {}, onDone: () => sockets.remove(ws));
      return;
    }
    req.response.statusCode = 404;
    req.response.write('not found');
    await req.response.close();
  }

  /// 从 mux 流发一帧(server-request 信封)。
  void sendMuxFrame(Map<String, dynamic> payload) {
    for (final ws in muxSockets) {
      ws.add(jsonEncode({
        'type': 'server-request',
        'rpcId': 'fake-frame-' + DateTime.now().microsecondsSinceEpoch.toString(),
        'method': payload['type'] as String,
        'payload': payload,
      }));
    }
  }

  /// 拔线:只关 mux socket(留 host 存活)。
  void unplugMux() {
    for (final ws in muxSockets.toList()) {
      ws.close(1001, 'unplugged');
    }
    muxSockets.clear();
  }

  Future<void> stop() async {
    for (final ws in sockets.toList()) {
      try { await ws.close(); } catch (_) {}
    }
    sockets.clear();
    muxSockets.clear();
    hostSockets.clear();
    await _server.close(force: true);
  }
}
