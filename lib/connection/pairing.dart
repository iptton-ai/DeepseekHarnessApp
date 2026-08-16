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

/// 扫码邀请(M6.2):Mac 终端二维码 → 系统相机落地页「复制」→ 此处粘贴。
/// 内容是网关 /pair 落地页 URL(fragment 携带码),或裸 10 位码(手抄兜底)。
class PairInvite {
  const PairInvite({
    required this.baseUri,
    required this.code,
    this.hostCode,
    this.label = '',
  });

  /// 网关地址(落地页 URL 去掉 /pair 路径与 fragment)。
  final Uri baseUri;

  /// 10 位配对码(已归一化大写)。
  final String code;

  /// 锚定主机码(6 位;二维码携带,offers 里自动高亮匹配项)。
  final String? hostCode;

  /// 来源机器名(仅展示)。
  final String label;

  String get displayCode => '${code.substring(0, 5)}-${code.substring(5)}';
}

const _kInviteAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

String _normalizeCode(String raw) =>
    raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

bool _isValidInviteCode(String code) => code.length == 10 &&
    code.runes
        .every((r) => _kInviteAlphabet.contains(String.fromCharCode(r)));

/// 解析剪贴板/手输的邀请内容:
/// - `https://host/pair#c=XXXXX&h=YYYYYY&l=label`(落地页「复制」产物)
/// - `XXXXX-XXXXX` / `XXXXXXXXXX`(裸码;此时 baseUri 用 [fallbackBase])
///
/// 无法解析返回 null(UI 提示格式不对)。
PairInvite? parsePairInvite(String input, {Uri? fallbackBase}) {
  final text = input.trim();
  if (text.isEmpty) return null;
  if (text.contains('://')) {
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    final frag = uri.fragment;
    final query = Uri.splitQueryString(frag);
    var code = _normalizeCode(query['c'] ?? query['code'] ?? '');
    final host = _normalizeCode(query['h'] ?? query['host'] ?? '');
    // 兼容:fragment 本身就是裸码(无键值对)。
    if (code.isEmpty && frag.isNotEmpty && !frag.contains('=')) {
      code = _normalizeCode(frag);
    }
    if (!_isValidInviteCode(code)) return null;
    // 网关地址 = scheme://host[:port]。Uri.replace 对 fragment 的 null 语义是
    // 「保持不变」、空串又留 ?# 尾巴 —— 组件重建才是干净删法。
    final base = Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    );
    final rawLabel = query['l'] ?? '';
    // 清洗但保留中文机器名(插件侧已限长;这里只剥会破坏展示的字符)。
    final safeLabel = rawLabel
        .replaceAll(RegExp(r'[^\p{L}\p{N} _.\-]', unicode: true), '')
        .trim();
    return PairInvite(
      baseUri: base,
      code: code,
      hostCode: host.length >= 6 ? host.substring(0, 6) : null,
      label: safeLabel.substring(0, safeLabel.length.clamp(0, 32)),
    );
  }
  // 裸码:必须带兜底地址。
  final code = _normalizeCode(text);
  if (!_isValidInviteCode(code)) return null;
  final base = fallbackBase;
  if (base == null) return null;
  return PairInvite(baseUri: base, code: code);
}

/// 配对客户端接口(UI 依赖;测试用假件替换)。
abstract class RemotePairing {
  /// 生成并发起配对;409(码被占)自动换码重试。
  /// [code] 提供时使用扫码邀请的固定码(不换码 —— 邀请码锚定了 Mac 侧)。
  Future<PairingSession> pairStart(Uri baseUri,
      {String device = 'dshapp', String? code});

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
  Future<PairingSession> pairStart(Uri baseUri,
      {String device = 'dshapp', String? code}) async {
    Object? lastError;
    // 外部邀请码归一化(去分隔符大写,与网关规则一致);自生成码本就纯净。
    final normalized = code == null
        ? null
        : code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    // 409(码被存活 pending 占用)自动换码,最多 3 次。
    // 邀请码不换码 —— 换了就与 Mac 侧锚定的码对不上。
    for (var attempt = 0; attempt < 3; attempt++) {
      final effective = normalized ?? generatePairCode();
      final secret = generatePairSecret();
      try {
        final resp = await _post(
          baseUri.replace(path: '/pair/start'),
          {'code': effective, 'secret': secret, 'device': device},
        );
        return PairingSession(
          baseUri: baseUri,
          pairingId: resp['pairing_id'] as String,
          code: effective,
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
    // 来源机器名回显(网关从 claim 的 host_label 快照;设置页「已连接 xxx」的
    // 种子 —— 运行时以 /pair/api/host 的当前值为准,这里只做首显)。
    final hostLabel = resp['host_label'];
    return RemoteLoginSuccess(
      baseUri: session.baseUri,
      token: token,
      hostLabel: hostLabel is String ? hostLabel : '',
    );
  }
}
