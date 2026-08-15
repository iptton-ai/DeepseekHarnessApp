// 连接配置页(M4 LAN 形态,ADR-0004;M6 增远程网关形态):
// - 桌面同机:直接进主界面(loopback 3080,全功能)
// - 手机 LAN:先输入主机地址(必须 --host <具体IP> + --trusted-host 启动的 dsh)
// - 手机公网:经 dsh.example.com 网关(密码登录 + 设备令牌;M6)
// - 特权围栏:非 loopback 且非已鉴权远程时,按 host.describe 能力隐藏特权面
//   (方法级 403 由服务端把关,客户端只做 UI 隐藏 —— DSH-PROTOCOL §6:可达性策略不是认证)
import 'package:flutter/material.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 特权面可见性:loopback 或「经网关鉴权的远程」连接可见。
class PrivilegeScope {
  const PrivilegeScope({required this.isLoopback, this.authenticatedRemote = false});
  final bool isLoopback;

  /// 远程网关形态(dsh-gateway 登录持有令牌):dsh 侧经隧道 + Host 改写
  /// 呈现为 loopback,特权方法实际可用。
  final bool authenticatedRemote;

  /// 特权方法 UI(settings/credentials/pickDirectory/openPath/agentPreset 写面)。
  bool get showPrivilegedPanels => isLoopback || authenticatedRemote;
}

/// 从连接目标推断 loopback(127.0.0.1/localhost/[::1])。
PrivilegeScope scopeFor(Uri baseUri, {bool authenticatedRemote = false}) {
  final h = baseUri.host.toLowerCase();
  return PrivilegeScope(
    isLoopback: h == '127.0.0.1' || h == 'localhost' || h == '[::1]' || h == '::1',
    authenticatedRemote: authenticatedRemote,
  );
}

/// 连接配置对话框:输入 http(s)://host:port。
Future<Uri?> showConnectDialog(BuildContext context, {String? initial}) {
  final controller = TextEditingController(text: initial ?? 'http://127.0.0.1:3080');
  return showDialog<Uri>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('连接 DSH 主机'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'http://192.168.1.10:3080',
          helperText: 'LAN 主机需 dsh web --host <IP> --trusted-host <authority>',
          isDense: true,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final parsed = Uri.tryParse(controller.text.trim());
            if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
              Navigator.pop(context, parsed);
            }
          },
          child: const Text('连接'),
        ),
      ],
    ),
  );
}

/// 非特权模式下的占位(特权面板被隐藏时显示)。
class PrivilegeHidden extends StatelessWidget {
  const PrivilegeHidden({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(12),
        child: Row(children: [
          Icon(Icons.lock_outline, size: 16),
          SizedBox(width: 6),
          Text('此功能仅在桌面同机(loopback)形态可用', style: TextStyle(fontSize: 12)),
        ]),
      );
}
