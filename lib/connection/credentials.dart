// 远程凭证模型与内存实现(M6 远程形态)。
//
// 纪律:本文件不得 import 任何 Flutter 依赖 —— bin/ 冒烟脚本会经
// remote_auth.dart 传递引入本文件(bin/*.dart 不沾 flutter,PROGRESS 坑表)。
// 文件实现(带 path_provider)在 credentials_path.dart,仅 main.dart 引。
import 'dart:convert';
import 'dart:io';

/// 持久化的连接配置。
class StoredCredentials {
  const StoredCredentials({required this.baseUri, this.token});
  final Uri baseUri;

  /// 远程网关的设备令牌;loopback 直连形态恒为 null。
  final String? token;
}

/// 凭证存取抽象(测试用内存实现替换)。
abstract class CredentialStore {
  Future<StoredCredentials?> load();
  Future<void> save(StoredCredentials credentials);
  Future<void> clear();
}

/// 内存实现(测试)。
class MemoryCredentialStore implements CredentialStore {
  StoredCredentials? _current;

  @override
  Future<StoredCredentials?> load() async => _current;

  @override
  Future<void> save(StoredCredentials credentials) async {
    _current = credentials;
  }

  @override
  Future<void> clear() async {
    _current = null;
  }
}

/// 共用的最小 JSON 编码(文件实现在 credentials_path.dart 复用)。
String encodeCredentialsJson(StoredCredentials credentials) =>
    jsonEncode(<String, dynamic>{
      'baseUri': credentials.baseUri.toString(),
      if (credentials.token != null) 'token': credentials.token,
    });

