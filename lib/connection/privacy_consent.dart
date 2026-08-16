// OHOS 首启隐私政策同意状态(华为应用市场合规要求):
// 用户点「同意并继续」之前,应用不得初始化任何网络连接 —— main() 里
// 隐私门挡在 boot()(连接启动)之前,而非仅在 UI 上盖一层。
// 持久化 ~/.singleman/privacy-consent.json(HOME 优先,path_provider 兜底,
// 同 FileCredentialStore/DeviceNameStore 布局;测试用 overridePath)。
// 版本化:政策实质变更时升 kPrivacyPolicyVersion,已同意旧版本的用户
// 下次启动重新过门。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 当前隐私政策版本(政策实质变更时更新)。
/// .2:权限披露修正 —— 相机权限为移动三端(Android/iOS/OHOS)共有,非仅 Android。
const String kPrivacyPolicyVersion = '2026-08-16.2';

/// 完整隐私政策网页(与应用市场「隐私政策」栏同源)。
/// 仓库内只放占位符(防泄漏围栏禁真实域名);发布/上架构建注入
/// --dart-define=DSHAPP_PRIVACY_POLICY_URL=<真实政策页地址>(见本地发布文档)。
const String kPrivacyPolicyUrl = String.fromEnvironment(
  'DSHAPP_PRIVACY_POLICY_URL',
  defaultValue: 'https://dsh.example.com/dshapp/privacy.html',
);

/// 同意文件内容判定:版本等于 [version] → true;缺失/损坏/陈旧 → false。
bool privacyConsentMatches(String? content, String version) {
  if (content == null) return false;
  try {
    final decoded = jsonDecode(content);
    return decoded is Map && decoded['version'] == version;
  } on FormatException {
    return false;
  }
}

/// 隐私同意状态存取。读失败一律视作未同意(合规从严)。
class PrivacyConsentStore {
  PrivacyConsentStore({String? overridePath}) : _overridePath = overridePath;

  final String? _overridePath;
  File? _resolved;

  Future<File> _file() async {
    final resolved = _resolved;
    if (resolved != null) return resolved;

    final overridePath = _overridePath;
    if (overridePath != null) {
      return _resolved = File(overridePath);
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final directory = Directory('$home/.singleman');
      await directory.create(recursive: true);
      return _resolved = File('${directory.path}/privacy-consent.json');
    }

    File file;
    try {
      final support = await getApplicationSupportDirectory();
      await support.create(recursive: true);
      file = File('${support.path}/privacy-consent.json');
    } on Object {
      file = File('privacy-consent.json');
    }
    return _resolved = file;
  }

  /// 是否已同意当前版本的政策。
  Future<bool> get isAgreed async {
    try {
      final f = await _file();
      if (!await f.exists()) return false;
      return privacyConsentMatches(
        await f.readAsString(),
        kPrivacyPolicyVersion,
      );
    } on Object {
      return false;
    }
  }

  /// 记录同意(当前版本 + UTC 时间戳)。写失败不抛:本次会话照常进入,
  /// 代价是下次启动重弹一次(合规可接受)。
  Future<void> agree() async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode(<String, Object?>{
          'version': kPrivacyPolicyVersion,
          'agreedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } on Object {
      // 同上:持久化失败不阻断进入应用。
    }
  }
}
