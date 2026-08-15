// M6 验收冒烟:经 dsh-gateway(鉴权中转)完成一次真实对话。
//
// 用法(gateway 与活体 dsh 都在跑):
//   dart run bin/live_remote_smoke.dart [gatewayBase] [password]
// 默认 gatewayBase=http://127.0.0.1:8199 password=debug-pw(本地联调姿态)。
//
// 步骤:login(密码→令牌)→ 描述/WS 全部带 Bearer → createSession →
// promptText(经网关的真实 LLM 轮)→ 等 assistant/message 回流 → 断言
// 网关侧确实校验了头(无令牌 401)。AUTH-SMOKE-PASS 为验收通过。
import 'dart:async';
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/connection/remote_auth.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

const promptText =
    '这是一次自动化连通性验收(singleman 远程网关链路)。请只回复这五个词:SMOKE OK FROM GATEWAY,不要做任何其他事。';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isNotEmpty ? args[0] : 'http://127.0.0.1:8199');
  final password = args.length > 1 ? args[1] : 'debug-pw';

  // 0. 未授权访问必须被拒(网关鉴权在位证明)。
  final anon = ApiClient(baseUri: base);
  try {
    await anon.call(RpcMethods.hostDescribe, <String, dynamic>{},
        parse: HostDescribeValue.fromJson,
        timeout: const Duration(seconds: 5));
    print('AUTH-SMOKE-FAIL: anonymous describe was not rejected');
    exit(1);
  } on CarrierError catch (e) {
    if (e.httpStatus != 401) {
      print('AUTH-SMOKE-FAIL: expected 401, got ${e.httpStatus}');
      exit(1);
    }
    print('REJECTED-ANON 401 OK');
  } finally {
    anon.dispose();
  }

  // 1. 密码登录 → 设备令牌。
  final auth = RemoteAuthClient();
  final login = await auth.login(base, password, device: 'live-remote-smoke');
  print('LOGIN-OK token ${login.token.length} chars');
  final tokens = MutableTokenProvider(login.token);

  // 2. 带令牌装配(与 main.dart 同构:authHeaders 注入 HTTP + 双 WS)。
  final api = ApiClient(baseUri: base, authHeaders: tokens.authHeaders);
  final connection = ConnectionController(
    baseUri: base,
    authHeaders: tokens.authHeaders,
    initialBackoff: const Duration(milliseconds: 300),
    maxBackoff: const Duration(seconds: 3),
  );
  final store = SessionStore(api: api, connection: connection);
  connection.start();
  store.start();

  final ready = await connection.snapshots
      .firstWhere((s) => s.phase == ConnectionPhase.ready)
      .timeout(const Duration(seconds: 10));
  print('READY-THROUGH-GATEWAY gen=' +
      ready.generation.toString() +
      ' host=' +
      (ready.describe?.version ?? '?'));

  // 3. 新建会话 + 真实 prompt(全部经网关中转)。
  final created = await store.createSession();
  print('CREATED ' + created.sessionId);
  await store.promptText(created.sessionId, promptText, clientTimeZone: 'UTC');

  // 4. 等对话回流(mux 经网关 WS;与 live_chat_smoke 同构的日志订阅)。
  final log = store.logFor(created.sessionId);
  var sawAssistant = false;
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  final sub = log.eventStream.listen((events) {
    for (final e in events) {
      if (e.type == 'assistant/message') sawAssistant = true;
    }
  });
  while (!sawAssistant && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  await sub.cancel();
  if (!sawAssistant) {
    print('AUTH-SMOKE-FAIL: no assistant message through gateway');
    exit(1);
  }

  print('AUTH-SMOKE-PASS: login + relay(HTTP/WS) + real turn through gateway');
  await connection.dispose();
  auth.dispose();
  exit(0);
}
