// 直连路径探针:与 GUI 完全相同的 createDirectHttpClient + describe 调用。
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

Future<void> main() async {
  print('env http_proxy=' + (Platform.environment['http_proxy'] ?? '(none)'));
  print('env HTTPS_PROXY=' + (Platform.environment['HTTPS_PROXY'] ?? '(none)'));
  print('env ALL_PROXY=' + (Platform.environment['ALL_PROXY'] ?? '(none)'));
  final api = ApiClient(baseUri: Uri.parse('http://127.0.0.1:3080'));
  try {
    final v = await api.call(
      RpcMethods.hostDescribe,
      <String, dynamic>{},
      parse: HostDescribeValue.fromJson,
      timeout: const Duration(seconds: 8),
    );
    print('DESCRIBE-OK version=' + v.version + ' model=' + (v.model ?? '?'));
  } on Object catch (e) {
    print('DESCRIBE-FAIL: ' + e.toString());
  } finally {
    api.dispose();
  }
}
