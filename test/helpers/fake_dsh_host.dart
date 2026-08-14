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
  int listCalls = 0;
  bool hangDescribe = false;
  bool wrongRpcIdEcho = false;
  bool businessError = false;
  final sessions = <String, List<Map<String, dynamic>>>{};
  final summaries = <Map<String, dynamic>>[];
  final promptRequests = <Map<String, dynamic>>[];
  final createRequests = <Map<String, dynamic>>[];
  final respondCalls = <Map<String, dynamic>>[];
  // rpcId -> 待应答类别(approval/question)
  final pendingRespondable = <String, String>{};
  final resolvedFrames = <Map<String, dynamic>>[];
  bool rejectNextRespond = false;
  String nextRespondRejectReason = 'not-pending';
  int nextSessionNo = 1;
  final workspaces = <Map<String, dynamic>>[
    <String, dynamic>{
      'workspaceId': 'ws-default',
      'path': '/tmp/fake-workspace',
      'title': 'fake workspace',
      'sessionIds': <String>[],
      'createdAt': '2026-08-14T00:00:00Z',
      'updatedAt': '2026-08-14T00:00:00Z',
    },
  ];

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
    if (req.method == 'POST' && path == '/api/session.list') {
      listCalls += 1;
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, {'items': summaries});
      return;
    }
    if (req.method == 'POST' && path == '/api/session.history') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      final sessionId = payload['sessionId'] as String;
      final events = sessions[sessionId] ?? <Map<String, dynamic>>[];
      final items = events
          .map((e) => <String, dynamic>{'event': e})
          .toList(growable: false);
      await _ok(req, envelope['rpcId'] as String, {
        'events': items,
        'hasMore': false,
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/workspace.list') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, {
        'items': workspaces,
        'archivedSessionIds': <String>[],
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/session.create') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      createRequests.add(payload);
      if (payload['workspaceId'] != null && payload['cwd'] != null) {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'type': 'server-response',
          'rpcId': envelope['rpcId'],
          'result': {
            'ok': false,
            'error': {
              'code': 'bad-request',
              'message': 'workspaceId or cwd, not both',
              'details': {'issues': []},
            },
          },
        }));
        await req.response.close();
        return;
      }
      final sessionId = 'session-fake-' + (nextSessionNo++).toString();
      sessions[sessionId] = <Map<String, dynamic>>[];
      summaries.add(<String, dynamic>{
        'sessionId': sessionId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'running': false,
        'blank': true,
      });
      for (final ws in workspaces) {
        (ws['sessionIds'] as List<String>).add(sessionId);
      }
      await _ok(req, envelope['rpcId'] as String, {'sessionId': sessionId});
      // 推 host 帧:新会话出现(客户端靠 refresh 拿到,不依赖此帧)。
      return;
    }
    if (req.method == 'POST' && path == '/api/session.prompt') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      promptRequests.add(envelope['payload'] as Map<String, dynamic>);
      await _ok(req, envelope['rpcId'] as String, {'accepted': true});
      return;
    }
    if (req.method == 'POST' && path == '/api/respond') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      respondCalls.add(envelope);
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      final rpcId = envelope['rpcId'] as String;
      Map<String, dynamic> receipt;
      if (rejectNextRespond) {
        receipt = {'accepted': false, 'reason': nextRespondRejectReason};
        rejectNextRespond = false;
      } else if (!pendingRespondable.containsKey(rpcId)) {
        receipt = {'accepted': false, 'reason': 'not-pending'};
      } else {
        final kind = pendingRespondable.remove(rpcId)!;
        // 服务端语义:应答成功后推 resolved 帧清场。
        final sessionId = ((envelope['result'] as Map)['value'] as Map)['sessionId'] as String;
        if (kind == 'approval') {
          final value = (envelope['result'] as Map)['value'] as Map;
          sendMuxFrame({
            'type': 'approval/resolved',
            'sessionId': sessionId,
            'approvalId': value['approvalId'],
            'outcome': value['outcome'],
          });
        } else {
          sendMuxFrame({
            'type': 'question/resolved',
            'sessionId': sessionId,
            'questionRpcId': rpcId,
            'outcome': 'answered',
          });
        }
        receipt = {'accepted': true};
      }
      req.response.write(jsonEncode(receipt));
      await req.response.close();
      return;
    }
    if (req.method == 'POST' && path == '/api/session.updateQueue') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      final action = payload['action'] as Map<String, dynamic>;
      final sid = payload['sessionId'] as String;
      final items = _queues[sid] ?? <Map<String, dynamic>>[];
      if (action['kind'] == 'remove') {
        final before = items.length;
        items.removeWhere((i) => i['id'] == payload['itemId']);
        _queues[sid] = items;
        sendMuxFrame({
          'type': 'session/queue',
          'sessionId': sid,
          'items': items,
        });
        if (items.length == before) {
          await _bizError(req, envelope['rpcId'] as String, 'queue-item-not-found',
              {'itemId': payload['itemId']});
          return;
        }
      }
      await _ok(req, envelope['rpcId'] as String, {'accepted': true});
      return;
    }
    if (req.method == 'POST' && path == '/api/session.cancel') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, {'accepted': true});
      return;
    }
    if (req.method == 'POST' && path == '/api/session.models') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      await _ok(req, envelope['rpcId'] as String, {
        'current': {'provider': 'fake', 'model': 'fake-model'},
        'routable': true,
        'groups': [
          {
            'id': 'fake',
            'name': 'Fake Provider',
            'models': [
              {
                'id': 'fake-model',
                'name': 'Fake Model',
                'reasoning': {
                  'efforts': [
                    {'id': 'low', 'name': 'Low'},
                    {'id': 'high', 'name': 'High'},
                  ],
                  'defaultEffort': 'high',
                },
              },
              {'id': 'fake-mini', 'name': 'Fake Mini'},
            ],
          },
        ],
        'failures': <Map<String, dynamic>>[],
      });
      return;
    }
    if (req.method == 'POST' && path == '/api/session.selectModel') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      final selected = <String, dynamic>{
        'provider': payload['provider'],
        'model': payload['model'],
      };
      if (payload['reasoningEffort'] is String) {
        selected['reasoningEffort'] = payload['reasoningEffort'];
      }
      await _ok(req, envelope['rpcId'] as String, {'selected': selected});
      return;
    }
    if (req.method == 'POST' && path == '/api/session.search') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      final query = payload['query'] as String;
      final items = <Map<String, dynamic>>[
        for (final s in summaries)
          if ((s['cwd'] as String? ?? '').contains(query))
            {'sessionId': s['sessionId'], 'snippet': 'matched ' + query},
      ];
      await _ok(req, envelope['rpcId'] as String,
          {'items': items, 'hasMore': false});
      return;
    }
    if (req.method == 'POST' && path == '/api/session.fork') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      final src = payload['sessionId'] as String;
      if (!(sessions.containsKey(src))) {
        await _bizError(req, envelope['rpcId'] as String, 'session-not-found',
            {'sessionId': src});
        return;
      }
      final forkId = 'session-fake-fork-' + (nextSessionNo++).toString();
      sessions[forkId] = List<Map<String, dynamic>>.of(sessions[src] ?? <Map<String, dynamic>>[]);
      summaries.add(<String, dynamic>{
        'sessionId': forkId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'running': false,
        'blank': false,
        'cwd': '/tmp/fake',
      });
      await _ok(req, envelope['rpcId'] as String, {'sessionId': forkId});
      return;
    }
    if (req.method == 'POST' && path == '/api/session.rename') {
      final body = await utf8.decoder.bind(req).join();
      final envelope = jsonDecode(body) as Map<String, dynamic>;
      final payload = envelope['payload'] as Map<String, dynamic>;
      final title = (payload['title'] as String).trim();
      if (title.isEmpty) {
        await _bizError(req, envelope['rpcId'] as String, 'title-invalid',
            {'sessionId': payload['sessionId']});
        return;
      }
      await _ok(req, envelope['rpcId'] as String, {'title': title, 'seq': 999});
      return;
    }
    if (req.method == 'GET' && path == '/api/session.export') {
      // 最小合法 ZIP(空档案的 22 字节 EOCD)。
      final zip = <int>[0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.binary;
      req.response.add(zip);
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

  Future<void> _ok(HttpRequest req, String rpcId, Map<String, dynamic> value) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'type': 'server-response',
      'rpcId': rpcId,
      'result': {'ok': true, 'value': value},
    }));
    await req.response.close();
  }

  final _queues = <String, List<Map<String, dynamic>>>{};

  /// 直接登记队列状态(测试 updateQueue 用)。
  void seedQueue(String sessionId, List<Map<String, dynamic>> items) {
    _queues[sessionId] = items;
    pushQueueFrame(sessionId: sessionId, items: items);
  }

  Future<void> _bizError(HttpRequest req, String rpcId, String code, Map<String, dynamic> details) async {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode({
      'type': 'server-response',
      'rpcId': rpcId,
      'result': {
        'ok': false,
        'error': {'code': code, 'message': code, 'details': details},
      },
    }));
    await req.response.close();
  }

  /// 推一条可应答审批帧,登记 rpcId 待应答。
  void pushApprovalFrame({
    required String rpcId,
    required String sessionId,
    required String approvalId,
    String toolName = 'bash',
    String? reason,
  }) {
    pendingRespondable[rpcId] = 'approval';
    sendMuxFrame(<String, dynamic>{
      'type': 'approval/requested',
      'sessionId': sessionId,
      'approvalId': approvalId,
      'toolName': toolName,
      if (reason != null) 'reason': reason,
    }, rpcId: rpcId);
  }

  /// 推一条可应答问答卷帧。
  void pushQuestionFrame({
    required String rpcId,
    required String sessionId,
    required List<Map<String, dynamic>> questions,
  }) {
    pendingRespondable[rpcId] = 'question';
    sendMuxFrame(<String, dynamic>{
      'type': 'question/requested',
      'sessionId': sessionId,
      'questions': questions,
    }, rpcId: rpcId);
  }

  /// 推队列快照帧(同时登记内部状态,updateQueue 在其上 splice)。
  void pushQueueFrame({required String sessionId, required List<Map<String, dynamic>> items}) {
    _queues[sessionId] = List<Map<String, dynamic>>.of(items);
    sendMuxFrame(<String, dynamic>{
      'type': 'session/queue',
      'sessionId': sessionId,
      'items': items,
    });
  }

  /// 往某会话追加事件并推 mux session/event 帧。
  void pushSessionEvent(String sessionId, Map<String, dynamic> event) {
    sessions.putIfAbsent(sessionId, () => <Map<String, dynamic>>[]).add(event);
    sendMuxFrame({
      'type': 'session/event',
      'sessionId': sessionId,
      'event': event,
    });
  }

  /// 从 mux 流发一帧(server-request 信封);可应答帧必须传与 pending 登记一致的 rpcId。
  void sendMuxFrame(Map<String, dynamic> payload, {String? rpcId}) {
    for (final ws in muxSockets) {
      ws.add(jsonEncode({
        'type': 'server-request',
        'rpcId': rpcId ?? 'fake-frame-' + DateTime.now().microsecondsSinceEpoch.toString(),
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
