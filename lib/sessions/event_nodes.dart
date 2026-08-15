// session/event → 会话流节点提取(纯 Dart;不 import flutter)。
//
// 职责(DSH-PROTOCOL §4 + audit/conversation + 本机真实日志普查):
// 把原始事件日志升级为 web 同款节点流 —— 用户气泡 / 助手消息(markdown)/
// think 折叠块 / 工具卡(call+result 经 ToolEventView 配对)/ todo 计划快照 /
// 压缩检查点 / 重试行 / 错误行 / 系统短提示 / 未知类型兜底。
//
// 事件词表对齐 dsh-session known-event-types.js(0.1.0-rc.6,真实日志普查):
// - assistant/chunk:流式增量(data.turn/step/chunk),按 (turn,step) 折叠为
//   直播节点;同步 assistant/message 到达即被定稿替换(不折叠)
// - tool/call|result:工具卡;result 的 callId/输出藏在
//   data.message.source.callId 与 data.message.content[].tool-result 里,
//   无 view 的历史回放也能完整渲染
// - tool/code-dispatch*:run_code 派发的内部子调用,归入内部事件(父卡已
//   汇总输出,重复展示只是噪音)
// - approval/asked|decided:审批轨迹短提示(注意:approval/resolved 是 mux
//   帧类型,不是会话事件)
// - step/*、request/*、session/title*、subagent/descriptor、feedback/record、
//   hook/*、web/*-llm-request:协议管道,不进主聊天流
//
// 不变式(头注释即契约):
// - 纯函数、可重放:同输入必同输出,无任何外部状态
// - 按 seq 升序输出(输入乱序也先排,配对按 seq 顺序进行)
// - 与 event_text.dart 并存不冲突:本文件产出结构化节点流,
//   event_text 只给纯文本,集成方择一
//
// view 来源:MuxFrameSessionEvent.view(实时 mux 帧,主机算好的渲染意图,
// 不落盘,同事件不同时刻可不同)。SessionLog 目前只存 SessionEvent 不带
// view —— 集成方如需保留 view,自行扩展 SessionLog(不在本文件范围)。
// 提取器输入是 (SessionEvent, ToolEventView?) 对(EventNodeInput):
// view 只作渲染增强,工具卡的本质信息以 event.data 为准,因此历史回放
// (无 view)也能渲染工具卡。
import 'dart:convert';

import 'package:singleman/sessions/event_text.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 工具卡状态(由渲染意图/数据判定:运行/成功/失败/中断)。
enum ToolStatus { running, success, failed, interrupted }

/// 会话流节点(sealed)。每个节点携带来源事件的 seq 与原始类型名。
sealed class ChatNode {
  const ChatNode({required this.seq, required this.type});
  final int seq;
  final String type;
}

/// 用户气泡(右对齐;agent.inject 的合成上下文被过滤,对齐 chat_view_model)。
class ChatNodeUser extends ChatNode {
  const ChatNodeUser({
    required super.seq,
    required super.type,
    required this.text,
    this.images,
  });
  final String text;

  /// 图片附件引用(本部署无视觉模型,线上暂无真实样本;形状防御式提取,见
  /// _imageRefs —— fixture 验收,有视觉模型后活体复验)。
  final List<ImageAttachmentRef>? images;
}

/// 助手消息(markdown 文本,UI 用 MarkdownWidget 渲染)。
/// [streaming] = 由 assistant/chunk 折叠出的直播节点(尚无定稿 message)。
class ChatNodeAssistant extends ChatNode {
  const ChatNodeAssistant({
    required super.seq,
    required super.type,
    required this.text,
    this.images,
    this.streaming = false,
  });
  final String text;
  final List<ImageAttachmentRef>? images;
  final bool streaming;
}

/// think 折叠块(默认收起,点开显示全文;streaming 时 UI 自动展开)。
class ChatNodeThink extends ChatNode {
  const ChatNodeThink({
    required super.seq,
    required super.type,
    required this.text,
    this.streaming = false,
  });
  final String text;
  final bool streaming;
}

/// 工具卡:call+result 配对后的渲染意图;未配对 call 保持运行中。
class ChatNodeTool extends ChatNode {
  const ChatNodeTool({
    required super.seq,
    required super.type,
    required this.toolName,
    this.callId,
    this.input,
    this.output,
    this.error,
    this.summary,
    this.status = ToolStatus.running,
    this.callSeq,
    this.resultSeq,
  });
  final String toolName;
  final String? callId;
  final dynamic input;
  final dynamic output;
  final String? error;

