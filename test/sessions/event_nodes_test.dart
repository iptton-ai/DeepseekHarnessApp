// event_nodes 域测试:各节点类型提取 / 工具卡配对 / 未知类型兜底 /
// 排序与可重放不变式。不 import 共享 helper(纪律:测试内自建假数据)。
//
// 输入形态:EventNodeInput(event, [view]) —— view 来自 MuxFrameSessionEvent.view
// (实时 mux 帧),历史回放无 view;工具卡本质信息以 event.data 为准。
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 探针式假事件:data 形状按线上弹性键构造(覆盖不了的按 data 原样渲染)。
SessionEvent _ev(int seq, String type, dynamic data) => SessionEvent(
  type: type,
  seq: seq,
  time: 1786723605000 + seq.toDouble(),
  data: data,
);

/// 便捷输入对:事件 + 可选 view(缺省 = 历史回放无 view)。
EventNodeInput _in(int seq, String type, dynamic data, [ToolEventView? view]) =>
    EventNodeInput(_ev(seq, type, data), view);

ToolEventView _callView(Map<String, dynamic> view) =>
    ToolEventViewCall(view: view);
ToolEventView _resultView(Map<String, dynamic> view) =>
    ToolEventViewResult(view: view);

void main() {
  test('user/message → 用户气泡(文本提取)', () {
    final nodes = extractNodes([
      _in(1, 'user/message', {
        'content': <Map<String, dynamic>>[
          {'type': 'text', 'text': '你好,世界'},
        ],
      }),
    ]);
    expect(nodes, hasLength(1));
    final n = nodes.single as ChatNodeUser;
    expect(n.seq, 1);
    expect(n.text, '你好,世界');
  });

  test('user/message 注入上下文(source=agent)→ ContextRow(A5 对齐 web)', () {
    final nodes = extractNodes([
      _in(1, 'user/message', {
        'content': <Map<String, dynamic>>[
          {'type': 'text', 'text': '内部注入'},
        ],
        'source': <String, dynamic>{'kind': 'agent'},
      }),
    ]);
    // 不再一刀切过滤:左侧低调注入行(provenance 回退 kind)。
    final ctx = nodes.single as ChatNodeContextRow;
    expect(ctx.provenanceLabel, 'agent');
    expect(ctx.recall, isFalse);
    expect(ctx.text, '内部注入');
  });

  test('assistant/message → markdown 助手消息', () {
    final nodes = extractNodes([
      _in(2, 'assistant/message', {
        'message': <String, dynamic>{
          'role': 'assistant',
          'content': <Map<String, dynamic>>[
            {'type': 'text', 'text': '**加粗结论**'},
          ],
        },
      }),
    ]);
    expect(nodes, hasLength(1));
    final n = nodes.single as ChatNodeAssistant;
    expect(n.text, '**加粗结论**');
    expect(n.type, 'assistant/message');
  });

  test('assistant/message 的 reasoning 块 → think + assistant 两个节点', () {
    final nodes = extractNodes([
      _in(2, 'assistant/message', {
        'message': <String, dynamic>{
          'content': <Map<String, dynamic>>[
            {'type': 'reasoning', 'text': '先想一步'},
            {'type': 'text', 'text': '最终结论'},
          ],
        },
      }),
    ]);
    expect(nodes, hasLength(2));
    expect(nodes[0], isA<ChatNodeThink>());
    expect((nodes[0] as ChatNodeThink).text, '先想一步');
    expect(nodes[1], isA<ChatNodeAssistant>());
    expect((nodes[1] as ChatNodeAssistant).text, '最终结论');
  });

  test('独立 think 事件(assistant/reasoning)→ ChatNodeThink', () {
    final nodes = extractNodes([
      _in(3, 'assistant/reasoning', {'text': '推理中…'}),
    ]);
    expect(nodes, hasLength(1));
    final n = nodes.single as ChatNodeThink;
    expect(n.text, '推理中…');
  });

  test('assistant/chunk 流式块按文本渲染为助手消息', () {
    final nodes = extractNodes([
      _in(4, 'assistant/chunk', {
        'content': <Map<String, dynamic>>[
          {'type': 'text', 'text': '增量文本'},
        ],
      }),
    ]);
    expect(nodes, hasLength(1));
    expect((nodes.single as ChatNodeAssistant).text, '增量文本');
  });

  test('tool call+result 经 view 配对 → 单个成功卡(含输入输出)', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {
        'name': 'bash',
        'callId': 'c1',
        'input': {'cmd': 'ls'},
      }, _callView({'toolName': 'bash'})),
      _in(5, 'tool/result', {
        'callId': 'c1',
      }, _resultView({'status': 'success', 'output': 'file.txt'})),
    ]);
    expect(nodes, hasLength(1));
    final tool = nodes.single as ChatNodeTool;
    expect(tool.toolName, 'bash');
    expect(tool.callId, 'c1');
    expect(tool.status, ToolStatus.success);
    expect(tool.callSeq, 4);
    expect(tool.resultSeq, 5);
    expect(tool.input, {'cmd': 'ls'});
    expect(tool.output, 'file.txt');
  });

  test('历史回放无 view 也能渲染工具卡:全以 event.data 为准', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {
        'name': 'bash',
        'callId': 'c1',
        'input': {'cmd': 'ls'},
      }),
      _in(5, 'tool/result', {'callId': 'c1', 'output': 'file.txt'}),
    ]);
    expect(nodes, hasLength(1));
    final tool = nodes.single as ChatNodeTool;
    expect(tool.toolName, 'bash'); // 名称来自 data
    expect(tool.status, ToolStatus.success); // 无 view 时结果即成功
    expect(tool.output, 'file.txt');
    expect(tool.input, {'cmd': 'ls'});
  });

  test('工具卡本质信息以 data 为准:view 与 data 冲突时取 data', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {
        'name': 'read',
        'callId': 'c1',
      }, _callView({'toolName': 'bash'})),
      _in(5, 'tool/result', {
        'callId': 'c1',
      }, _resultView({'status': 'failed', 'error': 'x'})),
    ]);
    final tool = nodes.single as ChatNodeTool;
    expect(tool.toolName, 'read'); // data 的 name 胜出
    // 状态/错误是主机渲染意图(view),仍以 view 为准。
    expect(tool.status, ToolStatus.failed);
    expect(tool.error, 'x');
  });

  test('tool call 无 result → 保持运行中卡(未配对渲染运行中)', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {
        'name': 'bash',
        'callId': 'c1',
        'input': {'cmd': 'ls'},
      }),
    ]);
    expect(nodes, hasLength(1));
    final tool = nodes.single as ChatNodeTool;
    expect(tool.status, ToolStatus.running);
    expect(tool.resultSeq, isNull);
    expect(tool.summary, isNotNull); // 摘要由输入预览兜底生成
  });

  test('tool result 无 call 且 view 带 error → 独立失败卡', () {
    final nodes = extractNodes([
      _in(5, 'tool/result', {
        'callId': 'orphan',
      }, _resultView({'status': 'failed', 'error': '权限不足'})),
    ]);
    expect(nodes, hasLength(1));
    final tool = nodes.single as ChatNodeTool;
    expect(tool.status, ToolStatus.failed);
    expect(tool.error, '权限不足');
  });

  test('两个 call 按 callId 交叉配对(不按到达顺序错配)', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {
        'name': 'read',
        'callId': 'cA',
        'input': {'path': 'a'},
      }),
      _in(5, 'tool/call', {
        'name': 'read',
        'callId': 'cB',
        'input': {'path': 'b'},
      }),
      _in(6, 'tool/result', {'callId': 'cB'}),
      _in(7, 'tool/result', {'callId': 'cA'}),
    ]);
    expect(nodes, hasLength(2));
    final first = nodes[0] as ChatNodeTool; // seq 4 的 cA
    final second = nodes[1] as ChatNodeTool; // seq 5 的 cB
    expect(first.callId, 'cA');
    expect(first.resultSeq, 7);
    expect(second.callId, 'cB');
    expect(second.resultSeq, 6);
  });

  test('tool/error 事件视作失败结果(带错误文本)', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {'name': 'bash', 'callId': 'c1'}),
      _in(5, 'tool/error', {'callId': 'c1', 'error': 'command not found'}),
    ]);
    expect(nodes, hasLength(1));
    final tool = nodes.single as ChatNodeTool;
    expect(tool.status, ToolStatus.failed);
    expect(tool.error, 'command not found');
  });

  test('todo/write → 紧凑计划卡(计数 done/total)', () {
    final nodes = extractNodes([
      _in(8, 'todo/write', {
        'items': <dynamic>[
          {'title': '调研', 'status': 'done'},
          {'title': '编码'},
          '收尾',
        ],
      }),
    ]);
    expect(nodes, hasLength(1));
    final todo = nodes.single as ChatNodeTodo;
    expect(todo.total, 3);
    expect(todo.done, 1);
    expect(todo.items.first.title, '调研');
  });

  test('compaction/summary → 检查点(kind/摘要/消息数)', () {
    final nodes = extractNodes([
      _in(9, 'compaction/summary', {'summary': '已压缩到关键上下文', 'messages': 12}),
    ]);
    expect(nodes, hasLength(1));
    final c = nodes.single as ChatNodeCompaction;
    expect(c.kind, 'summary');
    expect(c.summary, '已压缩到关键上下文');
    expect(c.messages, 12);
  });

  test('llm/retry → 重试行(reason/attempt)', () {
    final nodes = extractNodes([
      _in(10, 'llm/retry', {'reason': '速率限制', 'attempt': 2}),
    ]);
    expect(nodes, hasLength(1));
    final r = nodes.single as ChatNodeRetry;
    expect(r.reason, '速率限制');
    expect(r.attempt, 2);
  });

  test('turn/error → 错误行(message 兜底为类型名)', () {
    final nodes = extractNodes([
      _in(11, 'turn/error', {'message': '模型超时'}),
    ]);
    expect(nodes, hasLength(1));
    expect((nodes.single as ChatNodeError).message, '模型超时');
    // message 缺失时兜底为类型名。
    final fallback = extractNodes([_in(12, 'turn/error', <String, dynamic>{})]);
    expect((fallback.single as ChatNodeError).message, 'turn/error');
  });

  test('B2 unknown 收窄:非 surface 三类型的未知事件一律不可见', () {
    // web fallback.ts:未注册节点的类型根本不进时间线(log-only)。
    final nodes = extractNodes([
      _in(13, 'mystery/thing', {'x': 1}),
      _in(14, 'future/surface-ish', {'y': 2}),
    ]);
    expect(nodes, isEmpty);
  });

  test('B1 噪声重分类:投影/芯片类事件时间线不可见(web 无对应节点)', () {
    // permission/preset、sandbox/mode、approval/policy、approval/asked|decided、
    // goal/change、plan/mode、schedule/change、agent-preset/selected 全部
    // 不可见 —— 信息面由 composer chip / 审批交互卡 / GoalBar 等常驻 UI 承载。
    final nodes = extractNodes([
      _in(13, 'turn/start', <String, dynamic>{}),
      _in(14, 'sandbox/mode', {'mode': 'workspace-write'}),
      _in(15, 'permission/preset', {'preset': 'workspace-write'}),
      _in(16, 'approval/policy', {'policy': 'ask'}),
      _in(17, 'approval/asked', {'toolName': 'bash'}),
      _in(18, 'approval/decided', {'outcome': 'allowed-once'}),
      _in(19, 'goal/change', {
        'goal': {'objective': 'x'}
      }),
      _in(20, 'plan/mode', {'active': true}),
      _in(21, 'schedule/change', {'name': '日报'}),
      _in(22, 'agent-preset/selected', {'agentPreset': 'web'}),
      _in(23, 'turn/end', <String, dynamic>{}),
    ]);
    expect(nodes, isEmpty);
  });


