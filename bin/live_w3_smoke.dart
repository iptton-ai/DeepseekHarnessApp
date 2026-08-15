// live_w3_smoke.dart — W3 冒烟:workspace 域 + 远程端点(commands/pluginInventory)+ settings 只读面。
// 用法:dart run bin/live_w3_smoke.dart(需活体 3080;直连 client 避开系统代理坑,见 PROGRESS)
// 信封事实(PROTOCOL §9):commands/list result.value=裸数组;pluginInventory=普通 Map;
// 仅 RemoteResult 端点(messageFeedback/goals)才双层。ApiClient.call 会把非 Map value 折成 {},
// 故远程端点在本脚本内直呼 rawFetch。
import 'dart:convert';
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

const base = 'http://127.0.0.1:3080';

var _failed = false;

void check(String name, bool ok, [String detail = '']) {
  stdout.writeln((ok ? 'PASS ' : 'FAIL ') + name + (detail.isEmpty ? '' : ' ' + detail));
  if (!ok) _failed = true;
}

/// 远程端点 raw 直呼:成功返回 result.value 原样(数组或 Map),业务错误抛 RpcBusinessError。
Future<dynamic> remoteRaw(String method, Map<String, dynamic> args) async {
  final client = createDirectHttpClient();
  try {
    final req = await client.postUrl(Uri.parse(base + '/api/' + method))
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<String, dynamic>{
        'type': 'client-request',
        'rpcId': 'w3-' + DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        'method': method,
        'payload': {'args': args},
      }));
    final body = await (await req.close()).transform(utf8.decoder).join();
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final result = decoded['result'] as Map<String, dynamic>;
    if (result['ok'] == true) return result['value'];
    final err = RpcError.fromJson(result['error'] as Map<String, dynamic>);
    throw RpcBusinessError(err);
  } finally {
    client.close();
  }
}

Future<void> main() async {
  final api = ApiClient(baseUri: Uri.parse(base));

  // 1. workspace.list(W1-A 面)
  final ws = await api.call(
    RpcMethods.workspaceList,
    const <String, dynamic>{},
    parse: WorkspaceListValue.fromJson,
  );
  check('WORKSPACE-LIST', ws.items.isNotEmpty, 'groups=' + ws.items.length.toString());

  // 2. session.create + commands/list(W2-D;根会话)
  final sid = (await api.call(
    RpcMethods.sessionCreate,
    const <String, dynamic>{},
    parse: SessionCreateValue.fromJson,
  )).sessionId;
  check('SESSION-CREATE', sid.isNotEmpty);
  final cmds = await remoteRaw('commands/list', {'agentId': sid});
  check('COMMANDS-LIST', cmds is List && cmds.isNotEmpty,
      'count=' + (cmds is List ? cmds.length : -1).toString());

  // 3. pluginInventory(只读清单)
  final inv = await remoteRaw('pluginInventory/list', const <String, dynamic>{});
  final entries = inv is Map ? inv['entries'] : null;
  check('PLUGIN-INVENTORY', entries is List && entries.isNotEmpty,
      'entries=' + (entries is List ? entries.length.toString() : '-1'));

  // 4. settings.describe 只读(loopback;W1-D)
  try {
    await api.call<Map<String, dynamic>?>(
      RpcMethods.settingsDescribe,
      const <String, dynamic>{
        'namespaces': ['permission'],
      },
      parse: (json) => json,
    );
    check('SETTINGS-DESCRIBE', true);
  } on RpcBusinessError catch (e) {
    check('SETTINGS-DESCRIBE', false, e.toString());
  }

  stdout.writeln(_failed ? 'W3-SMOKE-FAIL' : 'W3-SMOKE-PASS');
  // 显式退出:dart run 关闭期的 telemetry 写入(沙箱 EPERM)会污染 Zone exitCode。
  exit(_failed ? 1 : 0);
}
