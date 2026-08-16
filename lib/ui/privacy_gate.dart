// OHOS 首启隐私政策门(华为应用市场合规):用户点「同意并继续」前,
// 应用不初始化任何网络连接 —— main() 在 boot()(连接启动)之前先过本门。
// 形态:全屏页 + 不可返回(PopScope 拦截);「不同意」走二次确认 → 退出。
// 政策文本与线上政策页同源(真实地址经 --dart-define 注入,见 privacy_consent.dart);
// 实质变更时升 kPrivacyPolicyVersion(已同意旧版用户重新过门)。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:singleman/connection/privacy_consent.dart';
import 'package:singleman/ui/app_theme.dart';

/// 摘要要点(门页高亮卡;全量文本在下方正文)。
const List<String> _summaryPoints = <String>[
  'DeepSeek Harness(dsh)的开发者终端控制工具,面向程序员',
  '不收集任何数据 —— 无账号、无广告、无统计、无追踪',
  '不提供后台服务与 LLM 服务,服务由你自己连接的宿主提供',
  '点「同意」后才会发起网络连接,连接目标完全由你配置',
];

class _PolicySection {
  const _PolicySection(this.heading, this.paragraphs);
  final String heading;
  final List<String> paragraphs;
}

const List<_PolicySection> _policySections = <_PolicySection>[
  _PolicySection('一、我们如何收集和使用信息', <String>[
    'DshAPP 不收集任何个人信息:无账号系统、无设备标识采集、无统计/广告/追踪 SDK、无崩溃上报。',
    '你与宿主的会话内容仅在你的设备与你自行配置的宿主之间传输,我们不参与、不可见。',
  ]),
  _PolicySection('二、服务提供方式', <String>[
    '本应用是编程工具 DeepSeek Harness(dsh)的终端控制工具,自身不提供任何后台服务与 LLM 服务。',
    '所有服务由你(开发者)连接的后台与 DeepSeek Harness 提供。',
  ]),
  _PolicySection('三、本地数据与存储', <String>[
    '应用仅在本机保存:配对凭证(设备令牌)、设备名与界面偏好;卸载即全部清除。',
    '设备名仅在配对/连接时发送给你自己的网关,用于宿主端「已配对设备」展示。',
  ]),
  _PolicySection('四、系统权限说明', <String>[
    '网络权限:连接你配置的宿主与网关,传输会话与控制指令。',
    '相机权限(移动版 Android/iOS/OHOS):仅用于扫描配对二维码完成配对,不拍照、不录像;'
        '拒绝授权不影响其他功能,可改用手动输入或剪贴板配对。桌面版不申请相机权限。',
  ]),
  _PolicySection('五、你的权利', <String>[
    '你可随时在系统设置中撤销权限;卸载应用即可删除全部本地数据;不同意本政策可随时退出应用。',
  ]),
  _PolicySection('六、政策更新与联系我们', <String>[
    '政策实质变更时,将在应用内重新征得你的同意。',
    '如有疑问或需行使数据权利,请联系:iptton@gmail.com',
  ]),
];

/// 拉起隐私门壳(独立 MaterialApp),返回用户决定:true=已同意并持久化,
/// false=拒绝(main 负责退出进程)。
Future<bool> runPrivacyConsentGate({required PrivacyConsentStore store}) {
  final decided = Completer<bool>();
  void settle(bool value) {
    if (!decided.isCompleted) decided.complete(value);
  }

  runApp(
    _PrivacyGateApp(
      onAgree: () async {
        await store.agree();
        settle(true);
      },
      onExit: () => settle(false),
    ),
  );
  return decided.future;
}

class _PrivacyGateApp extends StatelessWidget {
  const _PrivacyGateApp({required this.onAgree, required this.onExit});

  final Future<void> Function() onAgree;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    // 跟随系统亮/暗(与主 app 同一套主题定义,见 app_theme.dart)。
    return MaterialApp(
      title: 'DshAPP',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: PrivacyConsentPage(onAgree: onAgree, onExit: onExit),
    );
  }
}

/// 隐私同意页:摘要卡 + 全量政策正文 + 同意/不同意。
class PrivacyConsentPage extends StatefulWidget {
  const PrivacyConsentPage({super.key, required this.onAgree, this.onExit});

  final Future<void> Function() onAgree;
  final VoidCallback? onExit;

  @override
  State<PrivacyConsentPage> createState() => _PrivacyConsentPageState();
}

class _PrivacyConsentPageState extends State<PrivacyConsentPage> {
  Future<void> _agree() => widget.onAgree();

  Future<void> _confirmDecline() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('不同意并退出?'),
        content: const Text(
          '不同意《隐私政策》将无法使用 DshAPP。'
          '若仅对部分条款有疑问,可选择「再想想」,或通过邮件联系我们。',
        ),
        actions: <Widget>[
          TextButton(
            key: const ValueKey('privacy-exit-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            key: const ValueKey('privacy-exit-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('不同意并退出'),
          ),
        ],
      ),
    );
    if (go == true) widget.onExit?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      // 合规门不允许系统返回绕过。
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final body = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _buildHeader(scheme),
                          const SizedBox(height: 20),
                          _buildSummaryCard(scheme),
                          const SizedBox(height: 20),
                          for (final section in _policySections) ...<Widget>[
                            Text(
                              section.heading,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 8),
                            for (final p in section.paragraphs) ...<Widget>[
                              Text(
                                p,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  height: 1.55,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                            const SizedBox(height: 10),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            '完整隐私政策:$kPrivacyPolicyUrl',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: scheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
                    child: Row(
                      children: <Widget>[
                        TextButton(
                          key: const ValueKey('privacy-decline'),
                          onPressed: _confirmDecline,
                          child: const Text('不同意'),
                        ),
                        const Spacer(),
                        FilledButton(
                          key: const ValueKey('privacy-agree'),
                          onPressed: _agree,
                          child: const Text('同意并继续'),
                        ),
                      ],
                    ),
                  ),
                ],
              );
              // 宽屏(平板横放/桌面)限宽居中,保持可读行宽。
              return constraints.maxWidth > 640
                  ? Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: body,
                      ),
                    )
                  : body;
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/singleman_icon_master.png',
                width: 44,
                height: 44,
                filterQuality: FilterQuality.high,
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '欢迎使用 DshAPP',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.4,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '使用前,请阅读并同意《隐私政策》',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSummaryCard(ColorScheme scheme) {
    return Container(
      key: const ValueKey('privacy-summary'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          scheme.primary.withValues(alpha: .06),
          scheme.surface,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: .25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final point in _summaryPoints) ...<Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 4.5),
                  child: Icon(
                    Icons.check_circle,
                    size: 16,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    point,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            if (point != _summaryPoints.last) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// 供 main 在用户拒绝时调用:优雅退场,失败兜底杀进程。
Future<void> exitAfterPrivacyDecline() async {
  try {
    await SystemNavigator.pop();
  } on Object {
    // 平台通道不可用时直接退出。
  }
  exit(0);
}