// ---------------------------------------------------------------------------
// 展示逻辑对齐真实线上形状(dsh-session known-event-types + 本机日志普查)
// ---------------------------------------------------------------------------

  test('assistant/chunk 流式折叠:同 (turn,step) 的 delta 合并为直播节点', () {
    final nodes = extractNodes([
      _in(1, 'turn/start', {'turn': 1}),
      _in(2, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'block-start', 'index': 0, 'blockType': 'reasoning'},
      }),
      _in(3, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': '想想'},
      }),
      _in(4, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'block-start', 'index': 1, 'blockType': 'text'},
      }),
      _in(5, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'text-delta', 'index': 1, 'text': '你好'},
      }),
      _in(6, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'text-delta', 'index': 1, 'text': ',世界'},
      }),
    ]);
    // think(直播)+ assistant(直播)两个节点,文本为累计增量。
    expect(nodes, hasLength(2));
    final think = nodes.whereType<ChatNodeThink>().single;
    expect(think.text, '想想');
    expect(think.streaming, isTrue);
    final text = nodes.whereType<ChatNodeAssistant>().single;
    expect(text.text, '你好,世界');
    expect(text.streaming, isTrue);
    // 流式节点 seq 锚定块首事件(firstSeq):delta 继续到达也不变 ——
    // 列表 ValueKey 稳定,item State(think 展开态/尾随滚动)跨帧保留。
    expect(think.seq, 2);
    expect(text.seq, 2);
    // 再追加 delta 后重新提取:seq 仍稳定,文本增长。
    final grown = extractNodes([
      _in(1, 'turn/start', {'turn': 1}),
      _in(2, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'block-start', 'index': 0, 'blockType': 'reasoning'},
      }),
      _in(3, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': '想想'},
      }),
      _in(4, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'block-start', 'index': 1, 'blockType': 'text'},
      }),
      _in(5, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'text-delta', 'index': 1, 'text': '你好'},
      }),
      _in(6, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'text-delta', 'index': 1, 'text': ',世界'},
      }),
      _in(7, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'text-delta', 'index': 1, 'text': '!!'},
      }),
    ]);
    final grownText = grown.whereType<ChatNodeAssistant>().single;
    expect(grownText.seq, 2); // 不随 lastSeq(7)漂移
    expect(grownText.text, '你好,世界!!');
  });

  test('assistant/chunk 折叠被同 (turn,step) 的 assistant/message 定稿替换', () {
    final nodes = extractNodes([
      _in(2, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '直播中'},
      }),
      _in(3, 'assistant/message', {
        'turn': 1, 'step': 1,
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': '定稿文本'},
          ],
        },
      }),
    ]);
    expect(nodes, hasLength(1));
    final n = nodes.single as ChatNodeAssistant;
    expect(n.text, '定稿文本');
    expect(n.streaming, isFalse);
  });

  test('assistant/chunk 折叠:turn/end 之后的残留游不再标记 streaming', () {
    final nodes = extractNodes([
      _in(2, 'assistant/chunk', {
        'turn': 1, 'step': 1,
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '被中断的输出'},
      }),
      _in(3, 'turn/end', {'turn': 1}),
    ]);
    final n = nodes.whereType<ChatNodeAssistant>().single;
    expect(n.text, '被中断的输出');
    expect(n.streaming, isFalse);
  });

  test('tool/result 嵌套形状(线上 data.message.content[].tool-result)无 view 完整渲染', () {
    final nodes = extractNodes([
      _in(10, 'tool/call', {
        'turn': 1, 'step': 2,
        'callId': 'call_x',
        'name': 'bash',
        'arguments': '{"command":"ls","description":"x"}',
      }),
      _in(11, 'tool/result', {
        'turn': 1, 'step': 2,
        'message': {
          'source': {'kind': 'tool', 'callId': 'call_x'},
          'role': 'user',
          'content': [
            {
              'type': 'tool-result',
              'toolCallId': 'call_x',
              'content': [
                {'type': 'text', 'text': 'file-a.txt'},
                {'type': 'text', 'text': 'file-b.txt'},
              ],
              'isError': false,
            },
          ],
        },
      }),
    ]);
    expect(nodes, hasLength(1));
    final tool = nodes.single as ChatNodeTool;
    expect(tool.toolName, 'bash');
    expect(tool.callId, 'call_x');
    expect(tool.status, ToolStatus.success);
    // 输出从嵌套 tool-result 块拼接;输入 JSON 字符串被解码为结构。
    expect(tool.output, 'file-a.txt\nfile-b.txt');
    expect(tool.input, {
      'command': 'ls',
      'description': 'x',
    });
    // bash 摘要取 command 字段。
    expect(tool.summary, 'ls');
  });

  test('tool/result isError=true → 失败卡 + 错误文本取输出', () {
    final nodes = extractNodes([
      _in(10, 'tool/call', {'callId': 'c1', 'name': 'bash'}),
      _in(11, 'tool/result', {
        'message': {
          'source': {'kind': 'tool', 'callId': 'c1'},
          'content': [
            {
              'type': 'tool-result',
              'toolCallId': 'c1',
              'content': [
                {'type': 'text', 'text': 'command not found'},
              ],
              'isError': true,
            },
          ],
        },
      }),
    ]);
    final tool = nodes.single as ChatNodeTool;
    expect(tool.status, ToolStatus.failed);
    expect(tool.error, 'command not found');
  });

  test('todo/write 线上形状:{content,status} 计入标题与完成态', () {
    final nodes = extractNodes([
      _in(20, 'todo/write', {
        'todos': [
          {'content': '调研', 'status': 'completed'},
          {'content': '编码', 'status': 'in_progress'},
          {'content': '测试', 'status': 'pending'},
        ],
      }),
    ]);
    final todo = nodes.single as ChatNodeTodo;
    expect(todo.total, 3);
    expect(todo.done, 1);
    expect(todo.items.map((i) => i.title).toList(), ['调研', '编码', '测试']);
  });

  test('llm/retry 线上形状:failure.message 作原因,retry/maxRetries 作次数', () {
    final nodes = extractNodes([
      _in(30, 'llm/retry', {
        'retry': 1,
        'maxRetries': 2,
        'failure': {'message': '500: 网络错误', 'code': 'SERVER'},
      }),
      _in(31, 'llm/retry-started', {'retry': 1}),
    ]);
    // retry-started 是重复噪音,只留一行。
    expect(nodes, hasLength(1));
    final r = nodes.single as ChatNodeRetry;
    expect(r.reason, '500: 网络错误');
    expect(r.attempt, 1);
    expect(r.maxRetries, 2);
  });

  test('approval/asked|decided → 时间线不可见(B1;交互卡由 mux 帧负责)', () {
    // web:ApprovalPanel composer 接管,时间线无痕;mux approval/requested
    // 才是交互卡数据源 —— 会话事件层不再双份提示。
    final nodes = extractNodes([
      _in(40, 'approval/asked', {
        'id': 'ap1',
        'toolName': 'bash',
        'callId': 'c9',
        'reason': 'escalate sandbox',
      }),
      _in(41, 'approval/decided', {
        'id': 'ap1',
        'outcome': 'allowed-once',
      }),
    ]);
    expect(nodes, isEmpty);
  });

  test('协议管道事件不进主聊天流(不再伪装成未知事件)', () {
    final nodes = extractNodes([
      _in(1, 'step/start', {'turn': 1, 'step': 1}),
      _in(2, 'step/end', {'turn': 1, 'step': 1}),
      _in(3, 'request/context', {'provider': 'x', 'model': 'm'}),
      _in(4, 'request/header', {'k': 1}),
      _in(5, 'session/title', {'title': 't'}),
      _in(6, 'session/title-llm-request', {}),
      _in(7, 'session/end-seed', {}),
      _in(8, 'subagent/descriptor', {}),
      _in(9, 'feedback/record', {}),
      _in(10, 'tool/code-dispatch', {'subCallId': 's1'}),
      _in(11, 'tool/code-dispatch-start', {'subCallId': 's1'}),
      _in(12, 'hook/invoked', {}),
      _in(13, 'hook/result', {}),
      _in(14, 'web/deepseek-search-llm-request', {}),
    ]);
    expect(nodes, isEmpty);
  });

  test('tool-workflow 四事件 → 单张聚合运行卡(A7 对齐 web workflow-run)', () {
    final nodes = extractNodes([
      _in(1, 'tool-workflow/run-start', {
        'runId': 'r1',
        'name': 'audit',
      }),
      _in(2, 'tool-workflow/agent-start', {
        'runId': 'r1',
        'seq': 0,
        'label': '审计员 A',
        'phase': 'scan',
        'childId': 'child-a',
      }),
      _in(3, 'tool-workflow/agent-start', {
        'runId': 'r1',
        'seq': 1,
        'label': '审计员 B',
        'childId': 'child-b',
      }),
      _in(4, 'tool-workflow/agent-end', {
        'runId': 'r1',
        'seq': 0,
        'outcome': 'completed',
      }),
      _in(5, 'tool-workflow/run-end', {
        'runId': 'r1',
        'stopReason': 'error',
      }),
    ]);
    expect(nodes, hasLength(1));
    final run = nodes.single as ChatNodeWorkflowRun;
    expect(run.name, 'audit');
    expect(run.status, 'failed'); // stopReason=error → failed
    expect(run.seq, 1); // 锚定 run-start
    expect(run.phases, hasLength(2)); // scan 阶段 + 未声明阶段
    expect(run.phases[0].phase, 'scan');
    expect(run.phases[0].members.single.label, '审计员 A');
    expect(run.phases[0].members.single.status, 'completed');
    expect(run.phases[1].phase, isNull); // 未声明 phase 的成员归默认组
    // run 已结束但成员 1 无 agent-end → interrupted(web 同款)。
    expect(run.phases[1].members.single.status, 'interrupted');
  });

  test('command/run+done → 单张命令卡配对(B1 换形式)', () {
    final nodes = extractNodes([
      _in(10, 'command/run', {
        'commandId': 'cmd-1',
        'name': 'permission',
        'args': ' danger-full-access',
      }),
      _in(11, 'command/done', {
        'commandId': 'cmd-1',
        'kind': 'success',
        'text': 'preset danger-full-access',
      }),
    ]);
    expect(nodes, hasLength(1));
    final cmd = nodes.single as ChatNodeCommand;
    expect(cmd.name, 'permission');
    expect(cmd.args, contains('danger-full-access'));
    expect(cmd.done, isTrue);
    expect(cmd.outcomeKind, 'success');
    expect(cmd.outcomeText, 'preset danger-full-access');
    expect(cmd.seq, 10); // 锚定 run 事件
    // 只有 run 无 done:运行中卡。
    final running = extractNodes([
      _in(12, 'command/run', {
        'commandId': 'cmd-2',
        'name': 'export',
      }),
    ]);
    final r2 = running.single as ChatNodeCommand;
    expect(r2.done, isFalse);
    expect(r2.outcomeKind, isNull);
  });

  test('A1 轮末产出文件:修改意图 view locations 在 turn/end 结转为 Deliverables', () {
    final nodes = extractNodes([
      _in(1, 'turn/start', {'turn': 1}),
      _in(2, 'tool/call', {
        'name': 'edit',
        'callId': 'c1',
        'input': {'path': 'a.dart'},
      }, _callView({
        'card': 'generic',
        'kind': 'edit',
        'locations': [
          {'path': 'lib/a.dart'},
        ],
      })),
      _in(3, 'tool/result', {
        'message': {
          'source': {'callId': 'c1'},
          'content': [
            {
              'type': 'tool-result',
              'content': [
                {'type': 'text', 'text': 'ok'},
              ],
            }
          ],
        }
      }),
      // 同路径二次编辑:首见去重。
      _in(4, 'tool/call', {
        'name': 'edit',
        'callId': 'c2',
        'input': {'path': 'a.dart'},
      }, _callView({
        'card': 'diff',
        'locations': [
          {'path': 'lib/a.dart'},
          {'path': 'lib/b.dart'},
        ],
      })),
      _in(5, 'tool/result', {
        'message': {
          'source': {'callId': 'c2'},
          'content': [
            {
              'type': 'tool-result',
              'content': [
                {'type': 'text', 'text': 'ok'},
              ],
            }
          ],
        }
      }),
      _in(6, 'turn/end', {'reason': {'kind': 'completed'}}),
    ]);
    final deliverables = nodes.whereType<ChatNodeDeliverables>().single;
    expect(deliverables.paths, ['lib/a.dart', 'lib/b.dart']);
    expect(deliverables.seq, 6); // 锚定 turn/end
  });

  test('A1 失败调用的产出不计入;读类调用无产出', () {
    final nodes = extractNodes([
      _in(1, 'turn/start', {'turn': 1}),
      _in(2, 'tool/call', {
        'name': 'edit',
        'callId': 'c1',
        'input': {'path': 'a.dart'},
      }, _callView({
        'card': 'generic',
        'kind': 'edit',
        'locations': [
          {'path': 'lib/failed.dart'},
        ],
      })),
      _in(3, 'tool/result', {
        'message': {
          'source': {'callId': 'c1'},
          'content': [
            {
              'type': 'tool-result',
              'isError': true,
              'content': [
                {'type': 'text', 'text': 'boom'},
              ],
            }
          ],
        }
      }),
      _in(4, 'turn/end', {'reason': {'kind': 'completed'}}),
    ]);
    expect(nodes.whereType<ChatNodeDeliverables>(), isEmpty);
  });

  test('A5 provenance 词表:plugin/skill/instructions/session-reference', () {
    final nodes = extractNodes([
      _in(1, 'user/message', {
        'content': [
          {'type': 'text', 'text': 'p'},
        ],
        'source': {'kind': 'plugin', 'plugin': 'tool-jobs', 'form': 'notice', 'summary': 'job done'},
      }),
      _in(2, 'user/message', {
        'content': [
          {'type': 'text', 'text': 's'},
        ],
        'source': {'kind': 'skill-invocation', 'name': 'cordis'},
      }),
      _in(3, 'user/message', {
        'content': [
          {'type': 'text', 'text': 'i'},
        ],
        'source': {
          'kind': 'agent-instructions',
          'changes': [
            {'path': 'AGENTS.md'},
            {'path': 'AGENTS.md'},
            {'path': 'docs/X.md'},
          ],
        },
      }),
      _in(4, 'user/message', {
        'content': [
          {'type': 'text', 'text': 'r'},
        ],
        'source': {
          'kind': 'session-reference',
          'references': [
            {'label': '旧会话 A'},
          ],
        },
      }),
    ]);
    final rows = nodes.whereType<ChatNodeContextRow>().toList();
    expect(rows, hasLength(4));
    expect(rows[0].provenanceLabel, 'tool-jobs');
    expect(rows[0].summary, 'job done'); // notice form 的 summary 上折叠行
    expect(rows[1].provenanceLabel, 'cordis');
    expect(rows[2].provenanceLabel, 'AGENTS.md, docs/X.md'); // 去重
    expect(rows[3].recall, isTrue); // session-reference → 召回
    expect(rows[3].provenanceLabel, '旧会话 A');
  });

  test('A2 时间基线:节点携带事件 time(epoch ms)', () {
    final nodes = extractNodes([
      _in(1, 'user/message', {
        'content': [
          {'type': 'text', 'text': 'hi'},
        ],
        'source': {'kind': 'user'},
      }),
      _in(2, 'assistant/message', {
        'message': {
          'content': [
            {'type': 'text', 'text': 'hey'},
          ],
        },
      }),
    ]);
    expect(nodes.first.time, 1786723605000 + 1);
    expect(nodes.last.time, 1786723605000 + 2);
  });

  test('agent/inbox/spliced → 不可见,但驱动 steering 判定(A6)', () {
    // web inbox.ts:publication 'none',next-step splice 的 removed 项记
    // claimed → 对应落位 user/message 渲染为插话气泡。
    final nodes = extractNodes([
      _in(1, 'agent/inbox/spliced', {
        'target': 'next-step',
        'start': 0,
        'inserted': [],
        'removedCount': 1,
      }),
      // splice 之前 inbox 里得有一条排队项(先入队再被接纳)。
      _in(0, 'agent/inbox/spliced', {
        'target': 'next-step',
        'start': 0,
        'inserted': [
          {'id': 'm-1'},
        ],
        'removedCount': 0,
      }),
      _in(2, 'user/message', {
        'content': [
          {'type': 'text', 'text': '插话:换个角度'},
        ],
        'source': {'kind': 'user'},
        'id': 'm-1',
      }),
      _in(3, 'user/message', {
        'content': [
          {'type': 'text', 'text': '普通新消息'},
        ],
        'source': {'kind': 'user'},
        'id': 'm-2',
      }),
    ]);
    // splice 本身不可见;两条用户消息,第一条是插话,第二条不是。
    expect(nodes.whereType<ChatNodeNotice>(), isEmpty);
    final users = nodes.whereType<ChatNodeUser>().toList();
    expect(users, hasLength(2));
    expect(users[0].steering, isTrue);
    expect(users[0].text, '插话:换个角度');
    expect(users[1].steering, isFalse);
  });

  test('摘要种子兜底:Map 输入无 command/path 键 → 格式化 JSON 预览(不崩溃)', () {
    // 回归:线上 run_code 等工具的 input 是 Map 但没有 cmdKeys/pathKeys,
    // _summarySeed 曾声明 String? 却 return Map → 运行时隐式下转崩溃
    // (type '_Map<String, dynamic>' is not a subtype of 'String?')。
    final nodes = extractNodes([
      _in(1, 'tool/call', {
        'name': 'run_code',
        'callId': 'c1',
        'input': {
          'description': '列出文件',
          'code': 'ls -la',
        },
      }),
    ]);
    final tool = nodes.single as ChatNodeTool;
    expect(tool.toolName, 'run_code');
    expect(tool.summary, isNotNull);
    // 摘要是格式化 JSON 的截断预览(含键名),不再是崩溃。
    expect(tool.summary, contains('description'));
  });

  test('乱序输入 → seq 升序输出;两次提取一致(纯函数可重放)', () {
    final inputs = [
      _in(2, 'assistant/message', {
        'message': <String, dynamic>{
          'content': <Map<String, dynamic>>[
            {'type': 'text', 'text': 'B'},
          ],
        },
      }),
      _in(1, 'user/message', {
        'content': <Map<String, dynamic>>[
          {'type': 'text', 'text': 'A'},
        ],
      }),
      _in(3, 'turn/error', {'message': 'E'}),
    ];
    final first = extractNodes(inputs);
    final second = extractNodes(inputs);
    // 排序不变式:输出按 seq 升序。
    expect(first.map((n) => n.seq).toList(), [1, 2, 3]);
    // 可重放:两次提取的类型序列与内容一致。
    expect(
      first.map((n) => n.runtimeType).toList(),
      second.map((n) => n.runtimeType).toList(),
    );
    final texts = <String>[];
    for (final n in first) {
      if (n is ChatNodeUser) texts.add(n.text);
      if (n is ChatNodeAssistant) texts.add(n.text);
      if (n is ChatNodeError) texts.add(n.message);
    }
    expect(texts, ['A', 'B', 'E']);
  });

