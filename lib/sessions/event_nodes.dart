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
// - 中断/异常落点(0.1.0-rc.6 权威形状):
//   * 取消轮次:宿主对未派发调用补写合成 tool/result,data.error =
//     {name:'AbortError', code:'ABORTED_BEFORE_DISPATCH'};已派发被中断的
//     code='ABORTED';崩溃修复(重载后补)是 TOOL_OUTCOME_UNKNOWN /
//     TOOL_NOT_STARTED。这些 code → ToolStatus.interrupted(琥珀「中断」),
//     与 web 的 block.error?.code === 'interrupted' 客户端合成语义对齐
//   * turn/end 携带 data.reason(dsh-session TurnEndReasonMap):
//     completed | aborted(user/parent/hook/disposed)| blocked |
//     error(结构化 LlmFailure)| max-tokens | interrupted(崩溃孤儿)。
//     reason≠completed/blocked 产出提示节点(error → ChatNodeError,
//     其余 → ChatNodeNotice)
//   * step/end、turn/end 闭合时仍未配到结果的运行卡结算为 interrupted
//     (web interruption() 同款规则:所在 step/turn 已关闭 ⇒ 未结算调用
//     视为中断)——消灭「中断后永远转圈」
//   * view(dsh-tools presentation 词表)只有 card/title/output 等
//     渲染字段,不含 status/interrupted/ok —— 状态判定以 event.data 为准
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

/// 会话流节点(sealed)。每个节点携带来源事件的 seq 与原始类型名,
/// 以及来源事件的宿主时间戳(A2 时间基线;epoch ms,可空防御)。
sealed class ChatNode {
  const ChatNode({required this.seq, required this.type, this.time});
  final int seq;
  final String type;

  /// 来源事件 SessionEvent.time(epoch ms;历史旧档/合成节点可能缺失)。
  final double? time;
}

/// 用户气泡(右对齐)。[steering] = 运行中被接纳的插话(A6:web
/// SteeringMessageNode 同款语义,经 next-step inbox claimed 折叠判定),
/// UI 以「插话」标记区分普通用户消息。
class ChatNodeUser extends ChatNode {
  const ChatNodeUser({
    required super.seq,
    required super.type,
    required this.text,
    this.images,
    this.steering = false,
    super.time,
  });
  final String text;

  /// 是否为运行中被接纳的插话(web: admitted steering)。
  final bool steering;

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
    super.time,
    this.runMs,
    this.ttftMs,
    this.tokensPerSecond,
  });
  final String text;
  final List<ImageAttachmentRef>? images;
  final bool streaming;

  /// 轮级耗时指标(web turn-tail → MessageIconActions「Ran for/TTFT/tok-s」
  /// 的等价物;挂在轮末最后一条定稿助手消息上,仅完成轮有值)。
  final double? runMs;
  final double? ttftMs;
  final double? tokensPerSecond;
}

