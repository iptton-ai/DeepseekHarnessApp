// M2 验收冒烟:对活体 3080 完成一次真实对话 + 拔线重连不丢状态。
//
// 用法(活体靶机必须在跑):
//   dart run bin/live_chat_smoke.dart
//
// 步骤:describe → createSession → promptText(真实 LLM 轮)→
// 等 user/message + assistant/message 经 mux 回流 → 拔线(debug hook)→
// 新代 ready → 验证日志/列表仍在。
// 会在活体主机上留下一个真实会话(singleman-smoke-*);这是验收的成本。
import 'dart:async';
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/event_text.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

const base = 'http://127.0.0.1:3080';
const promptText =
    '这是一次自动化连通性验收(singleman 客户端)。请只回复这五个词:SMOKE OK FROM DSH,不要做任何其他事。';

Future<void> main() async {
  final uri = Uri.parse(base);
  final api = ApiClient(baseUri: uri);
  final connection = ConnectionController(
    baseUri: uri,
    initialBackoff: const Duration(milliseconds: 300),
    maxBackoff: const Duration(seconds: 3),
  );
  final store = SessionStore(api: api, connection: connection);
  connection.start();
  store.start();

  // 1. 就绪握手
  final ready1 = await connection.snapshots
      .firstWhere((s) => s.phase == ConnectionPhase.ready)
      .timeout(const Duration(seconds: 10));
  print('READY gen=' + ready1.generation.toString() +
      ' host=' + (ready1.describe?.version ?? '?') +
      ' provider=' + (ready1.describe?.provider ?? '?') +
      ' model=' + (ready1.describe?.model ?? '?'));

  // 2. 新建会话
  final created = await store.createSession();
  final sessionId = created.sessionId;
  print('CREATED ' + sessionId);

  // 3. 发送真实 prompt
  final sent = await store.promptText(sessionId, promptText, clientTimeZone: 'UTC');
  print('PROMPT accepted=' + sent.accepted.toString());

  // 4. 等对话回流(user/message 与 assistant/message 都要经 mux 到达)
  final log = store.logFor(sessionId);
  var sawUser = false;
  var assistantText = '';
  final deadline = DateTime.now().add(const Duration(seconds: 180));
  final sub = log.eventStream.listen((events) {
    for (final e in events) {
      if (e.type == 'user/message' && extractText(e.data).contains('自动化连通性验收')) {
        sawUser = true;
      }
      if (e.type == 'assistant/message') {
        final t = extractText(e.data);
        if (t.isNotEmpty) assistantText = t;
      }
    }
  });
  // 初始 user 帧可能先于订阅到达 —— 手动扫一遍现有日志。
  for (final e in log.events) {
    if (e.type == 'user/message' && extractText(e.data).contains('自动化连通性验收')) sawUser = true;
  }
  while (!(sawUser && assistantText.isNotEmpty) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  await sub.cancel();
  if (!sawUser) {
    stderr.writeln('FAIL: user/message never echoed via mux');
    await _shutdown(api, connection, store);
    exitCode = 1;
    return;
  }
  print('USER-ECHO ok');
  print('ASSISTANT: ' + (assistantText.isEmpty ? '(empty)' : assistantText.replaceAll('\n', ' | ').substring(0, assistantText.length > 300 ? 300 : assistantText.length)));
  if (assistantText.isEmpty) {
    stderr.writeln('FAIL: assistant/message never arrived');
    await _shutdown(api, connection, store);
    exitCode = 1;
    return;
  }

  // 5. 拔线重连:日志条数先记录
  final eventsBefore = log.events.length;
  final genBefore = connection.current?.generation ?? 0;
  await connection.debugDropDownlinks();
  final downSnap = await connection.snapshots
      .firstWhere((s) => s.phase == ConnectionPhase.down)
      .timeout(const Duration(seconds: 5));
  print('DOWN gen=' + downSnap.generation.toString() + ' reason=' + (downSnap.failureReason ?? '?'));
  final ready2 = await connection.snapshots
      .firstWhere((s) => s.phase == ConnectionPhase.ready && s.generation > genBefore)
      .timeout(const Duration(seconds: 15));
  print('RE-READY gen=' + ready2.generation.toString());
  // 重连后:列表重取 + 日志不丢
  final deadline2 = DateTime.now().add(const Duration(seconds: 10));
  while (connection.current?.describe == null && DateTime.now().isBefore(deadline2)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final logsAfter = log.events.length;
  print('EVENTS before=' + eventsBefore.toString() + ' after=' + logsAfter.toString());
  if (logsAfter < eventsBefore) {
    stderr.writeln('FAIL: event log shrank after reconnect');
    exitCode = 1;
  } else {
    print('SMOKE-PASS');
  }
  await _shutdown(api, connection, store);
}

Future<void> _shutdown(ApiClient api, ConnectionController connection, SessionStore store) async {
  await store.dispose();
  await connection.dispose();
  api.dispose();
}
