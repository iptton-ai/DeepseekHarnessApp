// 图片引用提取(fixture 验收;本部署无视觉模型,PROTOCOL §9 冻结)。
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

SessionEvent _evt(int seq, String type, Map<String, dynamic> data) {
  return SessionEvent.fromJson(<String, dynamic>{
    'type': type, 'seq': seq, 'time': 1786760000000 + seq, 'data': data,
  });
}

void main() {
  test('user/message 带 image 块 → ChatNodeUser.images 填充', () {
    final nodes = extractNodes([eventInput(_evt(1, 'user/message', {
      'content': [
        {'type': 'text', 'text': '看这张图'},
        {
          'type': 'image',
          'attachmentId': 'att-1',
          'mediaType': 'image/png',
          'bytes': 1200,
          'width': 800,
          'height': 600,
          'name': 'shot.png',
        },
      ],
    }))]);
    final user = nodes.whereType<ChatNodeUser>().single;
    expect(user.text, '看这张图');
    expect(user.images, hasLength(1));
    expect(user.images!.first.attachmentId, 'att-1');
    expect(user.images!.first.width, 800);
    expect(user.images!.first.name, 'shot.png');
  });

  test('缺关键字段的 image 块被跳过(不猜)', () {
    final nodes = extractNodes([eventInput(_evt(2, 'user/message', {
      'content': [
        {'type': 'text', 'text': 'x'},
        {'type': 'image', 'attachmentId': 'att-2'}, // 缺 mediaType 等
      ],
    }))]);
    final user = nodes.whereType<ChatNodeUser>().single;
    expect(user.images, isNull);
  });

  test('纯图消息(无文本)也产节点', () {
    final nodes = extractNodes([eventInput(_evt(3, 'user/message', {
      'content': [
        {'type': 'image', 'attachmentId': 'a', 'mediaType': 'image/jpeg', 'bytes': 10, 'width': 1, 'height': 1},
      ],
    }))]);
    expect(nodes.whereType<ChatNodeUser>().single.images, hasLength(1));
  });

  test('assistant/message 带 images 数组(另一种线上形状)也能提取', () {
    final nodes = extractNodes([eventInput(_evt(4, 'assistant/message', {
      'content': [
        {'type': 'text', 'text': '分析如下'},
      ],
      'images': [
        {'attachmentId': 'b', 'mediaType': 'image/png', 'bytes': 9, 'width': 2, 'height': 2},
      ],
    }))]);
    final asst = nodes.whereType<ChatNodeAssistant>().single;
    expect(asst.images, hasLength(1));
    expect(asst.images!.first.mediaType, 'image/png');
  });
}
