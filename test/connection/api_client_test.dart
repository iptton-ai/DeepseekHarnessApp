// ApiClient 故障注入测试(打假主机,不打活体 3080)。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

import '../helpers/fake_dsh_host.dart';

void main() {
  late FakeDshHost host;
  late ApiClient client;

  setUp(() async {
    host = await FakeDshHost.start();
    client = ApiClient(baseUri: host.baseUri);
  });

  tearDown(() async {
    client.dispose();
    await host.stop();
  });

  test('direct proxy policy is DIRECT for every target', () {
    // findProxy 只有 setter 在公开接口,策略函数独立导出供测试。
    expect(directProxy(Uri.parse('http://127.0.0.1:3080')), 'DIRECT');
    expect(directProxy(Uri.parse('http://192.168.1.10:3080')), 'DIRECT');
    final client = createDirectHttpClient();
    client.close();
  });

  test('describe round trip: envelope + typed value', () async {
    final value = await client.call(
      RpcMethods.hostDescribe,
      <String, dynamic>{},
      parse: HostDescribeValue.fromJson,
    );
    expect(value.version, '0.0.1-fake');
    expect(value.cwd, '/tmp/fake');
    expect(value.canOpenPath, isFalse);
  });

  test('business error folds into RpcBusinessError(RpcErrorBadRequest)', () async {
    host.businessError = true;
    await expectLater(
      client.call(RpcMethods.hostDescribe, <String, dynamic>{}, parse: HostDescribeValue.fromJson),
      throwsA(isA<RpcBusinessError>()
          .having((e) => e.error, 'error', isA<RpcErrorBadRequest>())),
    );
  });

  test('rpcId mismatch folds into CarrierError', () async {
    host.wrongRpcIdEcho = true;
    await expectLater(
      client.call(RpcMethods.hostDescribe, <String, dynamic>{}, parse: HostDescribeValue.fromJson),
      throwsA(isA<CarrierError>().having((e) => e.reason, 'reason', contains('rpcId'))),
    );
  });

  test('unary timeout folds into ApiTimeout', () async {
    host.hangDescribe = true;
    await expectLater(
      client.call(
        RpcMethods.hostDescribe,
        <String, dynamic>{},
        parse: HostDescribeValue.fromJson,
        timeout: const Duration(milliseconds: 150),
      ),
      throwsA(isA<ApiTimeout>()),
    );
  });

  test('host unreachable folds into CarrierError or ApiTimeout (never leaks)', () async {
    // Dart HttpClient 对连接失败有内部重试:refused 可能以超时形态浮出。
    // 纪律是「不泄漏原始异常、不假装成功」——两种折叠都可接受。
    final tmp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = tmp.port;
    await tmp.close();
    final dead = ApiClient(baseUri: Uri.parse('http://127.0.0.1:' + deadPort.toString()));
    try {
      await expectLater(
        dead.call(RpcMethods.hostDescribe, <String, dynamic>{}, parse: HostDescribeValue.fromJson,
            timeout: const Duration(seconds: 2)),
        throwsA(anyOf(isA<CarrierError>(), isA<ApiTimeout>())),
      );
    } finally {
      dead.dispose();
    }
  });
}
