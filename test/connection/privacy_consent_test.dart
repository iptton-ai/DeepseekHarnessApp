// 隐私同意状态测试(OHOS 首启门):默认未同意/同意往返/版本陈旧重新过门/
// 损坏文件从严/判定纯函数。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/privacy_consent.dart';

void main() {
  late Directory tmp;
  late String path;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('singleman-privacy');
    path = '${tmp.path}/privacy-consent.json';
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('privacyConsentMatches', () {
    test('null / 损坏 / 非对象 一律 false', () {
      expect(privacyConsentMatches(null, 'v1'), isFalse);
      expect(privacyConsentMatches('not json', 'v1'), isFalse);
      expect(privacyConsentMatches('[1,2]', 'v1'), isFalse);
      expect(privacyConsentMatches('{"version": 3}', 'v1'), isFalse);
    });

    test('版本精确匹配才算同意', () {
      expect(
        privacyConsentMatches(jsonEncode({'version': 'v1'}), 'v1'),
        isTrue,
      );
      expect(
        privacyConsentMatches(jsonEncode({'version': 'v0'}), 'v1'),
        isFalse,
      );
    });
  });

  group('PrivacyConsentStore', () {
    test('无文件 → 未同意;agree() → 同意且落盘版本与时间戳', () async {
      final store = PrivacyConsentStore(overridePath: path);
      expect(await store.isAgreed, isFalse);

      await store.agree();
      expect(await store.isAgreed, isTrue);

      final decoded = jsonDecode(await File(path).readAsString());
      expect(decoded, isA<Map>());
      expect(decoded['version'], kPrivacyPolicyVersion);
      expect(decoded['agreedAt'], isA<String>());
    });

    test('政策升版 → 旧同意作废,重新过门', () async {
      final old = PrivacyConsentStore(overridePath: path);
      await old.agree();

      // 旧版本文件(模拟历史版本同意)。
      await File(path).writeAsString(
        jsonEncode({'version': '2026-08-01.1', 'agreedAt': 'x'}),
      );
      final store = PrivacyConsentStore(overridePath: path);
      expect(await store.isAgreed, isFalse);

      await store.agree();
      expect(await store.isAgreed, isTrue);
    });

    test('文件损坏 → 从严视为未同意', () async {
      await File(path).writeAsString('{broken');
      final store = PrivacyConsentStore(overridePath: path);
      expect(await store.isAgreed, isFalse);
    });
  });
}