  /// 摘要行文本(来自 view;缺失时提取器按输入生成预览)。
  final String? summary;
  final ToolStatus status;
  final int? callSeq;
  final int? resultSeq;
}

/// todo/write 计划快照(紧凑状态计数卡)。
class ChatNodeTodo extends ChatNode {
  const ChatNodeTodo({
    required super.seq,
    required super.type,
    required this.items,
  });
  final List<TodoItem> items;
  int get done => items.where((i) => i.done).length;
  int get total => items.length;
}

/// 计划单项。
class TodoItem {
  const TodoItem({required this.title, this.done = false});
  final String title;
  final bool done;
}

/// 压缩检查点(compaction/start|end|summary|prune)。
class ChatNodeCompaction extends ChatNode {
  const ChatNodeCompaction({
    required super.seq,
    required super.type,
    required this.kind,
    this.summary,
    this.messages,
  });
  final String kind; // start | end | summary | prune
  final String? summary;
  final int? messages;
}

/// llm/retry 重试行(内联细行)。
class ChatNodeRetry extends ChatNode {
  const ChatNodeRetry({
    required super.seq,
    required super.type,
    this.reason,
    this.attempt,
    this.maxRetries,
  });
  final String? reason;
  final int? attempt;
  final int? maxRetries;
}

/// turn/error 错误行。
class ChatNodeError extends ChatNode {
  const ChatNodeError({
    required super.seq,
    required super.type,
    required this.message,
  });
  final String message;
}

/// 未知类型兜底(类型名 + 原始 data 折叠展示)。
class ChatNodeUnknown extends ChatNode {
  const ChatNodeUnknown({
    required super.seq,
    required super.type,
    required this.data,
  });
  final dynamic data;
}

/// 已知但不应直接暴露协议名的系统事件。
/// 主聊天流只展示经过人类语言整理的短提示,原始 payload 仍保留在轨迹视图。
class ChatNodeNotice extends ChatNode {
  const ChatNodeNotice({
    required super.seq,
    required super.type,
    required this.title,
    this.detail,
    this.icon = 'info',
  });
  final String title;
  final String? detail;
  final String icon;
}

/// 提取输入对:事件 + 主机渲染意图(view 可选,仅作渲染增强)。
/// 历史回放(无 view)直接传 [EventNodeInput(event)] 即可。
class EventNodeInput {
  const EventNodeInput(this.event, [this.view]);
  final SessionEvent event;
  final ToolEventView? view;
}

/// 便捷构造:仅事件(历史回放,无 view)。
EventNodeInput eventInput(SessionEvent event) => EventNodeInput(event);

/// 便捷构造:事件 + 渲染意图(mux 实时帧的 view)。
EventNodeInput eventInputWithView(SessionEvent event, ToolEventView view) =>
    EventNodeInput(event, view);

/// 提取器:List[EventNodeInput] → List[ChatNode](按 seq 升序,可重放)。
List<ChatNode> extractNodes(List<EventNodeInput> inputs) {
  final sorted = List<EventNodeInput>.of(inputs)
    ..sort((a, b) => a.event.seq.compareTo(b.event.seq));
  final result = <ChatNode>[];
  // 未配对 call 的占位:记录它在 result 中的下标,结果事件到达时回填合并。
  final pending = <_PendingCall>[];
  for (final input in sorted) {
    final event = input.event;
    final view = input.view;
    if (event.type == 'assistant/chunk' && _chunkOf(event.data) != null) {
      continue; // 折叠态由 _foldChunks 统一产出。
    }
    final kind = _toolKind(event, view);
    if (kind == _ToolKind.call) {
      final node = _buildToolCall(event, view);
      pending.add(_PendingCall(result.length, node.callId));
      result.add(node);
    } else if (kind == _ToolKind.result) {
      final node = _buildToolResult(event, view);
      final idx = _matchPending(pending, node.callId);
      if (idx >= 0) {
        final p = pending.removeAt(idx);
        result[p.index] = _mergeCallResult(
          result[p.index] as ChatNodeTool,
          node,
        );
      } else {
        result.add(node); // 无配对结果的独立卡(按 view 判定状态)。
      }
    } else {
      result.addAll(_nodesFor(event));
    }
  }
  // 流式折叠节点(无定稿 message 的 chunk 游)按 seq 归位插入。
  final folded = _foldChunks(sorted);
  if (folded.isNotEmpty) {
    result.addAll(folded);
    result.sort((a, b) => a.seq.compareTo(b.seq));
  }
  return result;
}

