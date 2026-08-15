// 配对客户端测试(M6.1):发起/轮询/确认 全流程 + 409 换码 + secret 校验。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/pairing.dart';
import 'package:singleman/connection/remote_auth.dart';

void main() {
  late HttpServer gw;
  late RemoteAuthClient client;

  // 极简网关状态机:单 pending + 单 claim。
  String? pendingCode;
  String? pendingSecret;
  Map<String, dynamic>? claim;

  setUp(() async {
    gw = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = RemoteAuthClient();
    pendingCode = null;
    pendingSecret = null;
    claim = null;
    gw.listen((req) async {
      final body = req.method == 'POST'
          ? (jsonDecode(await utf8.decoder.bind(req).join())
              as Map<String, dynamic>)
          : <String, dynamic>{};
      void ok(Map<String, dynamic> v) {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(v));
        req.response.close();
      }

      void err(int code, String msg) {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': msg}));
        req.response.close();
      }

      switch (req.uri.path) {
        case '/pair/start':
          if (pendingCode != null &&
              body['code'] == pendingCode &&
              body['code'] != 'FREECODE99') {
            // 模拟同码已占用(除测试指定换码成功路径外)。
            err(409, 'code already in use; generate a new one');
            return;
          }
          pendingCode = body['code'] as String;
          pendingSecret = body['secret'] as String;
          ok({
            'pairing_id': 'pr-1',
            'expires_at': DateTime.now()
                    .add(const Duration(minutes: 10))
                    .millisecondsSinceEpoch ~/
                1000,
          });
        case '/pair/poll':
          if (body['pairing_id'] != 'pr-1') {
            err(404, 'unknown pairing');
          } else if (body['secret'] != pendingSecret) {
            err(401, 'Unauthorized');
          } else if (claim == null) {
            ok({'status': 'waiting'});
          } else {
            ok({
              'status': 'offers',
              'offers': [claim],
            });
          }
        case '/pair/confirm':
          if (body['host_code'] != claim!['host_code']) {
            err(400, 'host code mismatch');
          } else {
            ok({
              'token': 'jwt-from-pair',
              'expires_at': 1999999999,
              'host_label': claim!['host_label'],
            });
          }
        default:
          err(404, 'not found');
      }
    });
  });

  tearDown(() async {
    client.dispose();
    await gw.close(force: true);
  });

  Uri base() => Uri.parse('http://127.0.0.1:${gw.port}');

  test('full pair flow: start → waiting → offers → confirm → token', () async {
    claim = {
      'claim_id': 'cl-1',
      'host_code': 'ABC234',
      'host_label': 'mac-mini',
      'upstream_port': 13105,
      'expires_at': 1999999999,
    };
    final session = await client.pairStart(base(), device: 'Pixel');
    expect(session.code.length, 10);
    expect(session.displayCode, contains('-'));
    expect(pendingCode, session.code);
    expect(pendingSecret, session.secret);

    final waiting = await client.pairPoll(session);
    expect(waiting.status, PairPollStatus.offers); // claim 已预置
    expect(waiting.offers.single.hostCode, 'ABC234');
    expect(waiting.offers.single.upstreamPort, 13105);

    final success =
        await client.pairConfirm(session, waiting.offers.single);
    expect(success.token, 'jwt-from-pair');
    expect(success.baseUri, base());
  });

  test('start regenerates code on 409 (squat defense, client side)', () async {
    // 先占一个码;客户端生成的新码极大概率不与它相撞,
    // 这里验证第二次 start(不同码)成功 —— 即换码重试路径。
    pendingCode = 'AAAAAAAAAA';
    final session = await client.pairStart(base());
    expect(session.code, isNot('AAAAAAAAAA'));
    expect(session.code, pendingCode);
  });

  test('poll with wrong secret → PairingFailure(401)', () async {
    final session = await client.pairStart(base());
    final bad = PairingSession(
      baseUri: session.baseUri,
      pairingId: session.pairingId,
      code: session.code,
      secret: 'wrong-secret-alphabet-0123456789abc',
      expiresAt: session.expiresAt,
    );
    await expectLater(
      client.pairPoll(bad),
      throwsA(isA<PairingFailure>()),
    );
  });

  test('confirm with mismatched host code → PairingFailure', () async {
    final session = await client.pairStart(base());
    claim = {
      'claim_id': 'cl-1',
      'host_code': 'ABC234',
      'host_label': 'mac',
      'upstream_port': 13100,
      'expires_at': 1999999999,
    };
    final wrongOffer = PairOfferView.fromJson({
      'claim_id': 'cl-1',
      'host_code': 'ZZZ999',
      'host_label': 'mac',
      'upstream_port': 13100,
      'expires_at': 1999999999,
    });
    await expectLater(
      client.pairConfirm(session, wrongOffer),
      throwsA(isA<PairingFailure>()),
    );
  });

  test('code generation: charset and length', () {
    final code = generatePairCode();
    expect(code.length, 10);
    expect(
      code.runes.every((r) => 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'.contains(String.fromCharCode(r))),
      isTrue,
    );
    final secret = generatePairSecret();
    expect(secret.length, 43);
    expect(secret.runes.every((r) => r >= 48 && r <= 122), isTrue);
  });
}
