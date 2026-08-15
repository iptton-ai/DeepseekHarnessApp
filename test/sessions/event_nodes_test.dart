// event_nodes 域测试:各节点类型提取 / 工具卡配对 / 未知类型兜底 /
// 排序与可重放不变式。不 import 共享 helper(纪律:测试内自建假数据)。
//
// 输入形态:EventNodeInput(event, [view]) —— view 来自 MuxFrameSessionEvent.view
// (实时 mux 帧),历史回放无 view;工具卡本质信息以 event.data 为准。
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 探针式假事件:data 形状按线上弹性键构造(覆盖不了的按 data 原样渲染)。
SessionEvent _ev(int seq, String type, dynamic data) =>
    SessionEvent(type: type, seq: seq, time: 1786723605000 + seq.toDouble(), data: data);

/// 便捷输入对:事件 + 可选 view(缺省 = 历史回放无 view)。
EventNodeInput _in(int seq, String type, dynamic data, [ToolEventView? view]) =>
    EventNodeInput(_ev(seq, type, data), view);

ToolEventView _callView(Map<String, dynamic> view) => ToolEventViewCall(view: view);
ToolEventView _resultView(Map<String, dynamic> view) => ToolEventViewResult(view: view);

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

  test('user/message 合成上下文(source=agent)不产出,对齐 chat_view_model', () {
    final nodes = extractNodes([
      _in(1, 'user/message', {
        'content': <Map<String, dynamic>>[
          {'type': 'text', 'text': '内部注入'},
        ],
        'source': <String, dynamic>{'kind': 'agent'},
      }),
    ]);
    expect(nodes, isEmpty);
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
    final nodes = extractNodes([_in(3, 'assistant/reasoning', {'text': '推理中…'})]);
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
      _in(4, 'tool/call', {'name': 'bash', 'callId': 'c1', 'input': {'cmd': 'ls'}},
          _callView({'toolName': 'bash'})),
      _in(5, 'tool/result', {'callId': 'c1'},
          _resultView({'status': 'success', 'output': 'file.txt'})),
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
      _in(4, 'tool/call', {'name': 'bash', 'callId': 'c1', 'input': {'cmd': 'ls'}}),
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
      _in(4, 'tool/call', {'name': 'read', 'callId': 'c1'},
          _callView({'toolName': 'bash'})),
      _in(5, 'tool/result', {'callId': 'c1'},
          _resultView({'status': 'failed', 'error': 'x'})),
    ]);
    final tool = nodes.single as ChatNodeTool;
    expect(tool.toolName, 'read'); // data 的 name 胜出
    // 状态/错误是主机渲染意图(view),仍以 view 为准。
    expect(tool.status, ToolStatus.failed);
    expect(tool.error, 'x');
  });

  test('tool call 无 result → 保持运行中卡(未配对渲染运行中)', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {'name': 'bash', 'callId': 'c1', 'input': {'cmd': 'ls'}}),
    ]);
    expect(nodes, hasLength(1));
    final tool = nodes.single as ChatNodeTool;
    expect(tool.status, ToolStatus.running);
    expect(tool.resultSeq, isNull);
    expect(tool.summary, isNotNull); // 摘要由输入预览兜底生成
  });

  test('tool result 无 call 且 view 带 error → 独立失败卡', () {
    final nodes = extractNodes([
      _in(5, 'tool/result', {'callId': 'orphan'},
          _resultView({'status': 'failed', 'error': '权限不足'})),
    ]);
    expect(nodes, hasLength(1));
    final tool = nodes.single as ChatNodeTool;
    expect(tool.status, ToolStatus.failed);
    expect(tool.error, '权限不足');
  });

  test('两个 call 按 callId 交叉配对(不按到达顺序错配)', () {
    final nodes = extractNodes([
      _in(4, 'tool/call', {'name': 'read', 'callId': 'cA', 'input': {'path': 'a'}}),
      _in(5, 'tool/call', {'name': 'read', 'callId': 'cB', 'input': {'path': 'b'}}),
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

  test('未知类型 → 兜底节点(类型名 + 原始 data 保留)', () {
    final nodes = extractNodes([_in(13, 'mystery/thing', {'x': 1})]);
    expect(nodes, hasLength(1));
    final u = nodes.single as ChatNodeUnknown;
    expect(u.type, 'mystery/thing');
    expect(u.data, {'x': 1});
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
    expect(first.map((n) => n.runtimeType).toList(),
        second.map((n) => n.runtimeType).toList());
    final texts = <String>[];
    for (final n in first) {
      if (n is ChatNodeUser) texts.add(n.text);
      if (n is ChatNodeAssistant) texts.add(n.text);
      if (n is ChatNodeError) texts.add(n.message);
    }
    expect(texts, ['A', 'B', 'E']);
  });
}
