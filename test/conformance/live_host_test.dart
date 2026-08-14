// M0 conformance test: live host at http://127.0.0.1:3080.
// Verifies the generated contract models parse a real host.describe round trip
// and a session.list response, plus envelope unwrap discipline.
// Skips automatically when no live host is reachable (CI runs fixture-only).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

const base = 'http://127.0.0.1:3080';

Future<Map<String, dynamic>> post(String method, Map<String, dynamic> payload) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(base + '/api/' + method));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'type': 'client-request',
      'rpcId': 'conformance-' + DateTime.now().microsecondsSinceEpoch.toString(),
      'method': method,
      'payload': payload,
    }));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    expect(res.statusCode, 200, reason: method + ' -> ' + res.statusCode.toString() + ': ' + body);
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

void main() {
  // NOTE: no TestWidgetsFlutterBinding here — it stubs HttpClient with a fake
  // that returns 400 for every request. These are pure-IO contract tests.
  var hostUp = true;
  setUpAll(() async {
    try {
      await post(RpcMethods.hostDescribe, {});
    } catch (_) {
      hostUp = false;
    }
  });

  test('host.describe envelope + value parse against live dsh', () async {
    final raw = await post(RpcMethods.hostDescribe, {});
    final envelope = RpcMessage.fromJson(raw);
    expect(envelope, isA<RpcMessageServerResponse>());
    final resp = envelope as RpcMessageServerResponse;
    expect(resp.rpcId, startsWith('conformance-'));
    final r = resp.result as Map<String, dynamic>;
    expect(r['ok'], true, reason: 'describe must succeed: ' + jsonEncode(r));
    final value = HostDescribeValue.fromJson(r['value'] as Map<String, dynamic>);
    expect(value.version, isNotEmpty);
    expect(value.cwd, isNotEmpty);
    expect(value.canOpenPath, isA<bool>());
    expect(value.attachedSessions, greaterThanOrEqualTo(0));
  }, skip: hostUp ? false : 'no live dsh host on 3080');

  test('session.list envelope + typed items against live dsh', () async {
    final raw = await post(RpcMethods.sessionList, {});
    final envelope = RpcMessage.fromJson(raw) as RpcMessageServerResponse;
    final r = envelope.result as Map<String, dynamic>;
    expect(r['ok'], true);
    final value = SessionListValue.fromJson(r['value'] as Map<String, dynamic>);
    expect(value.items, isA<List<SessionSummary>>());
    for (final item in value.items) {
      expect(item.sessionId, isNotEmpty);
      expect(item.running, isA<bool>());
    }
  }, skip: hostUp ? false : 'no live dsh host on 3080');

  test('unknown method fails loud at the HTTP carrier (404, no envelope)', () async {
    // Unknown methods never reach envelope parsing: the gateway 404s the route
    // itself. The client must surface this as a carrier error, never parse it.
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse(base + '/api/no.such.method'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'type': 'client-request',
        'rpcId': 'conformance-unknown',
        'method': 'no.such.method',
        'payload': {},
      }));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      expect(res.statusCode, 404);
      expect(() => RpcMessage.fromJson(jsonDecode(body) as Map<String, dynamic>), throwsA(anything));
    } finally {
      client.close();
    }
  }, skip: hostUp ? false : 'no live dsh host on 3080');
}