enum _ToolKind { none, call, result }

/// 工具事件判定:优先信 view(主机渲染意图),其次按类型名猜测。
_ToolKind _toolKind(SessionEvent event, ToolEventView? view) {
  if (view is ToolEventViewCall) return _ToolKind.call;
  if (view is ToolEventViewResult) return _ToolKind.result;
  final type = event.type;
  if (type.startsWith('tool/') || type.startsWith('tool:')) {
    if (type.contains('result')) return _ToolKind.result;
    if (type.contains('error')) return _ToolKind.result; // tool/error 视作失败结果。
    return _ToolKind.call;
  }
  return _ToolKind.none;
}

class _PendingCall {
  const _PendingCall(this.index, this.callId);
  final int index;
  final String? callId;
}

/// 配对:先按 callId 精确匹配,否则取最近(最后加入)的未配对 call。
int _matchPending(List<_PendingCall> pending, String? callId) {
  if (callId != null) {
    for (var i = pending.length - 1; i >= 0; i--) {
      if (pending[i].callId == callId) return i;
    }
  }
  return pending.length - 1;
}

ChatNodeTool _buildToolCall(SessionEvent event, ToolEventView? view) {
  final viewMap = view is ToolEventViewCall ? view.view : null;
  final name =
      _pick(event.data, viewMap, ['toolName', 'name', 'tool', 'tool_name']) ??
      'tool';
  final callId = _pick(event.data, viewMap, ['callId', 'call_id', 'id']);
  final rawInput = _pickValue(event.data, viewMap, ['input', 'args', 'arguments']);
  // 线上 arguments 是 JSON 字符串:能解析就解码成结构(展示/摘要都更友好)。
  final input = _maybeDecodeJson(rawInput);
  final summary =
      _pickString(viewMap, ['summary', 'title', 'label']) ??
      _preview(_summarySeed(name, input), 60);
  return ChatNodeTool(
    seq: event.seq,
    type: event.type,
    toolName: name,
    callId: callId,
    input: input,
    summary: summary,
    status: ToolStatus.running,
    callSeq: event.seq,
  );
}

ChatNodeTool _buildToolResult(SessionEvent event, ToolEventView? view) {
  final viewMap = view is ToolEventViewResult ? view.view : null;
  final name =
      _pick(event.data, viewMap, ['toolName', 'name', 'tool', 'tool_name']) ??
      _resultToolName(event.data) ??
      'tool';
  final callId = _pick(event.data, viewMap, ['callId', 'call_id', 'id']) ??
      _resultCallId(event.data);
  final output = _pickValue(event.data, viewMap, [
    'output',
    'result',
    'value',
    'data',
  ]) ?? _resultText(event.data);
  final isError = _resultIsError(event.data);
  final error = _errorOf(event.data, viewMap) ??
      (isError && output is String && output.isNotEmpty ? output : null);
  final status = _statusOf(viewMap, error);
  final summary =
      _pickString(viewMap, ['summary', 'title', 'label']) ??
      _preview(output ?? error, 60);
  return ChatNodeTool(
    seq: event.seq,
    type: event.type,
    toolName: name,
    callId: callId,
    output: output,
    error: error,
    summary: summary,
    status: status,
    resultSeq: event.seq,
  );
}

/// 合并配对:卡出现在 call 位置(seq=call),状态与输出取结果侧。
ChatNodeTool _mergeCallResult(ChatNodeTool call, ChatNodeTool result) =>
    ChatNodeTool(
      seq: call.seq,
      type: call.type,
      toolName: result.toolName != 'tool' ? result.toolName : call.toolName,
      callId: call.callId ?? result.callId,
      input: call.input,
      output: result.output,
      error: result.error,
      summary: result.summary ?? call.summary,
      status: result.status,
      callSeq: call.callSeq ?? call.seq,
      resultSeq: result.resultSeq ?? result.seq,
    );

// ---------------------------------------------------------------------------
// assistant/chunk 流式折叠
// ---------------------------------------------------------------------------

Map<dynamic, dynamic>? _chunkOf(dynamic data) {
  if (data is! Map) return null;
  final chunk = data['chunk'];
  return chunk is Map ? chunk : null;
}

class _FoldedBlock {
  _FoldedBlock(this.kind); // 'reasoning' | 'text' | 'tool-call'
  final String kind;
  final StringBuffer text = StringBuffer();
}

