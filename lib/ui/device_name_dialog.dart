// 设备名编辑对话框(配对页首屏与设置页「连接」分区共用)。
// 校验:清洗后非空且非泛称(localhost 等);拒绝时内联提示不关窗。
import 'package:flutter/material.dart';

Future<void> showDeviceNameDialog(
  BuildContext context, {
  required String current,
  required Future<bool> Function(String) onSet,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _DeviceNameDialog(current: current, onSet: onSet),
  );
}

class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.current, required this.onSet});
  final String current;
  final Future<bool> Function(String) onSet;

  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final TextEditingController _controller;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.current);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await widget.onSet(_controller.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = '名称不能为空或「localhost」(1-32 字符)';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('本机名称'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: 32,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '设备名',
              hintText: '如 iPhone-书房 或 Android-Pixel8',
              counterText: '',
            ),
            onSubmitted: (_) {
              if (!_busy) _save();
            },
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }
}

/// 当前设备名的展示值(未装载 → 兜底),供对话框/行副标题。
String displayDeviceName(String? raw, String fallback) =>
    raw == null || raw.isEmpty ? fallback : raw;
