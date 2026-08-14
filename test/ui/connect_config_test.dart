// LAN 形态:loopback 推断 + 特权面隐藏逻辑。
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/ui/connect_config.dart';

void main() {
  test('loopback detection', () {
    expect(scopeFor(Uri.parse('http://127.0.0.1:3080')).isLoopback, isTrue);
    expect(scopeFor(Uri.parse('http://localhost:3080')).isLoopback, isTrue);
    expect(scopeFor(Uri.parse('http://192.168.1.10:3080')).isLoopback, isFalse);
    expect(scopeFor(Uri.parse('http://10.0.0.5:3080')).isLoopback, isFalse);
  });

  test('privileged panels only on loopback', () {
    expect(scopeFor(Uri.parse('http://127.0.0.1:3080')).showPrivilegedPanels, isTrue);
    expect(scopeFor(Uri.parse('http://192.168.1.10:3080')).showPrivilegedPanels, isFalse);
  });
}