/// 事件序后的 chunk 游 → 直播节点。同 (turn,step) 已有 assistant/message
/// 定稿的游直接丢弃(定稿渲染更完整);否则产出 streaming 节点:
/// 若该步之后出现过任何定界事件(turn/end、step/end、user/message、
/// llm/retry…),说明这一步被中断/翻页,标记为非流式(静态残留)。
List<ChatNode> _foldChunks(List<EventNodeInput> sorted) {
  final groups = <String, List<_FoldedBlock>>{};
  final meta = <String, _ChunkGroupMeta>{};
  for (final input in sorted) {
    final event = input.event;
    final data = event.data;
    if (event.type == 'assistant/chunk') {
      final chunk = _chunkOf(data);
      if (chunk == null) continue;
      final key = _stepKeyOf(data);
      if (key == null) continue;
      final blocks = groups.putIfAbsent(key, () => <_FoldedBlock>[]);
      meta.putIfAbsent(
        key,
        () => _ChunkGroupMeta(firstSeq: event.seq, lastSeq: event.seq),
      )..lastSeq = event.seq;
      final index = (chunk['index'] as num?)?.toInt() ?? blocks.length;
      final type = chunk['type'];
      if (type == 'block-start') {
        while (blocks.length <= index) {
          blocks.add(_FoldedBlock(''));
        }
        blocks[index] = _FoldedBlock(
          (chunk['blockType'] as String?) ?? 'text',
        );
      } else if (type == 'text-delta' || type == 'reasoning-delta') {
        while (blocks.length <= index) {
          blocks.add(_FoldedBlock(''));
        }
        if (blocks[index].kind.isEmpty) {
          blocks[index] = _FoldedBlock(type == 'reasoning-delta' ? 'reasoning' : 'text');
        }
        final t = chunk['text'];
        if (t is String) blocks[index].text.write(t);
      } else if (type == 'block-end') {
        // block-end 携带整块定稿文本(权威);有机会就替换累计值。
        final block = chunk['block'];
        if (block is Map) {
          while (blocks.length <= index) {
            blocks.add(_FoldedBlock(''));
          }
          final t = block['text'];
          if (t is String && t.isNotEmpty) {
            blocks[index]
              ..text.clear()
              ..text.write(t);
          }
        }
      }
      // tool-call-delta:文本流不消费(后续 tool/call 事件自成卡片)。
    }
  }
  if (groups.isEmpty) return const [];
  // 定稿集合 + 定界事件最大 seq。
  final finalized = <String>{};
  var maxSettleSeq = -1;
  for (final input in sorted) {
    final event = input.event;
    if (event.type == 'assistant/message') {
      final key = _stepKeyOf(event.data);
      if (key != null) {
        finalized.add(key);
      }
      maxSettleSeq = event.seq;
    } else if (_settleTypes.contains(event.type)) {
      maxSettleSeq = event.seq;
    }
  }
  final nodes = <ChatNode>[];
  groups.forEach((key, blocks) {
    if (finalized.contains(key)) return;
    final m = meta[key]!;
    final streaming = m.lastSeq >= maxSettleSeq;
    final reasoning = blocks
        .where((b) => b.kind == 'reasoning' && b.text.isNotEmpty)
        .map((b) => b.text.toString())
        .join('\n');
    final text = blocks
        .where((b) => b.kind == 'text' && b.text.isNotEmpty)
        .map((b) => b.text.toString())
        .join('\n');
    if (reasoning.isNotEmpty) {
      nodes.add(
        ChatNodeThink(
          seq: m.lastSeq,
          type: 'assistant/chunk/reasoning',
          text: reasoning,
          streaming: streaming,
        ),
      );
    }
    if (text.isNotEmpty) {
      nodes.add(
        ChatNodeAssistant(
          seq: m.lastSeq,
          type: 'assistant/chunk',
          text: text,
          streaming: streaming,
        ),
      );
    }
  });
  return nodes;
}

class _ChunkGroupMeta {
  _ChunkGroupMeta({required this.firstSeq, required this.lastSeq});
  int firstSeq;
  int lastSeq;
}

const Set<String> _settleTypes = {
  'turn/end',
  'step/end',
  'user/message',
  'llm/retry',
};

String? _stepKeyOf(dynamic data) {
  if (data is! Map) return null;
  final turn = data['turn'];
  final step = data['step'];
  if (turn is! num || step is! num) return null;
  return '$turn:${turn.toInt()}:$step:${step.toInt()}';
}

// ---------------------------------------------------------------------------
// tool/result 嵌套形状提取(真实日志:data.message.content[].tool-result)
// ---------------------------------------------------------------------------

