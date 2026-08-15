// LAN/远程形态:loopback 推断 + 特权面可见性(M6:鉴权远程 = 可见)。
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/ui/connect_config.dart';

void main() {
  test('loopback detection', () {
    expect(scopeFor(Uri.parse('http://127.0.0.1:3080')).isLoopback, isTrue);
    expect(scopeFor(Uri.parse('http://localhost:3080')).isLoopback, isTrue);
    expect(scopeFor(Uri.parse('http://192.168.1.10:3080')).isLoopback, isFalse);
    expect(scopeFor(Uri.parse('http://10.0.0.5:3080')).isLoopback, isFalse);
    expect(scopeFor(Uri.parse('https://dsh.example.com')).isLoopback, isFalse);
  });

  test('privileged panels: loopback or authenticated remote', () {
    // 桌面同机:可见(旧语义)。
    expect(scopeFor(Uri.parse('http://127.0.0.1:3080')).showPrivilegedPanels, isTrue);
    // LAN 直连(无鉴权):不可见(旧语义)。
    expect(scopeFor(Uri.parse('http://192.168.1.10:3080')).showPrivilegedPanels, isFalse);
    // 公网网关(密码登录 + 令牌):可见 —— dsh 侧经隧道 + Host 改写呈现为
    // loopback,特权方法实际可用,安全性由网关鉴权把守。
    expect(
      scopeFor(Uri.parse('https://dsh.example.com'),
              authenticatedRemote: true)
          .showPrivilegedPanels,
      isTrue,
    );
    // 网关域名但未鉴权(理论态):不可见。
    expect(
      scopeFor(Uri.parse('https://dsh.example.com')).showPrivilegedPanels,
      isFalse,
    );
  });
}
