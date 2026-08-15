// 性能回归:loadHistory 默认单页尾页 / loadOlder 逐页向前 / appendAll 单次广播。
// 背景:启动卡死根因 = 无界翻页 + 逐事件全量重算(见 PROGRESS 性能回写)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

Map<String, dynamic> _ok(String rpcId, Map<String, dynamic> value) => {
      'type': 'server-response',
      'rpcId': rpcId,
      'result': {'ok': true, 'value': value},
    };

SessionEvent _userMsg(int seq) => SessionEvent.fromJson(<String, dynamic>{
      'type': 'user/message',
      'seq': seq,
      'time': 1786760000000 + seq,
      'data': <String, dynamic>{
        'content': <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'm' + seq.toString()},
        ]
      },
    });

void main() {
  late HttpServer server;
  late List<Map<String, dynamic>> historyRequests;

  setUp(() async {
    historyRequests = <Map<String, dynamic>>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body =
          jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      final res = req.response;
      res.headers.contentType = ContentType.json;
      final rpcId = body['rpcId'] as String;
      if (req.uri.path == '/api/host.describe') {
        res.write(jsonEncode(_ok(rpcId, <String, dynamic>{
          'version': '0.1.0-rc.6',
          'cwd': '/tmp',
          'provider': 'p',
          'model': 'm',
          'attachedSessions': 0,
          'canOpenPath': false,
        })));
      } else if (req.uri.path == '/api/session.list') {
        res.write(jsonEncode(_ok(rpcId, <String, dynamic>{
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'sessionId': 's1',
              'updatedAt': 1786760000000,
              'running': false,
              'blank': false,
            }
          ]
        })));
      } else if (req.uri.path == '/api/session.history') {
        historyRequests.add(Map<String, dynamic>.from(body['payload'] as Map));
        final before = (body['payload'] as Map)['beforeSeq'] as int?;
        final all = List<int>.generate(150, (i) => i + 1);
        final visible = before == null ? all : all.where((s) => s < before).toList();
        final page =
            visible.length > 50 ? visible.sublist(visible.length - 50) : visible;
        res.write(jsonEncode(_ok(rpcId, <String, dynamic>{
          'events': <Map<String, dynamic>>[
            for (final s in page)
              <String, dynamic>{
                'event': <String, dynamic>{
                  'type': 'user/message',
                  'seq': s,
                  'time': 1786760000000 + s,
                  'data': <String, dynamic>{
                    'content': <Map<String, dynamic>>[
                      <String, dynamic>{'type': 'text', 'text': 'm' + s.toString()},
                    ]
                  }
                }
              }
          ],
          'hasMore': visible.length > 50,
          if (before == null)
            'projections': <String, dynamic>{
              'asOfSeq': 150,
              'values': <String, dynamic>{'title': <String, dynamic>{'title': 'T'}},
            },
        })));
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  });

  tearDown(() async {
    await server.close();
  });

  test('loadHistory 默认只拉一页尾页(hasMore 记录在 log.hasOlder)', () async {
    final base = Uri.parse('http://127.0.0.1:' + server.port.toString());
    final store = SessionStore(
      api: ApiClient(baseUri: base),
      connection: ConnectionController(baseUri: base),
    );
    await store.loadHistory('s1');
    final log = store.logFor('s1');
    expect(historyRequests, hasLength(1));
    expect(historyRequests.single.containsKey('beforeSeq'), isFalse);
    expect(log.events, hasLength(50));
    expect(log.events.last.seq, 150);
    expect(log.hasOlder, isTrue);
  });

  test('loadOlder 逐页向前,补到头后 no-op', () async {
    final base = Uri.parse('http://127.0.0.1:' + server.port.toString());
    final store = SessionStore(
      api: ApiClient(baseUri: base),
      connection: ConnectionController(baseUri: base),
    );
    final log = store.logFor('s1');
    await store.loadHistory('s1');
    await store.loadOlder('s1');
    expect(log.events, hasLength(100));
    expect(historyRequests.last['beforeSeq'], 101);
    await store.loadOlder('s1');
    expect(log.events, hasLength(150));
    expect(log.hasOlder, isFalse);
    final calls = historyRequests.length;
    await store.loadOlder('s1'); // no-op
    expect(historyRequests.length, calls);
  });

  test('appendAll 单次广播(而非逐事件 50 次)且去重语义保持', () async {
    final log = SessionLog('s1');
    var emissions = 0;
    final sub = log.eventStream.listen((_) => emissions += 1);
    final events = List<int>.generate(50, (i) => 51 + i).map(_userMsg).toList();
    log.appendAll(events);
    await Future<void>.delayed(Duration.zero);
    expect(emissions, 1);
    expect(log.events, hasLength(50));
    log.appendAll(events); // 全部重复
    await Future<void>.delayed(Duration.zero);
    expect(emissions, 1);
    await sub.cancel();
  });
}
