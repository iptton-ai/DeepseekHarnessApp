// 凭证存储测试(M6 → 方案 A 多主机簿):文件往返/迁移/损坏兜底/簿演化/内存契约。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/credentials_path.dart';

StoredCredentials _host(
  Uri base, {
  String? token,
  String hostLabel = '',
}) =>
    StoredCredentials(
      id: hostIdForBase(base),
      baseUri: base,
      token: token,
      hostLabel: hostLabel,
    );

void main() {
  late Directory tmp;
  late String path;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('singleman-creds');
    path = '${tmp.path}/credentials.json';
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('hostIdForBase 归一化:默认端口折叠,大小写与 path 不参与', () {
    expect(hostIdForBase(Uri.parse('https://dsh.example.com')),
        'https://dsh.example.com:443');
    expect(hostIdForBase(Uri.parse('https://dsh.example.com:443')),
        'https://dsh.example.com:443');
    expect(hostIdForBase(Uri.parse('HTTP://Gw.Example.COM:8443')),
        'http://gw.example.com:8443');
    expect(hostIdForBase(Uri.parse('https://dsh.example.com/relay')),
        'https://dsh.example.com:443');
  });

  test('file store roundtrips host book(两台 + active 指针)', () async {
    final store = FileCredentialStore(path: path);
    await store.save(HostBook(hosts: [
      _host(Uri.parse('https://dsh.example.com'),
          token: 'tok-123', hostLabel: 'devs-MacBook-Pro'),
      _host(Uri.parse('https://gw2.example.com'), token: 'tok-9'),
    ], activeId: hostIdForBase(Uri.parse('https://gw2.example.com'))));
    final loaded = await store.load();
    expect(loaded.hosts.length, 2);
    expect(loaded.active!.baseUri, Uri.parse('https://gw2.example.com'));
    expect(loaded.hosts.first.token, 'tok-123');
    expect(loaded.hosts.first.hostLabel, 'devs-MacBook-Pro');
    // 无 hostLabel/token 的条目往返字段回退。
    expect(loaded.hosts.last.hostLabel, '');
  });

  test('旧单对象文件(M6 形状)读入迁移为一元簿', () async {
    await File(path).writeAsString(
        '{"baseUri":"https://dsh.example.com","token":"tok-old","hostLabel":"旧Mac"}');
    final store = FileCredentialStore(path: path);
    final book = await store.load();
    expect(book.hosts.length, 1);
    expect(book.active!.token, 'tok-old');
    expect(book.active!.hostLabel, '旧Mac');
    expect(book.activeId, book.hosts.first.id);

    // 迁移后再保存 → v2 形状,二次读回不变形。
    await store.save(book);
    final again = await store.load();
    expect(again.hosts.length, 1);
    expect(again.active!.token, 'tok-old');
  });

  test('missing / corrupted file yields empty book (re-login path, no crash)',
      () async {
    final store = FileCredentialStore(path: path);
    expect(await store.load(), const HostBook());
    await File(path).writeAsString('{not json');
    expect((await store.load()).hosts, isEmpty);
  });

  group('HostBook 演化(簿一致性不变式)', () {
    final h1 = _host(Uri.parse('https://a.example.com'), token: 't1');
    final h2 = _host(Uri.parse('https://b.example.com'), token: 't2');

    test('upsert 同 id 原地替换保位,新 id 追加并激活', () {
      final book = HostBook(hosts: [h1, h2], activeId: h1.id);
      final refreshed = h1.copyWith(token: 't1-new', hostLabel: '改名Mac');
      final next = book.upsert(refreshed);
      expect(next.hosts.length, 2, reason: '同网关重复配对不产生重复条目');
      expect(next.hosts.first.token, 't1-new');
      expect(next.activeId, h1.id);

      final h3 = _host(Uri.parse('https://c.example.com'), token: 't3');
      final grown = book.upsert(h3);
      expect(grown.hosts.length, 3);
      expect(grown.active!.id, h3.id, reason: '新配对的主机立即成为活动主机');
    });

    test('remove 活动条目 → 指针滑到剩余首条;删空 → null', () {
      final book = HostBook(hosts: [h1, h2], activeId: h1.id);
      final next = book.remove(h1.id);
      expect(next.hosts.length, 1);
      expect(next.active!.id, h2.id);

      final emptied = next.remove(h2.id);
      expect(emptied.hosts, isEmpty);
      expect(emptied.active, isNull);
    });

    test('withActive 指针失效(unknown id)时簿原样返回', () {
      final book = HostBook(hosts: [h1], activeId: h1.id);
      expect(book.withActive('https://nope.example.com:443'), same(book));
    });

    test('active 指针缺失/失效回落首条(防数据损坏卡死启动)', () {
      expect(HostBook(hosts: [h1, h2]).active!.id, h1.id);
      expect(HostBook(hosts: [h1, h2], activeId: 'gone').active!.id, h1.id);
      expect(const HostBook().active, isNull);
    });
  });

  test('memory store mirrors file contract', () async {
    final store = MemoryCredentialStore();
    expect((await store.load()).hosts, isEmpty);
    store.seed(HostBook(hosts: [_host(Uri.parse('https://dsh.example.com'), token: 'tok')]));
    expect((await store.load()).active!.token, 'tok');
    await store.save(const HostBook());
    expect((await store.load()).hosts, isEmpty);
  });
}

extension on StoredCredentials {
  StoredCredentials copyWith({String? token, String? hostLabel}) =>
      StoredCredentials(
        id: id,
        baseUri: baseUri,
        token: token ?? this.token,
        hostLabel: hostLabel ?? this.hostLabel,
      );
}
