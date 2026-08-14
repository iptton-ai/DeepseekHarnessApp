// 图片附件 intake(M4):本地预拒 + base64 上行 payload 构造。
//
// 契约(DSH-PROTOCOL §7 + sessions.schema):
// - promptContentPart image 分支:{type:'image', mediaType, data(base64), name?}
// - mediaType 闭合枚举:image/png | image/jpeg | image/webp | image/gif
// - imageLimits 投影(host 下发,per-boot 常量):maxImageBytes 单张字节 /
//   maxImagesPerMessage 张数 / maxMessageImageBytes 每条消息总字节 /
//   maxImagePixels 像素 —— intake 前本地拒绝超限,省一次上行往返
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class AttachmentLimits {
  const AttachmentLimits({
    required this.maxImageBytes,
    required this.maxImagesPerMessage,
    required this.maxMessageImageBytes,
    required this.maxImagePixels,
    required this.mediaTypes,
  });
  final int maxImageBytes;
  final int maxImagesPerMessage;
  final int maxMessageImageBytes;
  final int maxImagePixels;
  final Set<String> mediaTypes;

  static AttachmentLimits? fromProjection(Map<String, dynamic> p) {
    if (!p.containsKey('maxImageBytes')) return null;
    return AttachmentLimits(
      maxImageBytes: (p['maxImageBytes'] as num).toInt(),
      maxImagesPerMessage: (p['maxImagesPerMessage'] as num).toInt(),
      maxMessageImageBytes: (p['maxMessageImageBytes'] as num).toInt(),
      maxImagePixels: (p['maxImagePixels'] as num).toInt(),
      mediaTypes: (p['mediaTypes'] as List).cast<String>().toSet(),
    );
  }
}

/// 单张图片的内存表示(尺寸探测结果一并携带)。
class PendingImage {
  const PendingImage({
    required this.bytes,
    required this.mediaType,
    required this.width,
    required this.height,
    this.name,
  });
  final Uint8List bytes;
  final String mediaType;
  final int width;
  final int height;
  final String? name;
}

/// 探测 PNG/JPEG/GIF/WEBP 尺寸(纯头部解析,不 decode 像素)。
/// 返回 null = 无法识别的格式。
(int, int)? probeImageSize(Uint8List bytes, String mediaType) {
  switch (mediaType) {
    case 'image/png':
      // PNG: 8 字节签名 + IHDR(宽高在 16..24)
      if (bytes.length < 24 || bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4E) return null;
      final w = bytes.buffer.asByteData().getUint32(16, Endian.big);
      final h = bytes.buffer.asByteData().getUint32(20, Endian.big);
      return (w, h);
    case 'image/gif':
      if (bytes.length < 10) return null;
      if (bytes[0] != 0x47 || bytes[1] != 0x49 || bytes[2] != 0x46) return null; // 'GIF'
      final d = bytes.buffer.asByteData();
      return (d.getUint16(6, Endian.little), d.getUint16(8, Endian.little));
    case 'image/jpeg':
      // 扫 JPEG 段找 SOF0/2 (C0/C2)
      var i = 2;
      while (i + 9 < bytes.length) {
        if (bytes[i] != 0xFF) {
          i += 1;
          continue;
        }
        final marker = bytes[i + 1];
        if (marker == 0xC0 || marker == 0xC2) {
          final d = bytes.buffer.asByteData(i + 2);
          return (d.getUint16(5, Endian.big), d.getUint16(3, Endian.big));
        }
        final len = bytes.buffer.asByteData(i + 2).getUint16(0, Endian.big);
        i += 2 + len;
      }
      return null;
    case 'image/webp':
      if (bytes.length < 30) return null;
      final d = bytes.buffer.asByteData(12);
      // VP8X(宽高 24bit - 1);VP8/VP8L 简化:直接读 VP8X 常见布局,失败给 null
      final chunk = String.fromCharCodes(bytes.sublist(12, 16));
      if (chunk != 'VP8X') return null;
      final w = bytes.buffer.asByteData(24).getUint32(0, Endian.little) & 0xFFFFFF;
      final h = bytes.buffer.asByteData(27).getUint32(0, Endian.little) >> 8;
      return (w + 1, h + 1);
  }
  return null;
}

/// 读取文件 + 探测尺寸;媒体类型按扩展名映射(与闭合枚举对齐)。
/// 返回 null = 扩展名不支持。
PendingImage? readImageFile(String path) {
  final ext = path.split('.').last.toLowerCase();
  const extMap = <String, String>{
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };
  final mediaType = extMap[ext];
  if (mediaType == null) return null;
  final bytes = File(path).readAsBytesSync();
  final size = probeImageSize(bytes, mediaType) ?? (0, 0);
  final name = path.split(Platform.pathSeparator).last;
  return PendingImage(
    bytes: bytes,
    mediaType: mediaType,
    width: size.$1,
    height: size.$2,
    name: name,
  );
}

/// 本地预拒:返回 null = 通过;否则拒绝原因(不构造 payload、不上行)。
String? validateImages(List<PendingImage> images, AttachmentLimits limits) {
  if (images.length > limits.maxImagesPerMessage) {
    return '图片数量超限(' + images.length.toString() + ' > ' + limits.maxImagesPerMessage.toString() + ')';
  }
  var total = 0;
  for (final img in images) {
    if (!limits.mediaTypes.contains(img.mediaType)) {
      return '不支持的媒体类型: ' + img.mediaType;
    }
    if (img.bytes.length > limits.maxImageBytes) {
      return '单张图片超限(' + img.bytes.length.toString() + ' > ' + limits.maxImageBytes.toString() + ' 字节)';
    }
    if (img.width * img.height > limits.maxImagePixels) {
      return '像素超限(' + (img.width * img.height).toString() + ' > ' + limits.maxImagePixels.toString() + ')';
    }
    total += img.bytes.length;
  }
  if (total > limits.maxMessageImageBytes) {
    return '消息图片总字节超限(' + total.toString() + ' > ' + limits.maxMessageImageBytes.toString() + ')';
  }
  return null;
}

/// 构造 prompt content 数组:文本块 + 图片块(base64)。
List<Map<String, dynamic>> buildPromptContent(String text, List<PendingImage> images) {
  return <Map<String, dynamic>>[
    <String, dynamic>{'type': 'text', 'text': text},
    for (final img in images)
      <String, dynamic>{
        'type': 'image',
        'mediaType': img.mediaType,
        'data': base64Encode(img.bytes),
        if (img.name != null) 'name': img.name,
      },
  ];
}
