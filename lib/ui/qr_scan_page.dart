// 扫码配对页(M6.2):相机直扫 Mac 侧 dsh web「移动接入」的二维码。
// 二维码内容 = 网关落地页 URL(#c=码&h=主机码&l=机器名),扫中 pop 回原文,
// 由 PairingPage.parsePairInvite 解析后发起(锚定主机码自动高亮)。
//
// 兜底:相机不可用/权限被拒时 errorBuilder 给出说明 + 剪贴板粘贴出口
// (系统相机扫 → 落地页「复制」→ 此处粘贴,即原 M6.2 流程)。
// 纪律:页面仅 Android/iOS 推入(桌面无相机形态走剪贴板,见 PairingPage)。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mobile_scanner/mobile_scanner.dart';

class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;
  bool _torchOn = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  /// 剪贴板兜底:落地页「复制」产物(完整邀请 URL 或裸码)。
  Future<void> _pasteAndReturn() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    _done = true;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫码配对'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _ErrorFallback(
              error: error,
              onRetry: () => _controller.start(),
              onPaste: _pasteAndReturn,
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    '对准 Mac 上 dsh web「移动接入」的二维码',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withValues(alpha: .9)),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: _torchOn ? '关闭手电' : '打开手电',
                        icon: Icon(
                          _torchOn ? Icons.flash_on : Icons.flash_off,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          setState(() => _torchOn = !_torchOn);
                          _controller.toggleTorch();
                        },
                      ),
                      const SizedBox(width: 12),
                      TextButton.icon(
                        icon: const Icon(Icons.content_paste, size: 18),
                        label: const Text('从剪贴板粘贴'),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.primary,
                          backgroundColor: Colors.white.withValues(alpha: .12),
                        ),
                        onPressed: _pasteAndReturn,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 相机失败面:权限被拒给去设置的指引;其余错误给重试 + 粘贴出口。
class _ErrorFallback extends StatelessWidget {
  const _ErrorFallback({
    required this.error,
    required this.onRetry,
    required this.onPaste,
  });

  final MobileScannerException error;
  final VoidCallback onRetry;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final message = denied
        ? '相机权限被拒绝。\n到系统设置放开 DshAPP 的相机权限后重试,'
            '或用系统相机扫码后在落地页点「复制」,回到这里粘贴。'
        : '相机不可用(${error.errorCode.name})。\n可重试,或改用剪贴板粘贴邀请。';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, size: 40, color: Colors.white70),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: onRetry,
                  child: const Text('重试'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: onPaste,
                  child: const Text('从剪贴板粘贴'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
