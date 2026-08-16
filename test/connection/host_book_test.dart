// HostCoordinator 测试(方案 A 多主机):adopt/switchTo/remove 的簿演化、
// 持久化落盘与 ValueNotifier 通知。
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/host_book.dart';
import 'package:singleman/connection/remote_auth.dart';

RemoteLoginSuccess _success(Uri base, String token, {String label = ''}) =>
    RemoteLoginSuccess(baseUri: base, token: token, hostLabel: label);

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
}
