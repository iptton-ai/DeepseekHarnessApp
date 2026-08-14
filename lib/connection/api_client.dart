// ApiClient — M1 连接控制器的上行一半。
//
// 职责(DSH-PROTOCOL §1/§2/§5):
// - rpcId mint(UUIDv4,只由发起方造,响应必须回显)
// - 信封 wrap(POST /api/<method>,Content-Type: application/json,否则 415)
// - 两级解析:先 RpcMessage 信封,再业务 value(调用方给 parse)
// - 30s 默认 unary 超时(host.pickDirectory 等用户节奏方法由调用方放宽)
// - 错误折叠:载波层(CarrierError/ApiTimeout)+ 业务层(RpcBusinessError,
//   内含生成的 RpcError sealed —— 41 个错误码全覆盖)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:singleman/wire/generated/wire_generated.dart';

/// 载波/传输层失败(连接拒绝、HTTP 非 200、信封畸形、rpcId 不回显)。
class CarrierError implements Exception {
  const CarrierError(this.reason, {this.httpStatus});
  final String reason;
  final int? httpStatus;
  @override
  String toString() =>
      'CarrierError($reason${httpStatus == null ? '' : ' (http $httpStatus)'})';
}

/// 业务失败:RpcResult 的 ok:false 分支,error 为生成的 sealed RpcError。
class RpcBusinessError implements Exception {
  const RpcBusinessError(this.error);
  final RpcError error;
  @override
  String toString() => 'RpcBusinessError($error)';
}

/// unary 超时(默认 30s;用户节奏方法调用方放宽)。
class ApiTimeout implements Exception {
  const ApiTimeout(this.method, this.limit);
  final String method;
  final Duration limit;
  @override
  String toString() => 'ApiTimeout($method after ${limit.inMilliseconds}ms)';
}

class ApiClient {
  ApiClient({
    required Uri baseUri,
    Duration defaultTimeout = const Duration(seconds: 30),
    HttpClient? httpClient,
  })  : _baseUri = baseUri,
        _defaultTimeout = defaultTimeout,
        _httpClient = httpClient ?? HttpClient();

  final Uri _baseUri;
  final Duration _defaultTimeout;
  final HttpClient _httpClient;
  final Random _random = Random.secure();

  /// 单方法调用:信封 wrap → POST → 信封 unwrap → 业务 parse/折叠。
  ///
  /// [parse] 收到的是 result.value 的 JSON(空 value 兜底为空 map);
  /// 业务错误抛 [RpcBusinessError],载波问题抛 [CarrierError],
  /// 超时抛 [ApiTimeout]。
  Future<T> call<T>(
    String method,
    Map<String, dynamic> payload, {
    required T Function(Map<String, dynamic> json) parse,
    Duration? timeout,
  }) async {
    final limit = timeout ?? _defaultTimeout;
    final rpcId = _mintRpcId();
    try {
      return await _roundTrip(method, payload, rpcId, parse).timeout(
        limit,
        onTimeout: () => throw ApiTimeout(method, limit),
      );
    } on ApiTimeout {
      rethrow;
    } on CarrierError {
      rethrow;
    } on RpcBusinessError {
      rethrow;
    } on SocketException catch (e) {
      throw CarrierError('socket: ${e.message}');
    } on FormatException catch (e) {
      throw CarrierError('malformed response: ${e.message}');
    }
  }

  Future<T> _roundTrip<T>(
    String method,
    Map<String, dynamic> payload,
    String rpcId,
    T Function(Map<String, dynamic> json) parse,
  ) async {
    final uri = _baseUri.replace(path: '/api/' + method);
    final HttpClientRequest req;
    try {
      req = await _httpClient.postUrl(uri);
    } on SocketException catch (e) {
      throw CarrierError('connect refused: ${e.message}');
    }
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(<String, dynamic>{
      'type': 'client-request',
      'rpcId': rpcId,
      'method': method,
      'payload': payload,
    }));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw CarrierError('http ' + res.statusCode.toString(),
          httpStatus: res.statusCode);
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw CarrierError('non-json body: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw CarrierError('envelope not an object');
    }
    final RpcMessage envelope;
    try {
      envelope = RpcMessage.fromJson(decoded);
    } on FormatException catch (e) {
      throw CarrierError('envelope parse: ${e.message}');
    }
    if (envelope is! RpcMessageServerResponse) {
      throw CarrierError('expected server-response, got ' + envelope.runtimeType.toString());
    }
    if (envelope.rpcId != rpcId) {
      throw CarrierError('rpcId mismatch: sent ' + rpcId + ', got ' + envelope.rpcId);
    }
    final result = envelope.result;
    if (result is! Map<String, dynamic>) {
      throw CarrierError('result not an object');
    }
    if (result['ok'] == true) {
      final value = result['value'];
      return parse(value is Map<String, dynamic> ? value : <String, dynamic>{});
    }
    final errorJson = result['error'];
    if (errorJson is! Map<String, dynamic>) {
      throw CarrierError('ok:false without error body');
    }
    throw RpcBusinessError(RpcError.fromJson(errorJson));
  }

  /// UUIDv4;rpcId 只由发起方 mint,响应只校验回显。
  String _mintRpcId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final h = hex;
    return h.substring(0, 8) +
        '-' +
        h.substring(8, 12) +
        '-' +
        h.substring(12, 16) +
        '-' +
        h.substring(16, 20) +
        '-' +
        h.substring(20);
  }

  void dispose() => _httpClient.close();
}
