// DeviceNameStore 单元:默认生成(iOS/macOS 取 localHostname、Android 取
// Build.MODEL)、清洗、持久化往返、set 校验。探针注入,不碰真机。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/device_identity.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('singleman-device-');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('generateDefaultDeviceName(探针注入)', () {
    test('localHostname 有意义(如 iOS 用户命名)→ 直接用,剥域名尾巴', () async {
      final n = await generateDefaultDeviceName(localHostname: 'Zxnap 的 iPhone.local');
      expect(n, 'Zxnap 的 iPhone');
    });

    test('localHostname 泛称 + Android → Android-<model>(无权限特征)', () async {
      final n = await generateDefaultDeviceName(
        localHostname: 'localhost',
        androidModel: () async => 'Pixel 8 Pro',
      );
      expect(n, 'Android-Pixel 8 Pro');
    });

    test('model 探针失败 → 兜底 Android', () async {
      final n = await generateDefaultDeviceName(
        localHostname: 'localhost',
        androidModel: () async => null,
      );
      expect(n, 'Android');
    });

    test('超长 hostname 截到 32 码点(中文按码点计)', () async {
      final long = 'A' * 50;
      final n = await generateDefaultDeviceName(localHostname: long);
      expect(n.length, 32);
    });
  });

  group('sanitizeDeviceName', () {
    test('控制符折叠为空格、连续空白折叠', () {
      expect(sanitizeDeviceName('a\u0007b\u001fc  d'), 'a b c d');
    });
    test('.lan/.home 尾巴剥除,.local 亦然', () {
      expect(sanitizeDeviceName('myphone.local'), 'myphone');
      expect(sanitizeDeviceName('myphone.lan'), 'myphone');
      expect(sanitizeDeviceName('myphone.home'), 'myphone');
    });
  });

  group('DeviceNameStore 持久化', () {
    test('首次 load:无文件 → 生成默认并回写;二次 load 读回用户设置', () async {
      final path = '${tmp.path}/device-name.txt';
      final store = DeviceNameStore(overridePath: path);
      await store.load();
      final first = store.name.value;
      expect(first, isNotNull);
      expect(File(path).existsSync(), isTrue, reason: '默认名回写,避免每次启动漂移');

      await File(path).writeAsString('我的手机');
      final store2 = DeviceNameStore(overridePath: path);
      await store2.load();
      expect(store2.name.value, '我的手机');
    });

    test('set:合法名持久化 + 通知;空/泛称/纯空白拒绝', () async {
      final path = '${tmp.path}/device-name.txt';
      final store = DeviceNameStore(overridePath: path);
      await store.load();

      expect(await store.set('我的手机'), isTrue);
      expect(store.name.value, '我的手机');
      expect(await File(path).readAsString(), '我的手机');

      expect(await store.set('   '), isFalse);
      expect(await store.set('localhost'), isFalse);
      expect(store.name.value, '我的手机', reason: '拒绝不改当前值');
    });

    test('损坏文件回落默认不崩', () async {
      final path = '${tmp.path}/device-name.txt';
      await File(path).writeAsString('\u0000\u0001'); // 清洗后为空 → 视为损坏
      final store = DeviceNameStore(overridePath: path);
      await store.load();
      expect(store.name.value, isNotNull);
    });
  });

  test('deviceLabelOr:未装载/空回退 fallback', () {
    final n = ValueNotifier<String?>(null);
    expect(deviceLabelOr(n, 'singleman-android'), 'singleman-android');
    n.value = '';
    expect(deviceLabelOr(n, 'singleman-android'), 'singleman-android');
    n.value = '我的手机';
    expect(deviceLabelOr(n, 'singleman-android'), '我的手机');
    expect(deviceLabelOr(null, 'x'), 'x');
  });
}