String? _resultCallId(dynamic data) {
  if (data is! Map) return null;
  final message = data['message'];
  if (message is Map) {
    final source = message['source'];
    if (source is Map) {
      final id = source['callId'];
      if (id is String && id.isNotEmpty) return id;
    }
    final content = message['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map) {
          final id = block['toolCallId'];
          if (id is String && id.isNotEmpty) return id;
        }
      }
    }
  }
  return null;
}

String? _resultToolName(dynamic data) => null; // 结果事件不携带名称,由 call 侧补。

/// tool-result 内容文本:content[].content[] 的 text 块拼接。
String? _resultText(dynamic data) {
  if (data is! Map) return null;
  final message = data['message'];
  if (message is! Map) return null;
  final content = message['content'];
  if (content is! List) return null;
  final parts = <String>[];
  for (final block in content) {
    if (block is! Map || block['type'] != 'tool-result') continue;
    final inner = block['content'];
    if (inner is! List) continue;
    for (final piece in inner) {
      if (piece is Map && piece['type'] == 'text') {
        final t = piece['text'];
        if (t is String && t.isNotEmpty) parts.add(t);
      }
    }
  }
  return parts.isEmpty ? null : parts.join('\n');
}

bool _resultIsError(dynamic data) {
  if (data is! Map) return false;
  final message = data['message'];
  if (message is! Map) return false;
  final content = message['content'];
  if (content is! List) return false;
  for (final block in content) {
    if (block is Map && block['type'] == 'tool-result' && block['isError'] == true) {
      return true;
    }
  }
  return false;
}

/// JSON 字符串 → 结构(解析失败原样返回;数字/布尔等标量不受影响)。
dynamic _maybeDecodeJson(dynamic v) {
  if (v is! String) return v;
  final s = v.trim();
  if (s.isEmpty || (s.codeUnitAt(0) != 0x7B && s.codeUnitAt(0) != 0x5B)) return v;
  try {
    return const JsonDecoder().convert(s);
  } catch (_) {
    return v;
  }
}

/// 摘要种子:bash 类工具取 command,其余走整体格式化。
String? _summarySeed(String name, dynamic input) {
  if (input is Map) {
    final n = name.toLowerCase();
    final cmdKeys = const ['command', 'cmd', 'script'];
    for (final k in cmdKeys) {
      final v = input[k];
      if (v is String && v.isNotEmpty) return v;
    }
    if (n.contains('read') || n.contains('glob') || n.contains('grep')) {
      for (final k in const ['path', 'pattern', 'file_path', 'filePath']) {
        final v = input[k];
        if (v is String && v.isNotEmpty) return v;
      }
    }
  }
  return input;
}

/// 防御式图片引用提取:data.content[](或 data.images[])中 type=='image' 的块。
List<ImageAttachmentRef> _imageRefs(dynamic data) {
  if (data is! Map) return const [];
  final candidates = <dynamic>[
    if ((data['content'] as List?) != null) ...(data['content'] as List),
    if ((data['images'] as List?) != null) ...(data['images'] as List),
  ];
  final refs = <ImageAttachmentRef>[];
  for (final c in candidates) {
    if (c is! Map) continue;
    final isImage = c['type'] == 'image' || c['attachmentId'] is String;
    if (!isImage) continue;
    final attachmentId = c['attachmentId'];
    if (attachmentId is! String) continue;
    final mediaType = c['mediaType'];
    final bytes = c['bytes'];
    final width = c['width'];
    final height = c['height'];
    if (mediaType is! String ||
        bytes is! num ||
        width is! num ||
        height is! num) {
      continue;
    }
    refs.add(
      ImageAttachmentRef(
        attachmentId: attachmentId,
        mediaType: mediaType,
        bytes: bytes.toInt(),
        width: width.toInt(),
        height: height.toInt(),
        name: c['name'] is String ? c['name'] as String? : null,
      ),
    );
  }
  return refs;
}

