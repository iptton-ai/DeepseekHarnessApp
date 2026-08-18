// 主机簿协调器(方案 A 多主机,2026-08-16):配对 upsert / 切换 / 删除的
// 唯一变更通路 —— 维护簿一致性(活动指针有效、同网关幂等去重)+ 持久化
// + ValueNotifier 通知 UI(设置页主机列表实时重建)。
//
// 单活动语义:簿只记数据,「切到哪台就整代重装到哪台」由 main.dart 的
// reboot 闭包实现(与 onLoginDone 换 base 重装同一条路径)。
import 'package:flutter/foundation.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/remote_auth.dart';

/// 吊销结果(测试与日志用;失败不阻断删除)。
enum TokenRevokeOutcome { skipped, revoked, failed }

class HostCoordinator {
  HostCoordinator(this._store, {HttpClient Function()? revokeHttpClientFactory})
    : _revokeHttpClientFactory = revokeHttpClientFactory ?? createDirectHttpClient;

  final CredentialStore _store;
  final HttpClient Function() _revokeHttpClientFactory;
  HttpClient? _revokeHttpClient;

  /// 上次吊销结果(测试观测口;生产仅日志)。best-effort,删除永不因它失败。
  TokenRevokeOutcome lastRevokeOutcome = TokenRevokeOutcome.failed;
  final _book = ValueNotifier<HostBook>(const HostBook());

  /// 主机簿(监听以重建 UI;boot 后 hydrate 一次即真)。
  ValueListenable<HostBook> get book => _book;

  Future<void> hydrate() async {
    try {
      _book.value = await _store.load();
    } on Object {
      // 读失败按空簿处理(重新配对),不崩。
    }
  }

  /// 配对/登录成功 → upsert 条目并激活。条目 id = 网关地址 + 宿主标识复合
  /// ([hostIdFor]):同一宿主重复配对原地刷新令牌/机器名;同一网关后面的
  /// 不同宿主(host_ref 不同)= 各自独立条目(多宿主网关,2026-08-18)。
  ///
  /// 复合键迁移:同网关存在旧形态条目(id = 裸网关地址,升级前的单宿主键)
  /// 且本次配对带 host_ref 时,旧条目被取代移除 —— 网关一旦开始返回
  /// host_ref,其全部宿主都会返回;旧条目只可能是本机旧形态(需重配)或
  /// 陈旧令牌,保留只会造成重复条目。
  Future<StoredCredentials> adopt(RemoteLoginSuccess success) async {
    final id = hostIdFor(success.baseUri, success.hostRef);
    var book = _book.value;
    final legacyId = hostIdForBase(success.baseUri);
    if (id != legacyId) {
      for (final h in book.hosts) {
        if (h.id == legacyId) {
          book = book.remove(legacyId);
          break;
        }
      }
    }
    final next = book.upsert(StoredCredentials(
      id: id,
      baseUri: success.baseUri,
      token: success.token,
      hostLabel: success.hostLabel,
      hostRef: success.hostRef,
    ));
    await _persist(next);
    return next.active!;
  }

  /// 切换活动主机。id 不命中任何条目时簿不变(防误切)。
  Future<StoredCredentials?> switchTo(String id) async {
    final next = _book.value.withActive(id);
    if (identical(next, _book.value)) return _book.value.active;
    await _persist(next);
    return next.active;
  }

  /// 删除主机条目;若删的是活动条目,指针自动滑到剩余首条(簿空则 null)。
  ///
  /// 落盘成功后 best-effort 吊销网关令牌(否则网关侧行永久留存,Web 端
  /// 「已配对设备」一直显示该设备;CF Worker 的在线判定还是 5 分钟内
  /// 有活动的启发式,不吊销会顶满 5 分钟「在线」)。吊销失败不阻断删除 ——
  /// 令牌仍有 30 天自然过期 + 管理面手工吊销两条退路。
  Future<StoredCredentials?> remove(String id) async {
    StoredCredentials? entry;
    for (final h in _book.value.hosts) {
      if (h.id == id) entry = h;
    }
    await _persist(_book.value.remove(id));
    if (entry != null) {
      unawaited(_revokeToken(entry.token, entry.baseUri));
    }
    return _book.value.active;
  }

  /// 通知网关吊销令牌(POST /auth/revoke {jti},Bearer 自证)。
  /// jti 从本地 JWT 载荷解析(不验签 —— 网关验);载荷里没有 jti(非网关
  /// 签发的形态)则跳过网络调用。
  Future<void> _revokeToken(String? token, Uri gatewayUri) async {
    if (token == null || token.isEmpty) {
      lastRevokeOutcome = TokenRevokeOutcome.skipped;
      return;
    }
    // loopback 直连形态的条目不持有网关令牌,上面的空令牌判断已覆盖;
    // 载荷里没有 jti 的令牌(非网关签发)同样无从吊销,跳过。
    final jti = jtiFromJwt(token);
    if (jti == null) {
      lastRevokeOutcome = TokenRevokeOutcome.skipped;
      debugPrint('host remove: token carries no jti, skip revoke');
      return;
    }
    try {
      final client = _revokeHttpClient ??= _revokeHttpClientFactory();
      final req = await client
          .postUrl(gatewayUri.replace(path: '/auth/revoke'))
          .timeout(const Duration(seconds: 5));
      req.headers.contentType = ContentType.json;
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.write(jsonEncode(<String, dynamic>{'jti': jti}));
      final res = await req.close().timeout(const Duration(seconds: 5));
      // 网关撤销响应体只作日志;非 200 视为失败(不重试)。
      await res.drain<void>().catchError((Object _) {});
      lastRevokeOutcome =
          res.statusCode == 200 ? TokenRevokeOutcome.revoked : TokenRevokeOutcome.failed;
      if (res.statusCode != 200) {
        debugPrint('host remove: revoke token HTTP ${res.statusCode}');
      }
    } on Object catch (e) {
      lastRevokeOutcome = TokenRevokeOutcome.failed;
      debugPrint('host remove: revoke token error: $e');
    }
  }

  Future<void> _persist(HostBook next) async {
    _book.value = next;
    await _store.save(next);
  }
}

/// 从 JWT 载荷段解析 jti(纯解码,不验签;非三段式/解析失败返回 null)。
String? jtiFromJwt(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  var payload = parts[1];
  // base64url 去填充编码,解码前补齐。
  final pad = payload.length % 4;
  if (pad == 2) {
    payload += '==';
  } else if (pad == 3) {
    payload += '=';
  }
  try {
    final decoded = utf8.decode(base64Url.decode(payload));
    final map = jsonDecode(decoded);
    if (map is Map<String, dynamic>) {
      final jti = map['jti'];
      return jti is String && jti.isNotEmpty ? jti : null;
    }
    return null;
  } on Object {
    return null;
  }
}