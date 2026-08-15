// 配对面(M6.1):手机生成亮码 + 秘密 → 轮询 offers → 人工比对主机码点选。
//
// 协议(与 services/dsh-gateway/src/pair.rs 对齐):
//   POST /pair/start   {code, secret, device} → {pairing_id, expires_at}
//   POST /pair/poll    {pairing_id, secret}   → {status, offers[]}
//   POST /pair/confirm {pairing_id, secret, claim_id, host_code} → {token, ...}
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:singleman/connection/remote_auth.dart';

/// 手机亮码字符集(与网关一致:去 I/L/O 与 0/1)。
const _kCodeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// 一次配对会话(手机侧材料)。secret 永不显示;code 大字展示给用户。
class PairingSession {
  PairingSession({
    required this.baseUri,
    required this.pairingId,
    required this.code,
    required this.secret,
    required this.expiresAt,
  });

  final Uri baseUri;
  final String pairingId;
  final String code;
  final String secret;
  final DateTime expiresAt;

  /// 展示形态 XXXXX-XXXXX。
  String get displayCode => '${code.substring(0, 5)}-${code.substring(5)}';
}

/// 一条来自某台 Mac 的应约 offer(主机码 = 人工比对凭证)。
class PairOfferView {
  const PairOfferView({
    required this.claimId,
    required this.hostCode,
    required this.hostLabel,
    required this.upstreamPort,
    required this.expiresAt,
  });

  factory PairOfferView.fromJson(Map<String, dynamic> json) => PairOfferView(
        claimId: json['claim_id'] as String,
        hostCode: json['host_code'] as String,
        hostLabel: json['host_label'] as String? ?? '',
        upstreamPort: json['upstream_port'] as int? ?? 0,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          ((json['expires_at'] as int? ?? 0) * 1000),
        ),
      );

  final String claimId;
  final String hostCode;
  final String hostLabel;
  final int upstreamPort;
  final DateTime expiresAt;

  String get displayHostCode =>
      hostCode.length == 6 ? '${hostCode.substring(0, 3)}-${hostCode.substring(3)}' : hostCode;
}

enum PairPollStatus { waiting, offers, confirmed, expired }

class PairPollResult {
  const PairPollResult({required this.status, required this.offers});
  final PairPollStatus status;
  final List<PairOfferView> offers;
}

/// 配对失败(网络/协议/被拒),message 面向用户。
class PairingFailure implements Exception {
  const PairingFailure(this.message);
  final String message;
  @override
  String toString() => 'PairingFailure($message)';
}

/// 配对客户端接口(UI 依赖;测试用假件替换)。
abstract class RemotePairing {
  /// 生成并发起配对;409(码被占)自动换码重试。返回待展示的会话。
  Future<PairingSession> pairStart(Uri baseUri, {String device = 'singleman'});

  /// 轮询当前状态与 offers 列表。
  Future<PairPollResult> pairPoll(PairingSession session);

  /// 确认选中的 offer(人工比对主机码后调用)→ 设备令牌。
  Future<RemoteLoginSuccess> pairConfirm(PairingSession session, PairOfferView offer);
}

/// 生成 10 位亮码(与网关字符集一致)。
String generatePairCode([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(10, (_) => _kCodeAlphabet[r.nextInt(_kCodeAlphabet.length)])
      .join();
}

/// 生成 43 位字母数字秘密(永不显示)。
String generatePairSecret([Random? random]) {
  final r = random ?? Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(43, (_) => chars[r.nextInt(chars.length)]).join();
}

/// RemoteAuthClient 的配对实现(与密码登录共用直连 HttpClient)。
mixin PairingClientMixin implements RemotePairing {
  HttpClient get pairingHttpClient;

  Future<Map<String, dynamic>> _post(Uri uri, Map<String, dynamic> body) async {
    final req = await pairingHttpClient.postUrl(uri);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      Map<String, dynamic>? err;
      try {
        final d = jsonDecode(text);
        if (d is Map<String, dynamic>) err = d;
      } on Object {/* 保留默认消息 */}
      throw PairingFailure(
        '${err?['error'] ?? 'HTTP ${res.statusCode}'}',
      );
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const PairingFailure('网关响应不是 JSON 对象');
    }
    return decoded;
  }

  @override
  Future<PairingSession> pairStart(Uri baseUri, {String device = 'singleman'}) async {
    Object? lastError;
    // 409(码被存活 pending 占用)自动换码,最多 3 次。
    for (var attempt = 0; attempt < 3; attempt++) {
      final code = generatePairCode();
      final secret = generatePairSecret();
      try {
        final resp = await _post(
          baseUri.replace(path: '/pair/start'),
          {'code': code, 'secret': secret, 'device': device},
        );
        return PairingSession(
          baseUri: baseUri,
          pairingId: resp['pairing_id'] as String,
          code: code,
          secret: secret,
          expiresAt: DateTime.fromMillisecondsSinceEpoch(
            ((resp['expires_at'] as int? ?? 0) * 1000),
          ),
        );
      } on SocketException catch (e) {
        throw PairingFailure('无法连接 ${baseUri.authority}: ${e.message}');
      } on HandshakeException catch (e) {
        throw PairingFailure('TLS 握手失败: ${e.message}');
      } on FormatException {
        throw const PairingFailure('网关响应不是 JSON');
      } on PairingFailure catch (e) {
        if (e.message.contains('already in use') && attempt < 2) {
          lastError = e;
          continue;
        }
        rethrow;
      }
    }
    throw lastError is PairingFailure
        ? lastError
        : const PairingFailure('配对码生成冲突,请重试');
  }

  @override
  Future<PairPollResult> pairPoll(PairingSession session) async {
    final resp = await _post(
      session.baseUri.replace(path: '/pair/poll'),
      {'pairing_id': session.pairingId, 'secret': session.secret},
    );
    final statusStr = resp['status'] as String? ?? 'waiting';
    final status = switch (statusStr) {
      'offers' => PairPollStatus.offers,
      'confirmed' => PairPollStatus.confirmed,
      'expired' => PairPollStatus.expired,
      _ => PairPollStatus.waiting,
    };
    final offersRaw = resp['offers'];
    final offers = offersRaw is List
        ? offersRaw
            .whereType<Map<String, dynamic>>()
            .map(PairOfferView.fromJson)
            .toList(growable: false)
        : const <PairOfferView>[];
    return PairPollResult(status: status, offers: offers);
  }

  @override
  Future<RemoteLoginSuccess> pairConfirm(
    PairingSession session,
    PairOfferView offer,
  ) async {
    final resp = await _post(
      session.baseUri.replace(path: '/pair/confirm'),
      {
        'pairing_id': session.pairingId,
        'secret': session.secret,
        'claim_id': offer.claimId,
        'host_code': offer.hostCode,
      },
    );
    final token = resp['token'];
    if (token is! String || token.isEmpty) {
      throw const PairingFailure('网关响应缺少令牌');
    }
    return RemoteLoginSuccess(baseUri: session.baseUri, token: token);
  }
}
