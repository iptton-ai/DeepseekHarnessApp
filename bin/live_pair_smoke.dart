// M6.1 验收冒烟:配对全流程(本地 dsh-gateway:公开 8199 / 管理 8203)。
//
// 前置(本地联调姿态):
//   cd <gateway-repo> && DSH_GATEWAY_JWT_SECRET=devsecret DSH_GATEWAY_PORT=8199 \
//   DSH_GATEWAY_ADMIN_PORT=8203 DSH_GATEWAY_UPSTREAM=127.0.0.1:3080 \
//   DSH_GATEWAY_TUNNEL_PORT_MIN=1024 DSH_GATEWAY_DATABASE=/tmp/dshgw-pair.db \
//   ./target/debug/dsh-gateway &
//
// 步骤:pairStart(手机角色,亮码)→ 本脚本同时扮演 Mac(直接打管理口 claim,
// 相当于 pair.sh 的 ssh+curl)→ poll 拿 offers → confirm(人工比对的机器等价)
// → 用令牌经网关 describe(打到真 dsh)→ 顺带断言「无令牌 401」与
// 「令牌绑定端口路由」。PAIR-SMOKE-PASS 为验收通过。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/pairing.dart';
import 'package:singleman/connection/remote_auth.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

const kGateway = 'http://127.0.0.1:8199';
const kAdmin = 'http://127.0.0.1:8203';
const kDshPort = 3080;

Future<Map<String, dynamic>> _post(String url, Map<String, dynamic> body) async {
  final client = HttpClient()..findProxy = directProxy;
  final req = await client.postUrl(Uri.parse(url));
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode(body));
  final res = await req.close();
  final text = await res.transform(utf8.decoder).join();
  client.close();
  if (res.statusCode != 200) {
    throw StateException('HTTP ${res.statusCode}: $text');
  }
  return jsonDecode(text) as Map<String, dynamic>;
}

class StateException implements Exception {
  StateException(this.msg);
  final String msg;
  @override
  String toString() => msg;
}

Future<void> main() async {
  final auth = RemoteAuthClient();

  // 0. 匿名访问必须被拒。
  final anon = ApiClient(baseUri: Uri.parse(kGateway));
  try {
    await anon.call(RpcMethods.hostDescribe, <String, dynamic>{},
        parse: HostDescribeValue.fromJson,
        timeout: const Duration(seconds: 5));
    print('PAIR-SMOKE-FAIL: anonymous describe was not rejected');
    exit(1);
  } on CarrierError catch (e) {
    if (e.httpStatus != 401) {
      print('PAIR-SMOKE-FAIL: expected 401, got ${e.httpStatus}');
      exit(1);
    }
    print('REJECTED-ANON 401 OK');
  } finally {
    anon.dispose();
  }

  // 1. 手机角色:发起配对(亮码)。
  final session = await auth.pairStart(Uri.parse(kGateway), device: 'pair-smoke');
  print('PHONE-CODE ${session.displayCode}');

  // 2. Mac 角色:亮主机码并 claim(本地直连管理口 = pair.sh 的 ssh 路径)。
  const hostCode = 'SMKY72';
  final claim = await _post('$kAdmin/admin/pair/claim', {
    'code': session.code,
    'host_code': hostCode,
    'host_label': 'smoke-mac',
    'port': kDshPort, // 本地联调:直接绑 3080(生产为 131xx 隧道口)
  });
  print('MAC-CLAIM host_code=$hostCode device=${claim['device']}');

  // 3. 手机角色:轮询 offers(应看到刚登记的)。
  var offers = const <PairOfferView>[];
  for (var i = 0; i < 5; i++) {
    final poll = await auth.pairPoll(session);
    if (poll.status == PairPollStatus.offers) {
      offers = poll.offers;
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  if (offers.isEmpty) {
    print('PAIR-SMOKE-FAIL: no offers after claim');
    exit(1);
  }
  final match = offers.where((o) => o.hostCode == hostCode).toList();
  if (match.length != 1) {
    print('PAIR-SMOKE-FAIL: expected exactly 1 offer with $hostCode');
    exit(1);
  }
  print('PHONE-SEES-OFFER ${match.single.displayHostCode} (${match.single.hostLabel})');

  // 3b. 主机码不匹配必须被拒(人工比对的机器等价)。
  final wrong = PairOfferView.fromJson({
    'claim_id': match.single.claimId,
    'host_code': 'WRNG99',
    'host_label': 'evil',
    'upstream_port': kDshPort,
    'expires_at': 1999999999,
  });
  try {
    await auth.pairConfirm(session, wrong);
    print('PAIR-SMOKE-FAIL: mismatched host code was accepted');
    exit(1);
  } on PairingFailure {
    print('MISMATCH-REJECTED OK');
  }

  // 4. 确认(正确主机码)→ 令牌。
  final success = await auth.pairConfirm(session, match.single);
  print('PAIRED token ${success.token.length} chars');

  // 5. 令牌经网关中转到真 dsh(绑定端口路由生效)。
  final tokens = MutableTokenProvider(success.token);
  final api = ApiClient(
    baseUri: Uri.parse(kGateway),
    authHeaders: tokens.authHeaders,
  );
  final describe = await api.call(
    RpcMethods.hostDescribe,
    <String, dynamic>{},
    parse: HostDescribeValue.fromJson,
    timeout: const Duration(seconds: 8),
  );
  print('DESCRIBE-THROUGH-PAIRED-GATEWAY host=${describe.version} '
      'provider=${describe.provider}');
  if (describe.version.isEmpty) {
    print('PAIR-SMOKE-FAIL: describe empty');
    exit(1);
  }

  // 6. 抄码抢注:同码再 start 必须 409(客户端自动换码也是从这里识别)。
  try {
    await _post('${kGateway}pair/start'.replaceFirst('pair/', '/pair/'), {
      'code': session.code,
      'secret': 'squattersecreta1phabet9876543210zyxw',
      'device': 'squatter',
    });
    print('PAIR-SMOKE-FAIL: duplicate live code was accepted');
    exit(1);
  } on StateException catch (e) {
    if (!e.msg.contains('409')) {
      print('PAIR-SMOKE-FAIL: expected 409, got ${e.msg}');
      exit(1);
    }
    print('SQUAT-REJECTED 409 OK');
  }

  auth.dispose();
  print('PAIR-SMOKE-PASS: pair flow + mutual code check + port-bound routing');
  exit(0);
}
