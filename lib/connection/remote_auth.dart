// 远程网关鉴权客户端 + 令牌供给(M6 远程形态)。
//
// 登录:POST {base}/auth/login {password, device} → {token, expires_at}。
// 之后所有 /api 与 WS 请求带 Authorization: Bearer(见 ApiClient/Downlink)。
import 'dart:convert';
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/credentials.dart';

/// 令牌供给:ApiClient/Downlink 每次请求时读取,登录成功后原地刷新,
/// 无需重建任何 store。
class MutableTokenProvider {
  String? _token;
  MutableTokenProvider([this._token]);
  String? get token => _token;
  set token(String? value) {
    _token = (value == null || value.isEmpty) ? null : value;
  }

  bool get hasToken => _token != null;

  /// WS/HTTP 共用的鉴权头;无令牌返回空 map(不添头)。
  Map<String, String> authHeaders() =>
      _token == null ? const {} : {'Authorization': 'Bearer $_token'};
}

/// 登录结果。
class RemoteLoginSuccess {
  const RemoteLoginSuccess({required this.baseUri, required this.token});
  final Uri baseUri;
  final String token;
}

/// 登录失败(密码错/限速/网关不可达),message 面向用户。
class RemoteLoginFailure implements Exception {
  const RemoteLoginFailure(this.message);
  final String message;
  @override
  String toString() => 'RemoteLoginFailure($message)';
}

/// 登录器接口(UI 依赖它;实现可替换为测试假件)。
abstract class RemoteAuthenticator {
  Future<RemoteLoginSuccess> login(Uri baseUri, String password,
      {String device = 'singleman'});
}

class RemoteAuthClient implements RemoteAuthenticator {
  RemoteAuthClient({HttpClient? httpClient})
      : _httpClient = httpClient ?? createDirectHttpClient();

  final HttpClient _httpClient;

  @override
  Future<RemoteLoginSuccess> login(
    Uri baseUri,
    String password, {
    String device = 'singleman',
  }) async {
    final uri = baseUri.replace(path: '/auth/login');
    final HttpClientRequest req;
    try {
      req = await _httpClient.postUrl(uri);
    } on SocketException catch (e) {
      throw RemoteLoginFailure('无法连接 ${baseUri.authority}: ${e.message}');
    } on HandshakeException catch (e) {
      throw RemoteLoginFailure('TLS 握手失败: ${e.message}');
    }
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(<String, dynamic>{
      'password': password,
      'device': device,
    }));
    final HttpClientResponse res;
    try {
      res = await req.close().timeout(const Duration(seconds: 15));
    } on SocketException catch (e) {
      throw RemoteLoginFailure('连接中断: ${e.message}');
    }
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 401) {
      throw const RemoteLoginFailure('密码不正确');
    }
    if (res.statusCode == 409) {
      throw const RemoteLoginFailure('尝试过于频繁,请稍后再试');
    }
    if (res.statusCode != 200) {
      throw RemoteLoginFailure('网关错误 (HTTP ${res.statusCode})');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const RemoteLoginFailure('网关响应不是 JSON');
    }
    if (decoded is! Map<String, dynamic> || decoded['token'] is! String) {
      throw const RemoteLoginFailure('网关响应缺少令牌');
    }
    return RemoteLoginSuccess(baseUri: baseUri, token: decoded['token'] as String);
  }

  void dispose() => _httpClient.close();
}

/// 启动期凭证决策:决定用哪个 base、是否需要登录页。
class ConnectionPlan {
  const ConnectionPlan({
    required this.baseUri,
    required this.tokenProvider,
    required this.needsLogin,
  });
  final Uri baseUri;
  final MutableTokenProvider tokenProvider;
  final bool needsLogin;
}

/// loopback 形态永远免鉴权(也避免误带令牌头)。
bool isLoopbackBase(Uri base) {
  final h = base.host.toLowerCase();
  return h == '127.0.0.1' || h == 'localhost' || h == '[::1]' || h == '::1';
}

Future<ConnectionPlan> planFromCredentials(CredentialStore store,
    {Uri? defaultBase}) async {
  final Uri fallback = defaultBase ?? Uri.parse('http://127.0.0.1:3080');
  StoredCredentials? stored;
  try {
    stored = await store.load();
  } on Object {
    stored = null;
  }
  if (stored == null || isLoopbackBase(stored.baseUri)) {
    return ConnectionPlan(
      baseUri: stored?.baseUri ?? fallback,
      tokenProvider: MutableTokenProvider(null),
      needsLogin: false,
    );
  }
  return ConnectionPlan(
    baseUri: stored.baseUri,
    tokenProvider: MutableTokenProvider(stored.token),
    needsLogin: stored.token == null,
  );
}
