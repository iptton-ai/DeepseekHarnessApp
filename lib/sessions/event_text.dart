// session/event → 文本提取(纯 Dart;VM 与冒烟脚本共用,不 import flutter)。
///
/// 形状差异(实测 dsh 0.1.0-rc.6):
/// - user/message: data.content[] 直接是块数组
/// - assistant/message: 块数组在 data.message.content[](顶层还有 turn/step)
/// 只取 type=='text' 块拼接;reasoning 等其他块不冒泡。未知形状降级空串
/// (事件仍计入日志,只是不渲染)。
String extractText(dynamic data) {
  if (data is! Map) return '';
  var content = data['content'];
  if (content is! List) {
    final nested = data['message'];
    if (nested is Map) content = nested['content'];
  }
  if (content is! List) {
    final text = data['text'];
    return text is String ? text : '';
  }
  final parts = <String>[];
  for (final block in content) {
    if (block is Map && block['type'] == 'text') {
      final t = block['text'];
      if (t is String && t.isNotEmpty) parts.add(t);
    }
  }
  return parts.join('\n');
}
