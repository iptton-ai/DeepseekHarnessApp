// 切主机整代重装 —— 真 main.boot() ×2 的重挂验证(无网络依赖):
// 还原真实 HttpClient(mock 的 Mocked response 会在 dart:_http 内部产生
// 孤儿错误 future 直接判死测试);真 socket 在 fake-async zone 不推进,
// describe 恒等超时 → 连接停在 connecting,恰是装载态断言的前提。断言:
//   boot#1 → 树挂载 + 装载态 + 头部标签 = A;
//   switchTo(B) + _reboot 复刻(旧连接释放 + boot#2)→ 头部标签 = B +
//   装载态仍在(整树重挂、新代从零装配 —— 若元素树被复用,标签不可能
//   翻转到新代语义)。收尾:释放末代连接(disposed 状态掐断重试链)+
//   推进 fake 时钟排掉 describe 超时计时器。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/host_book.dart';
import 'package:singleman/connection/remote_auth.dart';
import 'package:singleman/main.dart';

/// 空子类 = 默认实现 = 真 HttpClient(flutter_test 的 mock overrides 会连
/// `HttpClient()` 工厂一起换成 Mocked response)。
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  testWidgets('boot×2:切主机 → 整树重挂(头部标签翻转 + 装载态)', (tester) async {
    HttpOverrides.global = _RealHttpOverrides();
    final a = StoredCredentials(
      id: 'http://127.0.0.1:1',
      baseUri: Uri.parse('http://127.0.0.1:1'),
      hostLabel: 'HostA',
    );
    final b = StoredCredentials(
      id: 'http://127.0.0.1:2',
      baseUri: Uri.parse('http://127.0.0.1:2'),
      hostLabel: 'HostB',
    );
    final credStore = MemoryCredentialStore()
      ..seed(HostBook(hosts: [a, b], activeId: a.id));
    final hosts = HostCoordinator(credStore);
    await hosts.hydrate();

    boot(plan: planForBook(hosts.book.value), hosts: hosts, mobileFirst: false);
    await tester.pump();
    await tester.pump();
    expect(find.text('HostA'), findsOneWidget, reason: '首代头部标签');
    expect(find.text('正在加载会话…'), findsOneWidget,
        reason: '连接未就绪 + 空数据 → 装载态');

    // —— 复刻 onSwitchHost:_reboot = 旧连接释放 + 新计划 boot。
    final old = activeConnectionForTest;
    await hosts.switchTo(b.id);
    await old?.dispose();
    boot(plan: planForBook(hosts.book.value), hosts: hosts, mobileFirst: false);
    await tester.pump();
    await tester.pump();

    expect(find.text('HostB'), findsOneWidget, reason: '重挂后头部标签 = 新主机');
    expect(find.text('HostA'), findsNothing, reason: '旧代头部随重挂消失');
    expect(find.text('正在加载会话…'), findsOneWidget,
        reason: '新代从零装配:装载态(而非旧代残留)');

    // 收尾:释放末代连接(disposed 掐断重试链),推进 fake 时钟排掉两代
    // 的 describe(10s)/settings·onboarding(30s)超时计时器 —— 它们的
    // future 完成后 invalidate/加载路径对 disposed 或单次尝试语义均无害。
    await activeConnectionForTest?.dispose();
    await tester.pump(const Duration(seconds: 65));
    await tester.pump(const Duration(seconds: 5));
  });
}
