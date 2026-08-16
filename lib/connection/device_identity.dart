// 本机设备名(设备侧身份):配对/登录时上报给网关的 `device` 字段,
// 宿主「已配对设备」表展示。默认 = 设备类型-无权限机器特征,可改,持久化。
//
// 默认生成(零权限):
// - iOS/macOS:Platform.localHostname(= 用户给设备起的名字,如「Zxnap 的
//   iPhone」,剥掉 .local 后缀)—— 本身就是「设备类型-特征」且可读;
// - Android:localHostname 通常只剩 'localhost'(系统不暴露设备名),
//   落到 device_info_plus 的 Build.MODEL(无需任何权限)→ 'Android-<model>';
// - 其余平台:'dshapp-<os>' 兜底。
// 清洗:去控制符/折叠空白/≤32 码点;空或泛称(localhost)视为无效。
// 持久化:~/.singleman/device-name.txt(HOME 优先,path_provider 兜底,
// 同 FileCredentialStore 布局;测试用 overridePath)。
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 设备名清洗:去控制符、折叠空白、剥域名尾巴、≤32 码点。
String sanitizeDeviceName(String raw) {
  final s = raw
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final stripped = s.replaceFirst(RegExp(r'\.(local|lan|home)$'), '');
  return String.fromCharCodes(stripped.runes.take(32));
}

bool _isGeneric(String name) =>
    name.isEmpty || name == 'localhost' || name == '127.0.0.1' || name == '::1';

/// 生成默认设备名(探针可注入,测试用)。
Future<String> generateDefaultDeviceName({
  String? localHostname,
  Future<String?> Function()? androidModel,
}) async {
  final host = sanitizeDeviceName(localHostname ?? Platform.localHostname);
  if (!_isGeneric(host)) return host;
  if (Platform.isAndroid || androidModel != null) {
    final model = sanitizeDeviceName(
      await (androidModel?.call() ?? _readAndroidModel()) ?? '',
    );
    return model.isEmpty ? 'Android' : 'Android-$model';
  }
  return 'dshapp-${Platform.operatingSystem}';
}

Future<String?> _readAndroidModel() async {
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    return info.model;
  } on Object {
    return null; // 插件缺席/平台通道异常 → 兜底「Android」
  }
}

/// 设备名存取 + 通知。null = 未装载(load 前/读失败)。
class DeviceNameStore {
  DeviceNameStore({String? overridePath})
    : _overridePath = overridePath,
      name = ValueNotifier<String?>(null);

  /// overridePath 优先(测试);HOME/.singleman 其次;path_provider 兜底。
  final String? _overridePath;
  File? _resolved;

  final ValueNotifier<String?> name;
  ValueListenable<String?> get listenable => name;

  Future<File> _file() async {
    final resolved = _resolved;
    if (resolved != null) return resolved;

    final overridePath = _overridePath;
    if (overridePath != null) {
      final file = File(overridePath);
      _resolved = file;
      return file;
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final directory = Directory('$home/.singleman');
      await directory.create(recursive: true);
      final file = File('${directory.path}/device-name.txt');
      _resolved = file;
      return file;
    }

    File file;
    try {
      final support = await getApplicationSupportDirectory();
      await support.create(recursive: true);
      file = File('${support.path}/device-name.txt');
    } on Object {
      file = File('device-name.txt');
    }
    _resolved = file;
    return file;
  }

  /// 装载:文件里的用户设置优先;缺失/损坏 → 生成默认并回写。
  Future<void> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final saved = sanitizeDeviceName(await f.readAsString());
        if (!_isGeneric(saved)) {
          name.value = saved;
          return;
        }
      }
    } on Object {
      // 读失败落到默认生成,不崩。
    }
    final generated = await generateDefaultDeviceName();
    name.value = generated;
    await _persist(generated);
  }

  /// 设置设备名(清洗后落盘);空/泛称拒绝(返回 false)。
  Future<bool> set(String raw) async {
    final next = sanitizeDeviceName(raw);
    if (_isGeneric(next)) return false;
    name.value = next;
    await _persist(next);
    return true;
  }

  Future<void> _persist(String value) async {
    try {
      final f = await _file();
      await f.writeAsString(value);
    } on Object {
      // 持久化失败不阻断本次会话(下次启动回落默认)。
    }
  }
}

/// UI 侧取当前上报值:store 未装载/空时退回旧字面量(行为兜底)。
String deviceLabelOr(ValueListenable<String?>? store, String fallback) {
  final v = store?.value;
  if (v == null || v.isEmpty) return fallback;
  return v;
}
