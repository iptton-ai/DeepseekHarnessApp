// 捕获真实 session/queue 帧:建会话 → 连发两条 prompt(第一条占用 turn,
// 第二条落队列)→ 抓 mux queue 帧 → 落 fixtures/ws/queue-frames.jsonl。
// 用法: dart run tool/codegen/capture_queue.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

Future<void> main() async {
  final uri = Uri.parse('http://127.0.0.1:3080');
  final api = ApiClient(baseUri: uri);
  final connection = ConnectionController(
    baseUri: uri,
    initialBackoff: const Duration(milliseconds: 300),
    maxBackoff: const Duration(seconds: 3),
  );
  final queueFrames = <Map<String, dynamic>>[];
  final sub = connection.muxFrames.listen((f) {
    if (f is MuxFrameSessionQueue) {
      queueFrames.add(f.toJson());
    }
  });
  connection.start();
  await connection.snapshots
      .firstWhere((s) => s.phase == ConnectionPhase.ready)
      .timeout(const Duration(seconds: 10));

  final created = await api.call(
    RpcMethods.sessionCreate,
    <String, dynamic>{},
    parse: SessionCreateValue.fromJson,
  );
  final sid = created.sessionId;
  print('session=' + sid);

  Future<Map<String, dynamic>> prompt(String text) => api.call(
        RpcMethods.sessionPrompt,
        <String, dynamic>{
          'sessionId': sid,
          'mode': 'queue',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'clientTimeZone': 'UTC',
        },
        parse: (j) => j,
      );

  // 两条消息背靠背:第一条被认领进 turn,第二条必然落队列(冷会话 FIFO 语义)。
  await prompt('请开始慢慢数数,从1数到20,每个数一行,不要做别的。');
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await prompt('数完之后,请总结你数了几个数。一句话即可。');

  // 等队列帧出现(入队即推快照)。
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (queueFrames.isEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  await sub.cancel();
  if (queueFrames.isEmpty) {
    stderr.writeln('no queue frame captured (host may have consumed both prompts into one turn)');
    await connection.dispose();
    api.dispose();
    exitCode = 1;
    return;
  }
  final f = File('fixtures/ws/queue-frames.jsonl');
  f.writeAsStringSync(queueFrames.map((q) => jsonEncode({'capturedAt': DateTime.now().toIso8601String(), 'frame': {
    'type': 'server-request',
    'rpcId': 'captured-queue',
    'method': 'session/queue',
    'payload': q,
  }})).join('\n') + '\n');
  print('captured ' + queueFrames.length.toString() + ' queue frame(s) -> fixtures/ws/queue-frames.jsonl');
  await connection.dispose();
  api.dispose();
}