/// think 折叠块(默认收起,点开显示全文;streaming 时 UI 在标题行滚动
/// 显示最后一行,不自动展开)。
class ChatNodeThink extends ChatNode {
  const ChatNodeThink({
    required super.seq,
    required super.type,
    required this.text,
    this.streaming = false,
    super.time,
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
    super.time,
    this.callTime,
    this.resultTime,
    this.producedPaths = const <String>[],
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

  /// call 事件时间(epoch ms;A4 工具耗时 = resultTime-callTime)。
  final double? callTime;

  /// result 事件时间(未结算为 null;运行中卡的实时耗时由 UI 用 now 补)。
  final double? resultTime;

  /// 本调用产出/修改的文件路径(web ui-deliverables 语义:call view 的
  /// locations,card=diff 或 generic+kind=edit;实时帧有 view 才非空)。
  final List<String> producedPaths;
}

/// todo/write 计划快照(紧凑状态计数卡)。
class ChatNodeTodo extends ChatNode {
  const ChatNodeTodo({
    required super.seq,
    required super.type,
    required this.items,
    super.time,
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
    super.time,
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
    super.time,
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
    super.time,
  });
  final String message;
}

/// 未知类型兜底(类型名 + 原始 data 折叠展示)。
class ChatNodeUnknown extends ChatNode {
  const ChatNodeUnknown({
    required super.seq,
    required super.type,
    required this.data,
    super.time,
  });
  final dynamic data;
}

/// 注入上下文行(A5:web ContextInjectionRow 对齐)。source.kind != 'user'
/// 的 user/message 不再一刀切过滤 —— 以左侧低调折叠行交代注入痕迹,
/// 头部 = 角色词 + 生产者标签,展开显示内容正文。
class ChatNodeContextRow extends ChatNode {
  const ChatNodeContextRow({
    required super.seq,
    required super.type,
    required this.provenanceLabel,
    this.recall = false,
    this.summary,
    this.text,
    super.time,
  });

  /// 生产者标签(web contextProvenance:agent-instructions 取 changes[].path、
  /// plugin 取 plugin id、skill-invocation 取 name、session-reference 取
  /// references[].label,其余回退 source.kind)。
  final String? provenanceLabel;

  /// 是否为跨会话召回(web role='recall':「上下文召回」而非「上下文注入」)。
  final bool recall;

  /// 折叠行摘要(仅 notice form 携带 source.summary)。
  final String? summary;

  /// 内容正文(text 块拼接;展开显示)。
  final String? text;
}

/// 斜杠命令卡(B1 换形式:command/run+done 聚合成单卡,web CommandNode)。
class ChatNodeCommand extends ChatNode {
  const ChatNodeCommand({
    required super.seq,
    required super.type,
    required this.name,
    this.args,
    this.outcomeKind,
    this.outcomeText,
    this.done = false,
    super.time,
  });
  final String? name;
  final String? args;

  /// 终态(command/done.data.kind):success | error | …;null = 运行中。
  final String? outcomeKind;

  /// 终态文本(command/done.data.text,如导出落盘路径)。
  final String? outcomeText;
  final bool done;
}

/// workflow 运行卡(A7:tool-workflow 四事件按 runId 聚合,web workflow-run)。
class ChatNodeWorkflowRun extends ChatNode {
  const ChatNodeWorkflowRun({
    required super.seq,
    required super.type,
    required this.runId,
    required this.name,
    required this.status,
    required this.phases,
    super.time,
  });
  final String runId;
  final String name;

  /// running | completed | failed | cancelled | interrupted。
  final String status;

  /// 阶段分组(保持 agent-start 顺序;phase 缺席归「默认」组)。
  final List<WorkflowPhase> phases;
}

class WorkflowPhase {
  const WorkflowPhase({required this.key, required this.phase, required this.members});

  /// web workflowPhaseKey:phase 为 null 时 'missing',否则 'value:len:phase'。
  final String key;

  /// 声明的阶段名(null = 未声明)。
  final String? phase;
  final List<WorkflowMember> members;
}

class WorkflowMember {
  const WorkflowMember({
    required this.seq,
    required this.label,
    required this.childId,
    required this.status,
  });
  final int seq;
  final String label;

  /// 子会话 id(点击打开 transcript 用)。
  final String childId;

  /// running | completed | failed | cancelled | interrupted。
  final String status;
}

/// 轮末产出文件行数据(A1:ProducedFilesRow 的数据节点)。
class ChatNodeDeliverables extends ChatNode {
  const ChatNodeDeliverables({
    required super.seq,
    required super.type,
    required this.paths,
    super.time,
  });

  /// 本轮产出/修改文件(首见序去重;web producedForClosing 同款)。
  final List<String> paths;
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
    super.time,
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
  // A6 steering 判定:next-step inbox 折叠(web inbox.ts applySplice 同款)。
  final inbox = _NextStepInboxState();
  // A2 轮级指标(turn-tail:runMs/ttftMs/tok-s),轮末回填到最后一条定稿
  // 助手消息(web MessageIconActions「Ran for/TTFT/tok-s」对齐)。
  final turnMetrics = _TurnMetrics();
  // A1 轮末产出:本轮成功修改调用累计的 locations 路径(首见去重)。
  var turnProduced = <String>[];
  // B1 命令卡:command/run 的卡位(run+done 按 commandId 配对)。
  final commandByRun = <String, _CommandSlot>{};
  // A7 workflow 聚合:runId → 状态(run-start 锚定卡位,成员事件更新)。
  final workflows = <String, _WorkflowState>{};
  for (final input in sorted) {
    final event = input.event;
    final view = input.view;
    if (event.type == 'assistant/chunk' && _chunkOf(event.data) != null) {
      continue; // 折叠态由 _foldChunks 统一产出。
    }
    // A7:workflow 家族聚合成单卡,不再各发一条 notice(B1)。
    if (_workflowEventOf(event) case final wf?) {
      final st = workflows.putIfAbsent(
        wf.runId,
        () => _WorkflowState(
          runId: wf.runId,
          anchorSeq: event.seq,
          time: event.time,
        ),
      );
      st.apply(event, wf);
      continue;
    }
    // A1:修改类调用的产出路径在轮边界结转(仅成功结果计入)。
    if (event.type == 'turn/end') {
      // A2 轮末回填:最后一条定稿助手消息带走本轮耗时指标。
      turnMetrics.attachTo(result);
      if (turnProduced.isNotEmpty) {
        result.add(
          ChatNodeDeliverables(
            seq: event.seq,
            type: 'turn/deliverables',
            paths: turnProduced,
            time: event.time,
          ),
        );
        turnProduced = <String>[];
      }
    }
    // A2 轮内记账:边界/首帧/定稿/用量喂给 turnMetrics。
    turnMetrics.observe(event);
    final kind = _toolKind(event, view);
    if (kind == _ToolKind.call) {
      final node = _buildToolCall(event, view);
      pending.add(
        _PendingCall(
          result.length,
          node.callId,
          turn: _intOf(event.data, ['turn']),
          step: _intOf(event.data, ['step']),
        ),
      );
      result.add(node);
    } else if (kind == _ToolKind.result) {
      final node = _buildToolResult(event, view);
      final idx = _matchPending(pending, node.callId);
      if (idx >= 0) {
        final p = pending.removeAt(idx);
        final merged = _mergeCallResult(
          result[p.index] as ChatNodeTool,
          node,
        );
        result[p.index] = merged;
        // web producedPaths:只有成功结算的修改意图才计入产出。
        if (merged.status == ToolStatus.success &&
            merged.producedPaths.isNotEmpty) {
          for (final pth in merged.producedPaths) {
            if (!turnProduced.contains(pth)) turnProduced.add(pth);
          }
        }
      } else {
        result.add(node); // 无配对结果的独立卡(按 view 判定状态)。
      }
    } else {
      // step/turn 闭合:范围内仍无结果的运行卡结算为中断(web interruption()
      // 同款规则 —— 宿主在关闭前必已提交结果,关闭时仍缺 = 永不再来)。
      if (event.type == 'step/end') {
        final t = _intOf(event.data, ['turn']);
        final s = _intOf(event.data, ['step']);
        // 字段齐全才做精确匹配;缺字段的 step 边界不结算(留给 turn 边界兜底)。
        if (t != null && s != null) {
          _settlePending(pending, result, turn: t, step: s, seq: event.seq);
        }
      } else if (event.type == 'turn/end') {
        // turn 边界落定一切:seq 序保证此前事件属于已闭合范围
        //(call 缺 turn 字段的防御形状也只能靠这里兜住)。
        _settlePending(pending, result, seq: event.seq);
      }
      // A6:next-step inbox 折叠先于 user/message 判定(seq 序保证 splice
      // 已在消息落位前发生 —— 与 web reader.previous 语义一致)。
      if (event.type == 'agent/inbox/spliced') {
        inbox.applySplice(event.data);
        continue; // B1:web publication:'none',时间线无行。
      }
      // B1:命令卡配对(run 锚卡,done 回填终态)。
      if (event.type == 'command/run' || event.type == 'command/done') {
        final id = _commandIdOf(event.data);
        if (id != null) {
          final slot = commandByRun[id];
          if (slot == null) {
            // 首见(run,或孤立 done):锚定本事件 seq 占卡。
            final node = _commandNodeFrom(event);
            commandByRun[id] = _CommandSlot(result.length, node);
            result.add(node);
          } else if (event.type == 'command/done') {
            // done 原位回填终态(卡位/seq 保持 run 侧)。
            final updated = _commandNodeUpdated(slot.node, event);
            result[slot.index] = updated;
            slot.node = updated;
          }
        }
        continue;
      }
      result.addAll(_nodesFor(event, inbox));
    }
  }
  // 流式折叠节点(无定稿 message 的 chunk 游)按 seq 归位插入。
  final folded = _foldChunks(sorted);
  if (folded.isNotEmpty) {
    result.addAll(folded);
  }
  // A7:workflow 聚合卡按锚定 seq(run-start)归位。
  for (final st in workflows.values) {
    final node = st.toNode();
    if (node != null) result.add(node);
  }
  if (folded.isNotEmpty || workflows.isNotEmpty) {
    result.sort((a, b) => a.seq.compareTo(b.seq));
  }
  return result;
}

enum _ToolKind { none, call, result }

// ---------------------------------------------------------------------------
// A2 轮级耗时指标(web turn-tail + assistantStepReading 的 Dart 等价)
// ---------------------------------------------------------------------------

/// 单轮指标:runMs(turn/start→turn/end)、ttftMs(首个文本 chunk)、
/// decode tok/s(usage outputTokens / 首 chunk→定稿)。轮末 attach 到
/// 该轮最后一条定稿 ChatNodeAssistant。
class _TurnMetrics {
  double? _turnStart;
  double? _firstChunk;
  int? _lastAssistantSeq;
  int _outputTokens = 0;

  /// 喂入非工具事件(边界/chunk/定稿/用量)。
  void observe(SessionEvent event) {
    switch (event.type) {
      case 'turn/start':
        _reset(event.time);
      case 'turn/end':
        _turnStart = _turnStart; // 结算在 attachTo;防御占位。
      case 'assistant/chunk':
        final chunk = event.data is Map ? (event.data as Map)['chunk'] : null;
        final hasText = chunk is Map &&
            ((chunk['type'] == 'text-delta' &&
                    chunk['text'] is String &&
                    (chunk['text'] as String).trim().isNotEmpty) ||
                chunk['type'] == 'block-end');
        if (hasText && _firstChunk == null) {
          _firstChunk = event.time;
        }
      case 'assistant/message':
        if (event.data is Map &&
            (event.data as Map)['message'] is Map &&
            ((event.data as Map)['message'] as Map)['content'] is List &&
            (((event.data as Map)['message'] as Map)['content'] as List)
                .isNotEmpty) {
          _lastAssistantSeq = event.seq;
        }
        final usage = event.data is Map
            ? (event.data as Map)['usage']
            : null;
        if (usage is Map && usage['outputTokens'] is num) {
          _outputTokens += (usage['outputTokens'] as num).toInt();
        }
      default:
        break;
    }
  }

  void _reset(double time) {
    _turnStart = time;
    _firstChunk = null;
    _lastAssistantSeq = null;
    _outputTokens = 0;
  }

  /// turn/end:把 runMs/ttftMs/tok-s 回填到最后一条定稿助手消息。
  void attachTo(List<ChatNode> result) {
    final start = _turnStart;
    final seq = _lastAssistantSeq;
    if (start == null || seq == null) {
      _reset(start ?? 0);
      return;
    }
    for (var i = result.length - 1; i >= 0; i--) {
      final n = result[i];
      if (n is ChatNodeAssistant && !n.streaming && n.seq == seq) {
        final end = n.time ?? start;
        final runMs = (end - start).clamp(0.0, double.infinity);
        final Double1 = _firstChunk;
        final ttft = Double1 == null
            ? null
            : (Double1 - start).clamp(0.0, double.infinity);
        final tps = (Double1 != null && _outputTokens > 0)
            ? _outputTokens /
                  ((end - Double1).clamp(1.0, double.infinity) / 1000)
            : null;
        result[i] = ChatNodeAssistant(
          seq: n.seq,
          type: n.type,
          text: n.text,
          images: n.images,
          streaming: n.streaming,
          time: n.time,
          runMs: runMs,
          ttftMs: ttft,
          tokensPerSecond: tps,
        );
        break;
      }
    }
    _reset(start);
  }
}

// ---------------------------------------------------------------------------
// A6 steering 判定:next-step inbox 折叠(web ui-conversation inbox.ts 同款)
// ---------------------------------------------------------------------------

class _NextStepInboxState {
  final List<String> _pending = <String>[];
  final Set<String> _claimed = <String>{};

  /// web applySplice:target=next-step 且非 canceled 时,被移除项记 claimed
  ///(= 已被运行中步骤接纳,对应落位的 user/message 是 steering)。
  void applySplice(dynamic data) {
    if (data is! Map) return;
    if (data['target'] != 'next-step') return;
    final start = data['start'];
    final removedCount = data['removedCount'];
    final inserted = data['inserted'];
    final s = start is int ? start : (start is num ? start.toInt() : 0);
    final rc = removedCount is int
        ? removedCount
        : (removedCount is num ? removedCount.toInt() : 0);
    final ids = <String>[
      if (inserted is List)
        for (final e in inserted)
          if (e is Map && e['id'] is String) e['id'] as String,
    ];
    final clamped = s.clamp(0, _pending.length);
    final removed = _pending.splice(clamped, rc, ids);
    for (final id in ids) {
      _claimed.remove(id);
    }
    if (data['outcome'] != 'canceled') {
      _claimed.addAll(removed);
    }
  }

  bool isClaimed(String? id) => id != null && _claimed.contains(id);
}

extension _Splice<T> on List<T> {
  /// JS Array.splice 的 Dart 版:移除 [count] 项并插入 [items],返回移除项。
  List<T> splice(int start, int count, List<T> items) {
    final removed = sublist(start, (start + count).clamp(start, length));
    removeRange(start, (start + count).clamp(start, length));
    insertAll(start, items);
    return removed;
  }
}

// ---------------------------------------------------------------------------
// B1+A7 命令卡 / workflow 聚合辅助
// ---------------------------------------------------------------------------

class _CommandSlot {
  _CommandSlot(this.index, this.node);
  final int index;
  ChatNodeCommand node;
}

String? _commandIdOf(dynamic data) =>
    data is Map && data['commandId'] is String ? data['commandId'] as String? : null;

ChatNodeCommand _commandNodeFrom(SessionEvent event) {
  final data = event.data;
  return ChatNodeCommand(
    seq: event.seq,
    type: event.type,
    name: data is Map && data['name'] is String ? data['name'] as String? : null,
    args: data is Map && data['args'] is String ? data['args'] as String? : null,
    time: event.time,
  );
}

ChatNodeCommand _commandNodeUpdated(ChatNodeCommand node, SessionEvent done) {
  final data = done.data;
  return ChatNodeCommand(
    seq: node.seq,
    type: node.type,
    name: node.name,
    args: node.args,
    outcomeKind: data is Map && data['kind'] is String ? data['kind'] as String? : null,
    outcomeText: data is Map && data['text'] is String ? data['text'] as String? : null,
    done: true,
    time: node.time,
  );
}

/// workflow 家族事件的 runId 提取(非 workflow 事件返回 null)。
String? _workflowRunIdOf(String type, dynamic data) {
  switch (type) {
    case 'tool-workflow/run-start':
    case 'tool-workflow/run-end':
    case 'tool-workflow/agent-start':
    case 'tool-workflow/agent-end':
      return data is Map && data['runId'] is String ? data['runId'] as String? : null;
    default:
      return null;
  }
}

class _WorkflowEventData {
  const _WorkflowEventData(this.runId);
  final String runId;
}

_WorkflowEventData? _workflowEventOf(SessionEvent event) {
  final runId = _workflowRunIdOf(event.type, event.data);
  return runId == null ? null : _WorkflowEventData(runId);
}

class _WorkflowMemberState {
  _WorkflowMemberState(this.seq, this.label, this.childId, this.phase);
  final int seq;
  final String label;
  final String childId;
  final String? phase;
  String? outcome;
}

class _WorkflowState {
  _WorkflowState({required this.runId, required this.anchorSeq, this.time});
  final String runId;
  final int anchorSeq;
  final double? time;
  String name = '';
  String? stopReason;
  final List<_WorkflowMemberState> members = [];

  void apply(SessionEvent event, _WorkflowEventData wf) {
    final data = event.data;
    switch (event.type) {
      case 'tool-workflow/run-start':
        if (data is Map && data['name'] is String) {
          name = data['name'] as String;
        }
      case 'tool-workflow/agent-start':
        if (data is Map) {
          final label =
              data['label'] is String ? data['label'] as String : '成员';
          final childId =
              data['childId'] is String ? data['childId'] as String : '';
          members.add(
            _WorkflowMemberState(
              data['seq'] is int ? data['seq'] as int : members.length,
              label,
              childId,
              data['phase'] is String ? data['phase'] as String? : null,
            ),
          );
        }
      case 'tool-workflow/agent-end':
        if (data is Map) {
          final seq = data['seq'];
          final outcome = data['outcome'];
          for (final m in members) {
            if (seq is int && m.seq == seq) {
              m.outcome = outcome is String ? outcome : m.outcome;
            }
          }
        }
      case 'tool-workflow/run-end':
        if (data is Map && data['stopReason'] is String) {
          stopReason = data['stopReason'] as String?;
        }
    }
  }

  ChatNodeWorkflowRun? toNode() {
    if (name.isEmpty && members.isEmpty) return null;
    final status = switch (stopReason) {
      'completed' => 'completed',
      'cancelled' => 'cancelled',
      'error' => 'failed',
      null => 'running',
      _ => 'interrupted',
    };
    final phases = <WorkflowPhase>[];
    for (final m in members) {
      final key = m.phase == null ? 'missing' : 'value:${m.phase!.length}:${m.phase}';
      var group = phases.where((p) => p.key == key).firstOrNull;
      if (group == null) {
        group = WorkflowPhase(key: key, phase: m.phase, members: []);
        phases.add(group);
      }
      group.members.add(
        WorkflowMember(
          seq: m.seq,
          label: m.label,
          childId: m.childId,
          status: _memberStatus(m, status),
        ),
      );
    }
    return ChatNodeWorkflowRun(
      seq: anchorSeq,
      type: 'tool-workflow/run',
      runId: runId,
      name: name,
      status: status,
      phases: phases,
      time: time,
    );
  }

  String _memberStatus(_WorkflowMemberState m, String runStatus) {
    switch (m.outcome) {
      case 'completed':
        return 'completed';
      case 'cancelled':
        return 'cancelled';
      case 'failed':
        return 'failed';
      case null:
        return runStatus == 'running' ? 'running' : 'interrupted';
      default:
        return 'interrupted';
    }
  }
}

/// 工具事件判定:优先信 view(主机渲染意图),其次按类型名猜测。
/// code-dispatch 是 run_code 的内部派发子调用(父卡已汇总输出),不算工具卡。
_ToolKind _toolKind(SessionEvent event, ToolEventView? view) {
  if (event.type == 'tool/code-dispatch' ||
      event.type == 'tool/code-dispatch-start') {
    return _ToolKind.none;
  }
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
  const _PendingCall(this.index, this.callId, {this.turn, this.step});
  final int index;
  final String? callId;

  /// call 所属 (turn, step)(dsh appendToolCall 必写;防御性可空)。
  final int? turn;
  final int? step;
}

/// 闭合结算:turn/step 均给定时只精确命中同范围的调用,均缺省时结算全部
/// (turn 边界语义)。倒序遍历安全移除;卡的 seq 保持 call 位(key 稳定)。
void _settlePending(
  List<_PendingCall> pending,
  List<ChatNode> result, {
  int? turn,
  int? step,
  required int seq,
}) {
  if (pending.isEmpty) return;
  final precise = turn != null && step != null;
  for (var i = pending.length - 1; i >= 0; i--) {
    final p = pending[i];
    if (precise && (p.turn != turn || p.step != step)) continue;
    pending.removeAt(i);
    result[p.index] = _interruptedCall(result[p.index] as ChatNodeTool, seq);
  }
}

/// 运行卡 → 中断卡(闭合时无结果):状态与 resultSeq 取结算事件,
/// 输出/错误不合成文本 —— 中断原因由紧随的轮次级提示节点交代。
ChatNodeTool _interruptedCall(ChatNodeTool call, int seq) => ChatNodeTool(
      seq: call.seq,
      type: call.type,
      toolName: call.toolName,
      callId: call.callId,
      input: call.input,
      summary: call.summary,
      status: ToolStatus.interrupted,
      callSeq: call.callSeq ?? call.seq,
      resultSeq: seq,
      time: call.time,
      callTime: call.callTime ?? call.time,
      resultTime: call.resultTime,
      producedPaths: call.producedPaths,
    );

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
    time: event.time,
    callTime: event.time,
    producedPaths: _producedPathsOfView(viewMap),
  );
}

