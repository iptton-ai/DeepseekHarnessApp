// 文件凭证实现(M6):~/.singleman/credentials.json。
//
// 本文件带 path_provider(Flutter 插件),只允许 main.dart 引用 ——
// bin/ 冒烟脚本不得引入(纪律见 credentials.dart 头注)。
// 密码永不落盘,只存网关设备令牌(30 天,可吊销)。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:singleman/connection/credentials.dart';

class FileCredentialStore implements CredentialStore {
  FileCredentialStore({String? path}) : _overridePath = path;
  final String? _overridePath;
  File? _resolved;

  Future<File> _file() async {
    if (_resolved != null) return _resolved!;
    if (_overridePath != null) {
      _resolved = File(_overridePath!);
    } else {
      final dir = await _resolveDir();
      _resolved = File('${dir.path}/credentials.json');
    }
    return _resolved!;
  }

  /// HOME 优先(桌面/iOS 沙箱);缺失时(部分 Android 环境)走
  /// path_provider 的应用支持目录;插件不可用时兜底当前目录。
  Future<Directory> _resolveDir() async {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final d = Directory('$home/.singleman');
      await d.create(recursive: true);
      return d;
    }
    try {
      final support = await getApplicationSupportDirectory();
      await support.create(recursive: true);
      return support;
    } on Object {
      return Directory.current;
    }
  }

  @override
  Future<StoredCredentials?> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map<String, dynamic>) return null;
      final baseStr = raw['baseUri'];
      if (baseStr is! String) return null;
      final base = Uri.tryParse(baseStr);
      if (base == null || !base.hasScheme || base.host.isEmpty) return null;
      final token = raw['token'];
      return StoredCredentials(
        baseUri: base,
        token: token is String && token.isNotEmpty ? token : null,
      );
    } on Object {
      // 任何读失败(损坏/权限)都视作无凭证 —— 走重新登录,不崩。
      return null;
    }
  }

  @override
  Future<void> save(StoredCredentials credentials) async {
    try {
      final f = await _file();
      await f.writeAsString(encodeCredentialsJson(credentials));
      // dart:io 无 chmod API;目录在应用沙箱内(移动端)/单用户目录(桌面),
      // 敏感性由令牌可吊销兜底。
    } on Object {
      // 持久化失败不阻断登录流程(下次启动重登)。
    }
  }

  @override
  Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } on Object {}
  }
}
