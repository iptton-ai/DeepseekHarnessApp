// session/event → 会话流节点提取(纯 Dart;不 import flutter)。
//
// 职责(DSH-PROTOCOL §4 + audit/conversation):把原始事件日志升级为
// web 同款节点流 —— 用户气泡 / 助手消息(markdown)/ think 折叠块 /
// 工具卡(call+result 经 ToolEventView 配对)/ todo 计划快照 /
// 压缩检查点 / 重试行 / 错误行 / 未知类型兜底。
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
// 已知限制:若 event.data 缺工具名/参数(线上形状未覆盖),工具名退化为
// 'tool'、摘要缺省为空;届时需扩展 SessionLog 保存 view 后由集成方补全。
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
  const ChatNodeUser({required super.seq, required super.type, required this.text});
  final String text;
}

/// 助手消息(markdown 文本,UI 用 MarkdownWidget 渲染)。
class ChatNodeAssistant extends ChatNode {
  const ChatNodeAssistant({required super.seq, required super.type, required this.text});
  final String text;
}

/// think 折叠块(默认收起,点开显示全文)。
class ChatNodeThink extends ChatNode {
  const ChatNodeThink({required super.seq, required super.type, required this.text});
  final String text;
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
  const ChatNodeTodo({required super.seq, required super.type, required this.items});
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

/// 压缩检查点(compaction/start|end|summary)。
class ChatNodeCompaction extends ChatNode {
  const ChatNodeCompaction({
    required super.seq,
    required super.type,
    required this.kind,
    this.summary,
    this.messages,
  });
  final String kind; // start | end | summary
  final String? summary;
  final int? messages;
}

/// llm/retry 重试行(内联细行)。
class ChatNodeRetry extends ChatNode {
  const ChatNodeRetry({required super.seq, required super.type, this.reason, this.attempt});
  final String? reason;
  final int? attempt;
}

/// turn/error 错误行。
class ChatNodeError extends ChatNode {
  const ChatNodeError({required super.seq, required super.type, required this.message});
  final String message;
}

/// 未知类型兜底(类型名 + 原始 data 折叠展示)。
class ChatNodeUnknown extends ChatNode {
  const ChatNodeUnknown({required super.seq, required super.type, required this.data});
  final dynamic data;
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
        result[p.index] = _mergeCallResult(result[p.index] as ChatNodeTool, node);
      } else {
        result.add(node); // 无配对结果的独立卡(按 view 判定状态)。
      }
    } else {
      result.addAll(_nodesFor(event));
    }
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
  final name = _pick(event.data, viewMap, ['toolName', 'name', 'tool', 'tool_name']) ?? 'tool';
  final callId = _pick(event.data, viewMap, ['callId', 'call_id', 'id']);
  final input = _pickValue(event.data, viewMap, ['input', 'args', 'arguments']);
  final summary = _pickString(viewMap, ['summary', 'title', 'label']) ?? _preview(input, 60);
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
  final name = _pick(event.data, viewMap, ['toolName', 'name', 'tool', 'tool_name']) ?? 'tool';
  final callId = _pick(event.data, viewMap, ['callId', 'call_id', 'id']);
  final output = _pickValue(event.data, viewMap, ['output', 'result', 'value', 'data']);
  final error = _errorOf(event.data, viewMap);
  final status = _statusOf(viewMap, error);
  final summary = _pickString(viewMap, ['summary', 'title', 'label']) ?? _preview(output ?? error, 60);
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
ChatNodeTool _mergeCallResult(ChatNodeTool call, ChatNodeTool result) => ChatNodeTool(
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

/// 非工具事件 → 按类型词表分派;未覆盖的走未知兜底。
List<ChatNode> _nodesFor(SessionEvent event) {
  final type = event.type;
  final data = event.data;
  if (type == 'user/message') {
    // 直发人类消息才冒泡;agent.inject 的合成上下文不进聊天流(对齐 chat_view_model)。
    if (_injected(data)) return const [];
    final text = extractText(data);
    if (text.isEmpty) return const [];
    return [ChatNodeUser(seq: event.seq, type: type, text: text)];
  }
  if (type == 'assistant/message') {
    final text = extractText(data);
    final think = _reasoningText(data);
    final nodes = <ChatNode>[];
    if (think != null && think.isNotEmpty) {
      nodes.add(ChatNodeThink(seq: event.seq, type: '$type/reasoning', text: think));
    }
    if (text.isNotEmpty) {
      nodes.add(ChatNodeAssistant(seq: event.seq, type: type, text: text));
    }
    return nodes;
  }
  if (type == 'assistant/chunk') {
    // 流式块(若线上存在):每块按文本渲染,合并交给集成方(VM)做。
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
      ChatNodeCompaction(seq: event.seq, type: type, kind: kind, summary: summary, messages: messages),
    ];
  }
  if (type == 'llm/retry' || type.startsWith('llm/retry')) {
    final reason = _pick(data, null, ['reason', 'message', 'error']);
    final attempt = _intOf(data, ['attempt', 'retryCount']);
    return [ChatNodeRetry(seq: event.seq, type: type, reason: reason, attempt: attempt)];
  }
  if (type == 'turn/error' || type.startsWith('turn/error')) {
    final message = _pick(data, null, ['message', 'error', 'text']) ?? type;
    return [ChatNodeError(seq: event.seq, type: type, message: message)];
  }
  // 兜底:未知类型按类型名 + 原始 data 折叠展示。
  return [ChatNodeUnknown(seq: event.seq, type: type, data: data)];
}

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
      final title = _firstString(e, ['title', 'text', 'id']) ?? '(无标题)';
      final status = _firstString(e, ['status', 'state']);
      final done = e['done'] == true ||
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
dynamic _pickValue(dynamic data, Map<String, dynamic>? viewMap, List<String> keys) {
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