List<ChatNode> _nodesFor(SessionEvent event) {
  final type = event.type;
  final data = event.data;
  if (type == 'user/message') {
    // 直发人类消息才冒泡;agent.inject 的合成上下文不进聊天流(对齐 chat_view_model)。
    if (_injected(data)) return const [];
    final text = extractText(data);
    final images = _imageRefs(data);
    if (text.isEmpty && images.isEmpty) return const [];
    return [
      ChatNodeUser(
        seq: event.seq,
        type: type,
        text: text,
        images: images.isEmpty ? null : images,
      ),
    ];
  }
  if (type == 'assistant/message') {
    final text = extractText(data);
    final think = _reasoningText(data);
    final images = _imageRefs(data);
    final nodes = <ChatNode>[];
    if (think != null && think.isNotEmpty) {
      nodes.add(
        ChatNodeThink(seq: event.seq, type: '$type/reasoning', text: think),
      );
    }
    if (text.isNotEmpty || images.isNotEmpty) {
      nodes.add(
        ChatNodeAssistant(
          seq: event.seq,
          type: type,
          text: text,
          images: images.isEmpty ? null : images,
        ),
      );
    }
    return nodes;
  }
  if (type == 'assistant/chunk') {
    // 无 data.chunk 的防御形状:按文本渲染为普通助手消息(合并由调用方处理)。
    final text = extractText(data);
    if (text.isEmpty) return const [];
    return [ChatNodeAssistant(seq: event.seq, type: type, text: text)];
  }
  if (type.startsWith('assistant/') &&
      (type.contains('reasoning') || type.contains('think'))) {
    final text = _eventText(data);
    if (text == null || text.isEmpty) return const [];
    return [ChatNodeThink(seq: event.seq, type: type, text: text)];
  }
  if (type == 'think' || type.startsWith('think/')) {
    final text = _eventText(data);
    if (text == null || text.isEmpty) return const [];
    return [ChatNodeThink(seq: event.seq, type: type, text: text)];
  }
  if (type.startsWith('todo')) {
    final items = _todoItems(data);
    if (items.isEmpty) return const [];
    return [ChatNodeTodo(seq: event.seq, type: type, items: items)];
  }
  if (type.startsWith('compaction')) {
    final kind = type.split('/').last;
    final summary = _pick(data, null, ['summary', 'text', 'message']);
    final messages = _intOf(data, ['messages', 'messageCount']);
    return [
      ChatNodeCompaction(
        seq: event.seq,
        type: type,
        kind: kind,
        summary: summary,
        messages: messages,
      ),
    ];
  }
  if (type == 'llm/retry' || type.startsWith('llm/retry')) {
    if (type == 'llm/retry-started') return const []; // 与 llm/retry 重复,只留一行。
    final reason = _retryReason(data);
    final attempt = _intOf(data, ['attempt', 'retryCount', 'retry']);
    final maxRetries = _intOf(data, ['maxRetries', 'max_retries']);
    return [
      ChatNodeRetry(
        seq: event.seq,
        type: type,
        reason: reason,
        attempt: attempt,
        maxRetries: maxRetries,
      ),
    ];
  }
  if (type == 'turn/error' || type.startsWith('turn/error')) {
    final message = _pick(data, null, ['message', 'error', 'text']) ?? type;
    return [ChatNodeError(seq: event.seq, type: type, message: message)];
  }
  final notice = _noticeFor(event);
  if (notice != null) return [notice];
  // 协议分隔符/内部管道事件不在主聊天流占位。
  if (_isInternalEvent(type)) return const [];
  // 真正未知的类型才走兜底,避免把已知协议事件伪装成未知数据。
  return [ChatNodeUnknown(seq: event.seq, type: type, data: data)];
}

/// llm/retry 失败原因:顶层 reason/message/error,或 failure.message(线上形状)。
String? _retryReason(dynamic data) {
  final direct = _pick(data, null, ['reason', 'message', 'error']);
  if (direct != null) return direct;
  if (data is Map) {
    final failure = data['failure'];
    if (failure is Map) {
      final m = failure['message'];
      if (m is String && m.isNotEmpty) return m;
    }
  }
  return null;
}

