// M4 图片附件:尺寸探测、本地预拒、payload 构造、带图 prompt 全链路。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/attachments.dart';
import 'package:singleman/sessions/session_store.dart';

import '../helpers/fake_dsh_host.dart';

/// 生成最小合法 PNG(IHDR 头,1x1 灰像素)。
Uint8List tinyPng() {
  final b = BytesBuilder();
  b.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); // 签名
  void chunk(String type, List<int> data) {
    final bd = ByteData(4)..setUint32(0, data.length, Endian.big);
    b.add(bd.buffer.asUint8List());
    b.add(type.codeUnits);
    b.add(data);
    // CRC 省略:探测只读宽高。
    b.add([0, 0, 0, 0]);
  }
  final ihdr = ByteData(13);
  ihdr.setUint32(0, 1, Endian.big); // width
  ihdr.setUint32(4, 1, Endian.big); // height
  ihdr.setUint8(8, 8); // bit depth
  ihdr.setUint8(9, 0); // color type
  b.add([]);
  chunk('IHDR', ihdr.buffer.asUint8List());
  return b.toBytes();
}

void main() {
  test('probeImageSize reads PNG header', () {
    final png = tinyPng();
    expect(probeImageSize(png, 'image/png'), (1, 1));
    expect(probeImageSize(png, 'image/gif'), isNull); // 格式不符
  });

  test('readImageFile maps extension to closed mediaType set', () {
    final tmp = Directory.systemTemp.createTempSync('singleman-img');
    final path = tmp.path + '/a.png';
    File(path).writeAsBytesSync(tinyPng());
    final img = readImageFile(path)!;
    expect(img.mediaType, 'image/png');
    expect((img.width, img.height), (1, 1));
    expect(img.name, 'a.png');
    final bad = tmp.path + '/a.bmp';
    File(bad).writeAsBytesSync([1, 2, 3]);
    expect(readImageFile(bad), isNull);
    tmp.deleteSync(recursive: true);
  });

  test('validateImages enforces all four limits', () {
    const limits = AttachmentLimits(
      maxImageBytes: 100,
      maxImagesPerMessage: 2,
      maxMessageImageBytes: 150,
      maxImagePixels: 25,
      mediaTypes: {'image/png'},
    );
    final small = PendingImage(bytes: Uint8List(60), mediaType: 'image/png', width: 4, height: 4);
    final big = PendingImage(bytes: Uint8List(101), mediaType: 'image/png', width: 1, height: 1);
    final manyPx = PendingImage(bytes: Uint8List(10), mediaType: 'image/png', width: 6, height: 6);
    final wrongType = PendingImage(bytes: Uint8List(10), mediaType: 'image/webp', width: 1, height: 1);

    expect(validateImages([small], limits), isNull);
    expect(validateImages([big], limits), contains('单张图片超限'));
    expect(validateImages([manyPx], limits), contains('像素超限'));
    expect(validateImages([wrongType], limits), contains('不支持的媒体类型'));
    expect(validateImages([small, small, small], limits), contains('图片数量超限'));
    final a = PendingImage(bytes: Uint8List(80), mediaType: 'image/png', width: 1, height: 1);
    final c = PendingImage(bytes: Uint8List(80), mediaType: 'image/png', width: 1, height: 1);
    expect(validateImages([a, c], limits), contains('总字节超限'));
  });

  test('buildPromptContent embeds base64 image blocks', () {
    final png = tinyPng();
    final img = PendingImage(bytes: png, mediaType: 'image/png', width: 1, height: 1, name: 'x.png');
    final content = buildPromptContent('看图', [img]);
    expect(content[0], {'type': 'text', 'text': '看图'});
    final imageBlock = content[1];
    expect(imageBlock['type'], 'image');
    expect(imageBlock['mediaType'], 'image/png');
    expect(imageBlock['name'], 'x.png');
    expect(imageBlock['data'], isNot(contains('[')));
  });

  test('promptWithImages round trips; local pre-rejection fires before wire', () async {
    final host = await FakeDshHost.start();
    final controller = ConnectionController(
      baseUri: host.baseUri,
      initialBackoff: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 150),
      probeTimeout: const Duration(milliseconds: 400),
    );
    final api = ApiClient(baseUri: host.baseUri);
    final store = SessionStore(api: api, connection: controller);
    controller.start();
    store.start();
    addTearDown(() async {
      await store.dispose();
      await controller.dispose();
      api.dispose();
      await host.stop();
    });
    await store.summaries.first.timeout(const Duration(seconds: 3));

    // 装载历史以取 imageLimits 投影。
    await store.loadHistory('session-s1');
    final limits = store.attachmentLimitsFor('session-s1');
    expect(limits, isNotNull);

    // 超限 → ArgumentError,不打网络。
    final huge = PendingImage(
      bytes: Uint8List(limits!.maxImageBytes + 1),
      mediaType: 'image/png',
      width: 1,
      height: 1,
    );
    await expectLater(
      store.promptWithImages('session-s1', 'x', [huge]),
      throwsA(isA<ArgumentError>()),
    );
    expect(host.promptRequests, isEmpty);

    // 合法 → 信封包含 image 块。
    final img = PendingImage(bytes: tinyPng(), mediaType: 'image/png', width: 1, height: 1);
    final value = await store.promptWithImages('session-s1', '看图说话', [img]);
    expect(value.accepted, isTrue);
    final payload = host.promptRequests.single;
    final content = payload['content'] as List;
    expect(content, hasLength(2));
    expect(content[1]['type'], 'image');
    expect(content[1]['mediaType'], 'image/png');
  });
}
