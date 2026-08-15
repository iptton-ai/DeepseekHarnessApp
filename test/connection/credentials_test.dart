// 凭证存储测试(M6):文件往返/损坏兜底/内存实现。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/credentials_path.dart';

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

  test('file store roundtrips remote credentials with token', () async {
    final store = FileCredentialStore(path: path);
    await store.save(StoredCredentials(
      baseUri: Uri.parse('https://dsh.example.com'),
      token: 'tok-123',
    ));
    final loaded = await store.load();
    expect(loaded!.baseUri, Uri.parse('https://dsh.example.com'));
    expect(loaded.token, 'tok-123');
  });

  test('file store roundtrips loopback credentials without token', () async {
    final store = FileCredentialStore(path: path);
    await store.save(
      StoredCredentials(baseUri: Uri.parse('http://127.0.0.1:3080')),
    );
    final loaded = await store.load();
    expect(loaded!.baseUri, Uri.parse('http://127.0.0.1:3080'));
    expect(loaded.token, isNull);
  });

  test('missing file yields null', () async {
    final store = FileCredentialStore(path: path);
    expect(await store.load(), isNull);
  });

  test('corrupted file yields null (re-login path, no crash)', () async {
    await File(path).writeAsString('{not json');
    final store = FileCredentialStore(path: path);
    expect(await store.load(), isNull);
  });

  test('clear deletes stored credentials', () async {
    final store = FileCredentialStore(path: path);
    await store.save(StoredCredentials(
      baseUri: Uri.parse('https://dsh.example.com'),
      token: 't',
    ));
    await store.clear();
    expect(await store.load(), isNull);
  });

  test('memory store mirrors file contract', () async {
    final store = MemoryCredentialStore();
    expect(await store.load(), isNull);
    await store.save(StoredCredentials(
      baseUri: Uri.parse('https://dsh.example.com'),
      token: 'tok',
    ));
    expect((await store.load())!.token, 'tok');
    await store.clear();
    expect(await store.load(), isNull);
  });
}