ChatNodeNotice? _noticeFor(SessionEvent event) {
  final type = event.type;
  final data = event.data;
  switch (type) {
    case 'permission/preset':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '权限预设已更新',
        detail: _pick(data, null, ['preset', 'name', 'value']),
        icon: 'shield',
      );
    case 'sandbox/mode':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '沙箱模式已更新',
        detail: _pick(data, null, ['mode', 'name', 'value']),
        icon: 'lock',
      );
    case 'approval/policy':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '审批策略已更新',
        detail: _pick(data, null, ['policy', 'name', 'value']),
        icon: 'approval',
      );
    case 'approval/asked':
      // 会话事件层的审批轨迹(mux approval/requested 负责交互卡)。
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '等待审批',
        detail: _approvalAskedDetail(data),
        icon: 'approval',
      );
    case 'approval/decided':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '审批已处理',
        detail: _approvalOutcome(data),
        icon: 'approval',
      );
    case 'agent-preset/selected':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: 'Agent 预设已切换',
        detail: _pick(data, null, ['preset', 'name', 'id', 'agentPreset']),
        icon: 'sparkle',
      );
    case 'command/run':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '正在执行命令',
        detail: _pick(data, null, ['name', 'command', 'input']),
        icon: 'terminal',
      );
    case 'command/done':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '命令执行完成',
        detail: _pick(data, null, ['name', 'command']),
        icon: 'check',
      );
    case 'agent/inbox/spliced':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '上下文已更新',
        detail: _splicedDetail(data),
        icon: 'inbox',
      );
    case 'goal/change':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '目标已更新',
        detail: _pick(data, null, ['title', 'goal', 'summary', 'text']),
        icon: 'target',
      );
    case 'plan/mode':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '计划模式已切换',
        detail: _pick(data, null, ['mode', 'name', 'value']),
        icon: 'plan',
      );
    case 'schedule/change':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '定时任务已更新',
        detail: _pick(data, null, ['name', 'scheduleId', 'summary']),
        icon: 'schedule',
      );
    case 'tool-workflow/run-start':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '工作流已启动',
        detail: _pick(data, null, ['name', 'workflowName', 'runId']),
        icon: 'workflow',
      );
    case 'tool-workflow/run-end':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '工作流已结束',
        detail: _pick(data, null, ['name', 'workflowName', 'runId']),
        icon: 'workflow',
      );
    case 'tool-workflow/agent-start':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '子代理已启动',
        detail: _pick(data, null, ['label', 'name', 'agentId']),
        icon: 'agents',
      );
    case 'tool-workflow/agent-end':
      return ChatNodeNotice(
        seq: event.seq,
        type: type,
        title: '子代理已结束',
        detail: _pick(data, null, ['label', 'name', 'agentId']),
        icon: 'agents',
      );
    default:
      return null;
  }
}

String? _approvalAskedDetail(dynamic data) {
  if (data is! Map) return null;
  final tool = _pick(data, null, ['toolName', 'name']);
  final reason = _pick(data, null, ['reason']);
  if (tool == null) return reason;
  if (reason == null) return tool;
  return '$tool · $reason';
}

String? _approvalOutcome(dynamic data) {
  if (data is! Map) return null;
  final outcome = data['outcome'];
  switch (outcome) {
    case 'allowed-once':
      return '已允许(仅此一次)';
    case 'allowed-always':
    case 'allowed':
      return '已允许';
    case 'rejected':
      return '已拒绝';
    case String s:
      return s;
    default:
      return null;
  }
}

String? _splicedDetail(dynamic data) {
  if (data is! Map) return null;
  final inserted = data['inserted'];
  final removed = data['removedCount'];
  final insertedCount = inserted is List ? inserted.length : null;
  if (insertedCount != null && removed is int) {
    return '注入 $insertedCount 条 · 移除 $removed 条';
  }
  if (insertedCount != null) return '注入 $insertedCount 条';
  if (removed is int) return '移除 $removed 条';
  return _pick(data, null, ['summary', 'message', 'text']);
}

/// 内部/管道事件(真实日志普查 + known-event-types 全集):
/// turn 与 step 边界、请求上下文、标题投影、子代理描述符、反馈落盘、
/// run_code 派发的 code-dispatch 子调用、钩子、检索类 LLM 请求。
bool _isInternalEvent(String type) =>
    type == 'turn/start' ||
    type == 'turn/end' ||
    type == 'step/start' ||
    type == 'step/end' ||
    type == 'session/queue' ||
    type == 'session/status' ||
    type == 'session/title' ||
    type == 'session/title-llm-request' ||
    type == 'session/end-seed' ||
    type == 'request/context' ||
    type == 'request/header' ||
    type == 'subagent/descriptor' ||
    type == 'feedback/record' ||
    type == 'tool/code-dispatch' ||
    type == 'tool/code-dispatch-start' ||
    type == 'hook/invoked' ||
    type == 'hook/result' ||
    type == 'web/deepseek-search-llm-request' ||
    type == 'connection/reset';

/// 合成上下文判定:source.kind 存在且非 'user' → 过滤。
bool _injected(dynamic data) {
  if (data is! Map) return false;
  final source = data['source'];
  if (source is Map) {
    final kind = source['kind'];
    return kind != null && kind != 'user';
  }
  return false;
}

/// 提取 assistant/message 中 reasoning 块的文本(拆成 think 节点)。
String? _reasoningText(dynamic data) {
  final parts = <String>[];
  for (final block in _contentOf(data)) {
    if (block is Map && block['type'] == 'reasoning') {
      final t = block['text'] ?? block['summary'] ?? block['content'];
      if (t is String && t.isNotEmpty) parts.add(t);
    }
  }
  return parts.isEmpty ? null : parts.join('\n');
}