/// A1(web producedPaths):call view 的渲染意图 —— card='diff' 或
/// card='generic' 且 kind='edit' 时,locations[].path 即产出文件。
List<String> _producedPathsOfView(Map<String, dynamic>? viewMap) {
  if (viewMap == null) return const <String>[];
  final card = viewMap['card'];
  final isMutation = card == 'diff' ||
      (card == 'generic' && viewMap['kind'] == 'edit');
  if (!isMutation) return const <String>[];
  final locations = viewMap['locations'];
  if (locations is! List) return const <String>[];
  final paths = <String>[];
  for (final l in locations) {
    if (l is Map && l['path'] is String) {
      final p = l['path'] as String?;
      if (p != null && p.isNotEmpty) paths.add(p);
    }
  }
  return paths;
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
  final code = _errorCodeOf(event.data, viewMap);
  // error 文本:message 优先;isError 的输出提升仅限非中断结果(中断卡
  // 不显示红错误框,输出文本原样留在输出区 —— 对齐 web stopped 语义)。
  final error = _errorOf(event.data, viewMap) ??
      (isError &&
              !_isInterruptCode(code) &&
              output is String &&
              output.isNotEmpty
          ? output
          : null);
  final status = _statusOf(code, error);
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
    time: event.time,
    resultTime: event.time,
  );
}