// ---------------------------------------------------------------------------
// 中断/异常落点(0.1.0-rc.6 权威形状:dsh-session TurnEndReasonMap +
// dsh-agent-loop appendSkippedToolCall + interruptedTurnClosers 崩溃修复)
// ---------------------------------------------------------------------------

  /// 线上合成 tool/result 的权威形状:message.content[].tool-result +
  /// 顶层 data.error = {name, code}(无 message 字段)。
  Map<String, dynamic> abortResult(String callId, String code, String text) => {
    'turn': 1,
    'step': 1,
    'message': {
      'source': {'kind': 'tool', 'callId': callId},
      'content': [
        {
          'type': 'tool-result',
          'toolCallId': callId,
          'isError': true,
          'content': [
            {'type': 'text', 'text': text},
          ],
        },
      ],
    },
    'error': {'name': 'AbortError', 'code': code},
  };

  test('取消未派发调用:ABORTED_BEFORE_DISPATCH → 中断卡,不显示红错误框', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {
        'turn': 1, 'step': 1,
        'name': 'bash', 'callId': 'c1',
        'arguments': '{"command":"sleep 10"}',
      }),
      _in(5, 'tool/result', abortResult(
        'c1', 'ABORTED_BEFORE_DISPATCH', 'Error: tool call aborted before dispatch',
      )),
    ]);
    expect(nodes, hasLength(1));
    final tool = nodes.single as ChatNodeTool;
    expect(tool.status, ToolStatus.interrupted);
    // 输出文本原样留在输出区(不提升进 error,对齐 web stopped 语义)。
    expect(tool.error, isNull);
    expect(tool.output, 'Error: tool call aborted before dispatch');
  });

  test('已派发被中断:ABORTED → 中断卡;崩溃修复 code 同样判中断', () {
    for (final code in ['ABORTED', 'TOOL_OUTCOME_UNKNOWN', 'TOOL_NOT_STARTED']) {
      final nodes = extractNodes([
        _in(4, 'tool/call', {'name': 'bash', 'callId': 'c1'}),
        _in(5, 'tool/result', abortResult('c1', code, 'unknown outcome')),
      ]);
      final tool = nodes.single as ChatNodeTool;
      expect(tool.status, ToolStatus.interrupted, reason: code);
    }
  });

  test('普通失败(isError 无 code)仍为失败卡 + 输出提升为错误文本(回归)', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {'name': 'bash', 'callId': 'c1'}),
      _in(5, 'tool/result', {
        'message': {
          'source': {'kind': 'tool', 'callId': 'c1'},
          'content': [
            {
              'type': 'tool-result',
              'toolCallId': 'c1',
              'isError': true,
              'content': [
                {'type': 'text', 'text': 'command not found'},
              ],
            },
          ],
        },
      }),
    ]);
    final tool = nodes.single as ChatNodeTool;
    expect(tool.status, ToolStatus.failed);
    expect(tool.error, 'command not found');
  });

  test('turn/end(aborted)结算未配对运行卡为中断 + 「本轮已停止」提示', () {
    final nodes = extractNodes([
      _in(1, 'turn/start', {'turn': 1}),
      _in(2, 'user/message', {
        'content': [
          {'type': 'text', 'text': '跑个长任务'},
        ],
      }),
      _in(3, 'tool/call', {
        'turn': 1, 'step': 1,
        'name': 'bash', 'callId': 'c1',
        'arguments': '{"command":"sleep 100"}',
      }),
      _in(4, 'turn/end', {
        'turn': 1,
        'reason': {
          'kind': 'aborted',
          'reason': {'kind': 'user'},
        },
      }),
    ]);
    // 用户气泡 + 中断工具卡 + 停止提示;turn/start 仍不占位。
    expect(nodes, hasLength(3));
    final tool = nodes.whereType<ChatNodeTool>().single;
    expect(tool.status, ToolStatus.interrupted);
    expect(tool.resultSeq, 4); // 结算锚定 turn/end
    expect(tool.seq, 3); // 卡保持 call 位(列表 key 稳定)
    final notice = nodes.whereType<ChatNodeNotice>().single;
    expect(notice.title, '本轮已停止');
    expect(notice.detail, '用户停止');
    expect(notice.icon, 'stop');
  });

  test('step/end 精确结算同 (turn,step) 的运行卡;其他 step 不受影响', () {
    final nodes = extractNodes([
      _in(3, 'tool/call', {
        'turn': 1, 'step': 1,
        'name': 'read', 'callId': 'cA',
      }),
      _in(4, 'step/end', {'turn': 1, 'step': 1}),
      _in(5, 'tool/call', {
        'turn': 1, 'step': 2,
        'name': 'bash', 'callId': 'cB',
      }),
      _in(6, 'step/end', {'turn': 2, 'step': 1}), // 别的 turn 边界
    ]);
    final a = nodes[0] as ChatNodeTool;
    final b = nodes[1] as ChatNodeTool;
    expect(a.callId, 'cA');
    expect(a.status, ToolStatus.interrupted); // 自己的 step 关闭 → 结算
    expect(a.resultSeq, 4);
    expect(b.callId, 'cB');
    expect(b.status, ToolStatus.running); // 别的范围关闭 → 不动
    expect(b.resultSeq, isNull);
  });

  test('结算后的真实结果不再重复占卡(pending 已消耗)', () {
    // 极端乱序:结算后同 callId 的迟到 result 只能成独立卡,不覆盖。
    final nodes = extractNodes([
      _in(3, 'tool/call', {'turn': 1, 'step': 1, 'name': 'bash', 'callId': 'c1'}),
      _in(4, 'turn/end', {'turn': 1, 'reason': {'kind': 'aborted'}}),
      _in(5, 'tool/result', {'callId': 'c1', 'output': 'late'}),
    ]);
    expect(nodes, hasLength(3));
    final tool = nodes.whereType<ChatNodeTool>().first;
    expect(tool.status, ToolStatus.interrupted);
    final late = nodes.whereType<ChatNodeTool>().last;
    expect(late.output, 'late');
  });

  test('turn/end reason=error → ChatNodeError(message + code)', () {
    final nodes = extractNodes([
      _in(4, 'turn/end', {
        'turn': 1,
        'reason': {
          'kind': 'error',
          'error': {'message': 'Provider rate limited', 'code': 'RATE_LIMIT'},
        },
      }),
    ]);
    final err = nodes.single as ChatNodeError;
    expect(err.message, 'Provider rate limited (RATE_LIMIT)');
    // message 缺失 → 仅 code;code UNKNOWN 不拼。
    final codeOnly = extractNodes([
      _in(5, 'turn/end', {
        'turn': 1,
        'reason': {
          'kind': 'error',
          'error': {'message': '', 'code': 'TIMEOUT'},
        },
      }),
    ]);
    expect((codeOnly.single as ChatNodeError).message, 'TIMEOUT');
    final unknown = extractNodes([
      _in(6, 'turn/end', {
        'turn': 1,
        'reason': {
          'kind': 'error',
          'error': {'message': 'boom', 'code': 'UNKNOWN'},
        },
      }),
    ]);
    expect((unknown.single as ChatNodeError).message, 'boom');
  });

  test('turn/end reason=max-tokens / interrupted → 各一行提示;completed/blocked 不占位', () {
    final maxTokens = extractNodes([
      _in(4, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'max-tokens'},
      }),
    ]);
    final mt = maxTokens.single as ChatNodeNotice;
    expect(mt.title, '输出已达长度上限');

    final crashed = extractNodes([
      _in(5, 'turn/end', {
        'turn': 1,
        'reason': {'kind': 'interrupted'},
      }),
    ]);
    final cr = crashed.single as ChatNodeNotice;
    expect(cr.title, '会话异常中断');
    expect(cr.icon, 'warning');

    for (final kind in ['completed', 'blocked']) {
      final quiet = extractNodes([
        _in(6, 'turn/end', {'turn': 1, 'reason': {'kind': kind}}),
      ]);
      expect(quiet, isEmpty, reason: kind);
    }
  });

  test('aborted 终止原因变体:parent / hook(带 reason)/ 缺 reason', () {
    String? detailOf(Map<String, dynamic> reason) {
      final nodes = extractNodes([
        _in(4, 'turn/end', {'turn': 1, 'reason': reason}),
      ]);
      return (nodes.single as ChatNodeNotice).detail;
    }
    expect(
      detailOf({'kind': 'aborted', 'reason': {'kind': 'parent'}}),
      '父级会话停止',
    );
    expect(
      detailOf({
        'kind': 'aborted',
        'reason': {'kind': 'hook', 'reason': 'policy'},
      }),
      '钩子停止: policy',
    );
    expect(detailOf({'kind': 'aborted'}), isNull);
  });
}