List<dynamic> _contentOf(dynamic data) {
  if (data is! Map) return const [];
  var content = data['content'];
  if (content is! List) {
    final message = data['message'];
    if (message is Map) content = message['content'];
  }
  return content is List ? content : const [];
}

/// 独立 think 事件的文本(弹性键:text/summary/content)。
String? _eventText(dynamic data) {
  if (data is! Map) return null;
  for (final k in ['text', 'summary', 'content']) {
    final v = data[k];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

List<TodoItem> _todoItems(dynamic data) {
  if (data is! Map) return const [];
  final raw = data['items'] ?? data['todos'];
  if (raw is! List) return const [];
  final items = <TodoItem>[];
  for (final e in raw) {
    if (e is String && e.isNotEmpty) {
      items.add(TodoItem(title: e));
    } else if (e is Map) {
      // 线上形状:{content, status: pending|in_progress|completed}。
      final title = _firstString(e, ['title', 'text', 'content', 'id']) ?? '(无标题)';
      final status = _firstString(e, ['status', 'state']);
      final done =
          e['done'] == true ||
          e['completed'] == true ||
          status == 'done' ||
          status == 'completed';
      items.add(TodoItem(title: title, done: done));
    }
  }
  return items;
}

/// 错误文本:error 字段可能是字符串或 {message}。
String? _errorOf(dynamic data, Map<String, dynamic>? viewMap) {
  for (final src in <dynamic>[viewMap, data is Map ? data : null]) {
    if (src == null) continue;
    final e = src['error'];
    if (e is String && e.isNotEmpty) return e;
    if (e is Map) {
      final m = e['message'];
      if (m is String && m.isNotEmpty) return m;
    }
  }
  return null;
}

/// 状态判定:view 的 status/error/interrupted/ok 字段优先,否则 data 的 error。
ToolStatus _statusOf(Map<String, dynamic>? viewMap, String? error) {
  if (viewMap != null) {
    final s = viewMap['status'];
    if (s is String) {
      switch (s.toLowerCase()) {
        case 'running':
          return ToolStatus.running;
        case 'failed':
        case 'error':
          return ToolStatus.failed;
        case 'interrupted':
        case 'cancelled':
        case 'canceled':
        case 'stopped':
          return ToolStatus.interrupted;
        default:
          return ToolStatus.success;
      }
    }
    if (viewMap['error'] != null) return ToolStatus.failed;
    if (viewMap['interrupted'] == true) return ToolStatus.interrupted;
    if (viewMap['ok'] == false) return ToolStatus.failed;
  }
  return error != null ? ToolStatus.failed : ToolStatus.success;
}

/// 弹性取字符串:工具卡本质信息以 event.data 为准,view 仅兜底(渲染增强)。
String? _pick(dynamic data, Map<String, dynamic>? viewMap, List<String> keys) {
  if (data is Map) {
    for (final k in keys) {
      final v = data[k];
      if (v is String && v.isNotEmpty) return v;
    }
  }
  for (final k in keys) {
    final v = viewMap?[k];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

/// 弹性取值:同上,data 优先、view 兜底。
dynamic _pickValue(
  dynamic data,
  Map<String, dynamic>? viewMap,
  List<String> keys,
) {
  if (data is Map) {
    for (final k in keys) {
      final v = data[k];
      if (v != null) return v;
    }
  }
  for (final k in keys) {
    final v = viewMap?[k];
    if (v != null) return v;
  }
  return null;
}

String? _pickString(Map<String, dynamic>? map, List<String> keys) {
  if (map == null) return null;
  for (final k in keys) {
    final v = map[k];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

/// 从任意 Map(含 Map[dynamic, dynamic])取首个非空字符串字段。
String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
  for (final k in keys) {
    final v = map[k];
    if (v is String && v.isNotEmpty) return v;
  }
  return null;
}

int? _intOf(dynamic data, List<String> keys) {
  if (data is! Map) return null;
  for (final k in keys) {
    final v = data[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
  }
  return null;
}

/// 摘要预览(截断防爆行)。
String? _preview(dynamic value, int max) {
  if (value == null) return null;
  final s = _format(value);
  if (s.length <= max) return s;
  return '${s.substring(0, max)}…';
}

/// 值 → 可读文本(Map/List 走缩进 JSON,标量直出)。
String _format(dynamic value) {
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}