/// 合并配对:卡出现在 call 位置(seq=call),状态与输出取结果侧;
/// 摘要优先保留 call 侧(命令/参数预览比输出首行更稳定可读)。
ChatNodeTool _mergeCallResult(ChatNodeTool call, ChatNodeTool result) =>
    ChatNodeTool(
      seq: call.seq,
      type: call.type,
      toolName: result.toolName != 'tool' ? result.toolName : call.toolName,
      callId: call.callId ?? result.callId,
      input: call.input,
      output: result.output,
      error: result.error,
      summary: call.summary ?? result.summary,
      status: result.status,
      callSeq: call.callSeq ?? call.seq,
      resultSeq: result.resultSeq ?? result.seq,
      time: call.time,
      callTime: call.callTime ?? call.time,
      resultTime: result.resultTime,
      producedPaths: call.producedPaths,
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
      final meta0 = meta.putIfAbsent(
        key,
        () => _ChunkGroupMeta(firstSeq: event.seq, lastSeq: event.seq),
      );
      meta0.lastSeq = event.seq;
      meta0.time ??= event.time;
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
    // seq 用 firstSeq(块首事件):流式期间每个 delta 都会把 lastSeq 推高,
    // 若节点 seq 跟着变,列表 ValueKey 每 66ms 一换 → item State 全量销毁
    // 重建(think 展开态丢失、尾随滚动动画每帧重置、TextPainter 缓存
    // 失效)——这正是「生成中无法保持展开」与流式滚动卡顿的根因之一。
    // firstSeq 在块生命周期内不变,排序仍单调(组按首次出现序创建)。
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
          seq: m.firstSeq,
          type: 'assistant/chunk/reasoning',
          text: reasoning,
          streaming: streaming,
          time: m.time,
        ),
      );
    }
    if (text.isNotEmpty) {
      nodes.add(
        ChatNodeAssistant(
          seq: m.firstSeq,
          type: 'assistant/chunk',
          text: text,
          streaming: streaming,
          time: m.time,
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
  double? time;
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

/// 摘要种子:bash 类工具取 command、read 类取 path,其余**原样交给
/// _preview 格式化**(Map/List 走缩进 JSON)—— 返回类型必须是 dynamic:
/// 声明 String? 时 Map 兜底分支会发生运行时隐式下转崩溃
/// (type '_Map<String, dynamic>' is not a subtype of 'String?')。
dynamic _summarySeed(String name, dynamic input) {
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

List<ChatNode> _nodesFor(SessionEvent event, _NextStepInboxState inbox) {
  final type = event.type;
  final data = event.data;
  if (type == 'user/message') {
    // A5+A6:按 web messageDefinition 三分类 ——
    // source.kind == 'user':右气泡(claimed → steering 插话变体);
    // 其余:注入上下文 → 左侧低调 ContextRow(不再一刀切过滤)。
    final source = data is Map && data['source'] is Map
        ? data['source'] as Map
        : null;
    final kind = source?['kind'];
    if (kind != null && kind != 'user') {
      final ctx = _contextRowFor(event, source!);
      return ctx == null ? const [] : [ctx];
    }
    final text = extractText(data);
    final images = _imageRefs(data);
    if (text.isEmpty && images.isEmpty) return const [];
    final messageId = data is Map && data['id'] is String ? data['id'] as String? : null;
    return [
      ChatNodeUser(
        seq: event.seq,
        type: type,
        text: text,
        images: images.isEmpty ? null : images,
        steering: inbox.isClaimed(messageId),
        time: event.time,
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
        ChatNodeThink(
          seq: event.seq,
          type: '$type/reasoning',
          text: think,
          time: event.time,
        ),
      );
    }
    if (text.isNotEmpty || images.isNotEmpty) {
      nodes.add(
        ChatNodeAssistant(
          seq: event.seq,
          type: type,
          text: text,
          images: images.isEmpty ? null : images,
          time: event.time,
        ),
      );
    }
    return nodes;
  }
  if (type == 'assistant/chunk') {
    // 无 data.chunk 的防御形状:按文本渲染为普通助手消息(合并由调用方处理)。
    final text = extractText(data);
    if (text.isEmpty) return const [];
    return [
      ChatNodeAssistant(seq: event.seq, type: type, text: text, time: event.time),
    ];
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
        time: event.time,
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
        time: event.time,
      ),
    ];
  }
  if (type == 'turn/end') {
    return _turnEndNodes(event);
  }
  if (type == 'turn/error' || type.startsWith('turn/error')) {
    final message = _pick(data, null, ['message', 'error', 'text']) ?? type;
    return [
      ChatNodeError(
        seq: event.seq,
        type: type,
        message: message,
        time: event.time,
      ),
    ];
  }
  // B2 unknown 收窄(镜像 web fallback.ts):只有 surface 三类型
  // (user/message | assistant/message | tool/result)且 surfaceOp=='append'
  // 但未被本提取器认识的情形,才显示兜底卡;其余未知类型一律不可见
  //(web:未注册节点的 surface 事件之外的类型根本不进时间线)。
  if (type == 'user/message' ||
      type == 'assistant/message' ||
      type == 'tool/result') {
    // 已在上面各分支处理过的形状不会到这里;仍会到这里的 = 结构可识别
    // 但内容空/未产出节点的合法变体(如空 content 的 assistant/message),
    // web 同样不渲染 —— 不可见。
    if (event.surfaceOp == 'append') {
      // surface 三类型 + append 且上面分支没接住(理论上仅防御形状)
      // → 与 web unknown-surface 兜底一致。
      if (data is Map && data.isNotEmpty) {
        return [
          ChatNodeUnknown(seq: event.seq, type: type, data: data, time: event.time),
        ];
      }
    }
    return const [];
  }
  // 协议分隔符/内部管道事件不在主聊天流占位。
  if (_isInternalEvent(type)) return const [];
  // 非三类型的未知事件:web 无节点注册 → 时间线不可见(log-only)。
  return const [];
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

/// turn/end → 提示节点(0.1.0-rc.6 权威形状:data.reason.kind ∈
/// completed|aborted|blocked|error|max-tokens|interrupted)。
/// completed/blocked 不占位(blocked 的等待感由审批交互卡表达,web 亦无
/// 渲染);其余终态各一行,给中断/异常轮次一个明确交代。
List<ChatNode> _turnEndNodes(SessionEvent event) {
  final reason = event.data is Map ? (event.data as Map)['reason'] : null;
  final kind = reason is Map ? reason['kind'] : null;
  switch (kind) {
    case 'aborted':
      return [
        ChatNodeNotice(
          seq: event.seq,
          type: event.type,
          title: '本轮已停止',
          detail: _abortedDetail(reason),
          icon: 'stop',
        ),
      ];
    case 'error':
      return [
        ChatNodeError(
          seq: event.seq,
          type: event.type,
          message: _failureText(reason['error']),
        ),
      ];
    case 'max-tokens':
      return [
        ChatNodeNotice(
          seq: event.seq,
          type: event.type,
          title: '输出已达长度上限',
          icon: 'info',
        ),
      ];
    case 'interrupted':
      return [
        ChatNodeNotice(
          seq: event.seq,
          type: event.type,
          title: '会话异常中断',
          detail: '主机异常退出,本轮未正常结束',
          icon: 'warning',
        ),
      ];
    default:
      return const []; // completed / blocked / 未知变体:不占位。
  }
}

/// aborted 终止原因(TurnEndCancelCause:user|parent|hook|disposed|legacy)。
String? _abortedDetail(Map<dynamic, dynamic> reason) {
  final cause = reason['reason'];
  if (cause is! Map) return null;
  switch (cause['kind']) {
    case 'user':
      return '用户停止';
    case 'parent':
      return '父级会话停止';
    case 'hook':
      final r = cause['reason'];
      return r is String && r.isNotEmpty ? '钩子停止: $r' : '钩子停止';
    case 'disposed':
      return '会话已释放';
    default:
      return null; // legacy 等粗粒度记录
  }
}

/// 轮次失败文本(reason.error = LlmFailure {message, code};
/// code 为 UNKNOWN 时不拼,避免噪音)。
String _failureText(dynamic failure) {
  if (failure is Map) {
    final message = failure['message'];
    final code = failure['code'];
    if (message is String && message.isNotEmpty) {
      return code is String && code.isNotEmpty && code != 'UNKNOWN'
          ? '$message ($code)'
          : message;
    }
    if (code is String && code.isNotEmpty) return code;
  }
  return '轮次失败';
}

/// 内部/管道事件(真实日志普查 + known-event-types 全集):
/// turn 与 step 边界、请求上下文、标题投影、子代理描述符、反馈落盘、
/// run_code 派发的 code-dispatch 子调用、钩子、检索类 LLM 请求。
/// B1 重分类追加(2026-08-17 parity 轮):web 时间线无对应节点的投影/芯片类
/// 事件 —— permission/preset、sandbox/mode、approval/policy(composer chip)、
/// approval/asked|decided(ApprovalPanel 交互卡,mux 帧负责,时间线无痕)、
/// agent/inbox/spliced(publication 'none',已提前消费做 steering 判定)、
/// goal/change(GoalBar 投影)、plan/mode(plan chip)、schedule/change、
/// agent-preset/selected —— 全部不可见(信息面由各自常驻 UI 承载)。
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
    type == 'connection/reset' ||
    type == 'permission/preset' ||
    type == 'sandbox/mode' ||
    type == 'approval/policy' ||
    type == 'approval/asked' ||
    type == 'approval/decided' ||
    type == 'agent-preset/selected' ||
    type == 'goal/change' ||
    type == 'plan/mode' ||
    type == 'schedule/change';

/// A5 注入上下文行(web contextProvenance + contextBody 的 Dart 移植)。
/// provenance:agent-instructions 取 changes[].path;plugin 取 plugin id;
/// skill-invocation 取 name;session-reference 取 references[].label(role=recall);
/// 其余回退 source.kind。summary 仅 notice form(source.summary)。
ChatNodeContextRow? _contextRowFor(SessionEvent event, Map source) {
  final text = extractText(event.data);
  if (text.isEmpty) return null;
  final provenance = _contextProvenance(source);
  final summary = source['summary'] is String
      ? source['summary'] as String?
      : null;
  return ChatNodeContextRow(
    seq: event.seq,
    type: event.type,
    provenanceLabel: provenance.label,
    recall: provenance.recall,
    summary: summary,
    text: text,
    time: event.time,
  );
}

class _ContextProvenance {
  const _ContextProvenance({required this.recall, required this.label});
  final bool recall;
  final String? label;
}

/// web contextProvenance 移植:角色(inject/recall)+ 生产者可读名。
_ContextProvenance _contextProvenance(Map source) {
  final kind = source['kind'];
  if (kind is! String || kind.isEmpty) {
    return const _ContextProvenance(recall: false, label: null);
  }
  switch (kind) {
    case 'session-reference':
      final refs = source['references'];
      final labels = <String>[];
      if (refs is List) {
        for (final r in refs) {
          if (r is Map && r['label'] is String) {
            final l = r['label'] as String?;
            if (l != null && l.isNotEmpty && !labels.contains(l)) labels.add(l);
          }
        }
      }
      return _ContextProvenance(
        recall: true,
        label: labels.isNotEmpty ? labels.join(', ') : kind,
      );
    case 'agent-instructions':
      final changes = source['changes'];
      final paths = <String>[];
      if (changes is List) {
        for (final c in changes) {
          if (c is Map && c['path'] is String) {
            final p = c['path'] as String?;
            if (p != null && p.isNotEmpty && !paths.contains(p)) paths.add(p);
          }
        }
      }
      return _ContextProvenance(
        recall: false,
        label: paths.isNotEmpty ? paths.join(', ') : kind,
      );
    case 'plugin':
      final plugin = source['plugin'];
      return _ContextProvenance(
        recall: false,
        label: plugin is String && plugin.isNotEmpty ? plugin : kind,
      );
    case 'skill-invocation':
      final name = source['name'];
      return _ContextProvenance(
        recall: false,
        label: name is String && name.isNotEmpty ? name : kind,
      );
    default:
      return _ContextProvenance(recall: false, label: kind);
  }
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
/// (只认 message —— {name, code} 形状是中断类错误,不进红错误框。)
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

/// 错误码提取:tool/result 的 data.error = {name, code}(dsh 权威形状:
/// AbortError/ABORTED*、TOOL_OUTCOME_UNKNOWN/TOOL_NOT_STARTED)。
String? _errorCodeOf(dynamic data, Map<String, dynamic>? viewMap) {
  for (final src in <dynamic>[data is Map ? data : null, viewMap]) {
    if (src == null) continue;
    final e = src['error'];
    if (e is Map) {
      final code = e['code'];
      if (code is String && code.isNotEmpty) return code;
    }
    if (e is String && e.isNotEmpty) return e;
  }
  return null;
}

/// 中断类错误码全集(0.1.0-rc.6):运行中被取消 / 派发前被跳过 /
/// 崩溃修复补记的两种未知结局。web 客户端合成的 'interrupted' 同义。
const Set<String> _kInterruptCodes = {
  'ABORTED',
  'ABORTED_BEFORE_DISPATCH',
  'TOOL_OUTCOME_UNKNOWN',
  'TOOL_NOT_STARTED',
  'INTERRUPTED',
};

bool _isInterruptCode(String? code) =>
    code != null && _kInterruptCodes.contains(code.toUpperCase());

/// 状态判定:data.error.code 权威 —— 中断类 → interrupted,其余 code →
/// failed;无 code 时 error 文本 → failed,否则 success。
/// view 词表(dsh-tools presentation)不含 status/interrupted/ok 字段,
/// 不参与判定。
ToolStatus _statusOf(String? code, String? error) {
  if (code != null) {
    return _isInterruptCode(code)
        ? ToolStatus.interrupted
        : ToolStatus.failed;
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
