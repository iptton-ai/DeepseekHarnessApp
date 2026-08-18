// HostCoordinator 测试(方案 A 多主机):adopt/switchTo/remove 的簿演化、
// 持久化落盘与 ValueNotifier 通知;remove 的网关令牌吊销(best-effort)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/host_book.dart';
import 'package:singleman/connection/remote_auth.dart';

/// 无填充 base64url(JWT 段形态)。
String _b64(Object json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

/// 三段式假 JWT(只求载荷可解析,签名段随便填)。
String _jwt({required String jti}) =>
    '${_b64({'alg': 'HS256', 'typ': 'JWT'})}.${_b64({'jti': jti, 'exp': 9999999999})}.sig';

RemoteLoginSuccess _success(Uri base, String token,
        {String label = '', String hostRef = ''}) =>
    RemoteLoginSuccess(
        baseUri: base, token: token, hostLabel: label, hostRef: hostRef);

void main() {
  late MemoryCredentialStore store;
  late HostCoordinator hosts;

  setUp(() {
    store = MemoryCredentialStore();
    hosts = HostCoordinator(store);
  });

  test('hydrate 从 store 载入簿(读失败按空簿)', () async {
    store.seed(HostBook(hosts: [
      StoredCredentials(
          id: 'https://a.example.com:443',
          baseUri: Uri.parse('https://a.example.com'),
          token: 't'),
    ]));
    await hosts.hydrate();
    expect(hosts.book.value.hosts.length, 1);
  });

  test('adopt:新网关追加并激活;同网关重复配对原地刷新不重复', () async {
    final a = await hosts.adopt(
        _success(Uri.parse('https://a.example.com'), 't1', label: 'MacA'));
    expect(a.id, 'https://a.example.com:443');
    expect(hosts.book.value.activeId, a.id);
    expect((await store.load()).hosts.length, 1, reason: '变更即持久化');

    final again = await hosts.adopt(
        _success(Uri.parse('https://A.example.com:443'), 't1-new', label: 'MacA改'));
    expect(hosts.book.value.hosts.length, 1, reason: '归一化同 id,原地刷新');
    expect(again.token, 't1-new');
    expect(again.hostLabel, 'MacA改');

    await hosts.adopt(_success(Uri.parse('https://b.example.com'), 't2'));
    expect(hosts.book.value.hosts.length, 2);
    expect(hosts.book.value.active!.baseUri, Uri.parse('https://b.example.com'));
  });

  group('多宿主复合键(同网关多宿主,2026-08-18)', () {
    final gw = Uri.parse('https://gw.example.com');

    test('hostRef 不同 = 不同条目;同 hostRef 重配 = 原地刷新', () async {
      await hosts.adopt(_success(gw, 't1', label: 'MacA', hostRef: '13110'));
      await hosts.adopt(_success(gw, 't2', label: 'MacB', hostRef: '13111'));
      expect(hosts.book.value.hosts.length, 2, reason: '同网关两宿主各自成条');
      expect(
        hosts.book.value.hosts.map((h) => h.hostRef).toSet(),
        {'13110', '13111'},
      );

      final again = await hosts.adopt(
          _success(gw, 't1-new', label: 'MacA改', hostRef: '13110'));
      expect(hosts.book.value.hosts.length, 2, reason: '同宿主原地刷新');
      expect(again.token, 't1-new');
      expect(again.hostLabel, 'MacA改');
    });

    test('无 hostRef(旧网关)= 裸网关地址旧语义', () async {
      final a = await hosts.adopt(_success(gw, 't'));
      expect(a.id, 'https://gw.example.com:443');
    });

    test('复合键条目取代同网关 legacy 条目(升级迁移)', () async {
      // 先以旧形态(无 host_ref)配过一次 —— id = 裸网关地址。
      await hosts.adopt(_success(gw, 't-old', label: 'MacA'));
      expect(hosts.book.value.hosts.single.id, 'https://gw.example.com:443');

      // 网关升级后重配同宿主:带 host_ref → 复合键新条目 + legacy 条目移除。
      await hosts.adopt(_success(gw, 't-new', label: 'MacA', hostRef: '13110'));
      expect(hosts.book.value.hosts.length, 1);
      expect(hosts.book.value.hosts.single.id, 'https://gw.example.com:443#13110');
      expect(hosts.book.value.hosts.single.token, 't-new');

      // 再配第二台宿主:legacy 条目已不存在,纯新增。
      await hosts.adopt(_success(gw, 't-b', label: 'MacB', hostRef: '13111'));
      expect(hosts.book.value.hosts.length, 2);
      expect(hosts.book.value.hosts.any((h) => h.id == 'https://gw.example.com:443'),
          false);
    });

    test('复合键持久化:hostRef 随簿落盘,重载后 id 稳定', () async {
      await hosts.adopt(_success(gw, 't1', hostRef: '13110'));
      final reloaded = MemoryCredentialStore()..seed(await store.load());
      final book = await reloaded.load();
      expect(book.hosts.single.hostRef, '13110');
      expect(book.hosts.single.id, 'https://gw.example.com:443#13110');
    });
  });

  test('switchTo:指针切换 + 通知;unknown id 簿不变', () async {
    await hosts.adopt(_success(Uri.parse('https://a.example.com'), 't1'));
    await hosts.adopt(_success(Uri.parse('https://b.example.com'), 't2'));
    expect(hosts.book.value.active!.id, 'https://b.example.com:443');

    var notified = 0;
    hosts.book.addListener(() => notified++);
    final target = await hosts.switchTo('https://a.example.com:443');
    expect(target!.id, 'https://a.example.com:443');
    expect((await store.load()).activeId, 'https://a.example.com:443');
    expect(notified, 1);

    final untouched = await hosts.switchTo('https://nope.example.com:443');
    expect(untouched!.id, 'https://a.example.com:443');
    expect(notified, 1, reason: '无效切换不触发通知');
  });

  test('remove:删非活动条目不动连接;删活动条目滑到剩余首条;删空得 null', () async {
    await hosts.adopt(_success(Uri.parse('https://a.example.com'), 't1'));
    await hosts.adopt(_success(Uri.parse('https://b.example.com'), 't2'));
    final aId = 'https://a.example.com:443', bId = 'https://b.example.com:443';

    final stillB = await hosts.remove(aId);
    expect(stillB!.id, bId);
    expect((await store.load()).hosts.length, 1);

    final none = await hosts.remove(bId);
    expect(none, isNull);
    expect((await store.load()).hosts, isEmpty);
  });

  group('remove 吊销网关令牌', () {
    test('网关主机:POST /auth/revoke 带 Bearer 与解析出的 jti', () async {
      final gateway = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => gateway.close(force: true));
      final token = _jwt(jti: 'jti-abc-123');
      final got = Completer<Map<String, dynamic>>();
      final serve = () async {
        await for (final req in gateway) {
          if (req.uri.path == '/auth/revoke') {
            final body = await utf8.decoder.bind(req).join();
            if (!got.isCompleted) {
              got.complete({
                'auth': req.headers.value(HttpHeaders.authorizationHeader),
                'body': body,
              });
            }
            req.response.statusCode = 200;
          } else {
            req.response.statusCode = 404;
          }
          await req.response.close();
        }
      }();
      // 循环随 gateway.close 结束;teardown 绝不 await 它(永不完成会挂死)。
      serve.ignore();

      final base = Uri.parse('http://127.0.0.1:${gateway.port}');
      final entry = await hosts.adopt(_success(base, token, label: 'gw'));
      await hosts.remove(entry.id);

      final info = await got.future.timeout(const Duration(seconds: 3));
      expect(info['auth'], 'Bearer $token');
      expect(jsonDecode(info['body'] as String), {'jti': 'jti-abc-123'});
      expect(hosts.book.value.hosts, isEmpty, reason: '删除不受吊销影响');
      await Future<void>.delayed(Duration.zero);
      expect(hosts.lastRevokeOutcome, TokenRevokeOutcome.revoked);
    });

    test('非 JWT 令牌/空令牌:跳过网络调用,不报错', () async {
      await hosts.adopt(_success(Uri.parse('https://a.example.com'), 't1'));
      await hosts.remove('https://a.example.com:443');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(hosts.lastRevokeOutcome, TokenRevokeOutcome.skipped);

      // loopback 直连条目(无令牌)同样跳过。
      store.seed(HostBook(hosts: [
        StoredCredentials(
            id: 'http://127.0.0.1:3080',
            baseUri: Uri.parse('http://127.0.0.1:3080')),
      ]));
      await hosts.hydrate();
      await hosts.remove('http://127.0.0.1:3080');
      await Future<void>.delayed(Duration.zero);
      expect(hosts.lastRevokeOutcome, TokenRevokeOutcome.skipped,
          reason: 'loopback 直连条目无令牌');
    });
  });

  group('jtiFromJwt', () {
    test('解析 jti(各 base64 填充形态)', () {
      expect(jtiFromJwt(_jwt(jti: 'x-y-z')), 'x-y-z');
      // 手工构造 %4==2/3/0 的载荷长度形态。
      expect(jtiFromJwt('${_b64({'a': 1})}.${_b64({'jti': 'p2'})}.s'), 'p2');
      expect(jtiFromJwt('${_b64({'a': 1})}.${_b64({'jti': 'p3x'})}.s'), 'p3x');
      expect(jtiFromJwt('${_b64({'a': 1})}.${_b64({'jti': 'pad0'})}.s'), 'pad0');
    });

    test('垃圾输入与无 jti 载荷返回 null', () {
      expect(jtiFromJwt('t1'), isNull);
      expect(jtiFromJwt('a.b'), isNull);
      expect(jtiFromJwt('..'), isNull);
      expect(jtiFromJwt('${_b64({'a': 1})}.${_b64({'nojti': 1})}.s'), isNull);
    });
  });
}
