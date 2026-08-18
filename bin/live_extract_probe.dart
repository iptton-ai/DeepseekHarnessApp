// 活体提取探针(RENDER-PARITY 验收辅助):对活体 3080 拉取现有会话的
// 历史尾页,用 extractNodes 跑真实事件,输出可见内容矩阵 ——
// 不创建会话、不触发 LLM 轮,只读。
//
// 用法:dart run bin/live_extract_probe.dart [sessionId]
// 不带参数时取列表第一个会话。
import 'dart:async';
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/event_nodes.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

const base = 'http://127.0.0.1:3080';

Future<void> main(List<String> args) async {
  final uri = Uri.parse(base);
  final api = ApiClient(baseUri: uri);
  final connection = ConnectionController(baseUri: uri);
  final store = SessionStore(api: api, connection: connection);
  connection.start();
  store.start();

  await connection.snapshots
      .firstWhere((s) => s.phase == ConnectionPhase.ready)
      .timeout(const Duration(seconds: 10));
  print('READY');

  final summaries = await store.summaries.first.timeout(
    const Duration(seconds: 10),
  );
  if (summaries.isEmpty) {
    print('NO SESSIONS');
    exit(0);
  }
  final sid = args.isNotEmpty
      ? args.first
      : summaries.first.sessionId;
  print('SESSION $sid');

  await store.loadHistory(sid);
  final log = store.logFor(sid);
  final events = log.events;
  print('EVENTS ${events.length} (lastSeq=${log.lastSeq})');

  // 类型普查(日志里出现过什么)。
  final typeCounts = <String, int>{};
  for (final e in events) {
    typeCounts[e.type] = (typeCounts[e.type] ?? 0) + 1;
  }
  print('TYPES:');
  final keys = typeCounts.keys.toList()..sort();
  for (final k in keys) {
    print('  $k ×${typeCounts[k]}');
  }

  // 提取 + 可见矩阵。
  final nodes = extractNodes([
    for (final e in events) EventNodeInput(e),
  ]);
  print('NODES ${nodes.length}');
  final kindCounts = <String, int>{};
  for (final n in nodes) {
    final kind = n.runtimeType.toString();
    kindCounts[kind] = (kindCounts[kind] ?? 0) + 1;
  }
  print('VISIBLE MATRIX:');
  final kk = kindCounts.keys.toList()..sort();
  for (final k in kk) {
    print('  $k ×${kindCounts[k]}');
  }

  // 抽样:每类节点第一个的摘要。
  final seen = <String>{};
  for (final n in nodes) {
    final kind = n.runtimeType.toString();
    if (seen.contains(kind)) continue;
    seen.add(kind);
    final desc = switch (n) {
      ChatNodeUser(:final text, :final steering) =>
        'steering=$steering text=${text.substring(0, text.length.clamp(0, 40))}',
      ChatNodeAssistant(:final text, :final runMs, :final ttftMs) =>
        'runMs=$runMs ttftMs=$ttftMs text=${text.substring(0, text.length.clamp(0, 40))}',
      ChatNodeTool(:final toolName, :final status, :final producedPaths) =>
        'name=$toolName status=$status produced=${producedPaths.length}',
      ChatNodeContextRow(:final provenanceLabel, :final recall) =>
        'label=$provenanceLabel recall=$recall',
      ChatNodeCommand(:final name, :final done) => 'name=$name done=$done',
      ChatNodeWorkflowRun(:final name, :final status, :final phases) =>
        'name=$name status=$status phases=${phases.length}',
      ChatNodeDeliverables(:final paths) => 'paths=${paths.take(3).join(",")}',
      ChatNodeThink(:final text) =>
        'text=${text.substring(0, text.length.clamp(0, 40))}',
      ChatNodeError(:final message) => 'msg=$message',
      ChatNodeRetry(:final reason) => 'reason=$reason',
      _ => n.type,
    };
    print('  SAMPLE $kind: $desc');
  }
  print('PROBE-PASS');
  exit(0);
}
