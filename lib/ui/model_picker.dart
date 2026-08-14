// 模型选择器(M4):目录分组 + reasoning effort 下拉;提交走 selectModel。
// routable=false 时警示(prompt 前不可路由 → model-unavailable)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class ModelPickerResult {
  const ModelPickerResult({required this.provider, required this.model, this.reasoningEffort});
  final String provider;
  final String model;
  final String? reasoningEffort;
}

/// 打开选择器;返回 null = 取消。
Future<ModelPickerResult?> showModelPicker(
  BuildContext context, {
  required Future<SessionModelsValue> Function() loadCatalog,
}) {
  return showDialog<ModelPickerResult>(
    context: context,
    builder: (context) => _ModelPickerDialog(loadCatalog: loadCatalog),
  );
}

class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({required this.loadCatalog});
  final Future<SessionModelsValue> Function() loadCatalog;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  SessionModelsValue? _catalog;
  Object? _error;
  ModelSelection? _picked;
  String? _effort;

  @override
  void initState() {
    super.initState();
    widget.loadCatalog().then((c) {
      if (mounted) {
        setState(() {
          _catalog = c;
          _picked = c.current;
          final efforts = _effortsOf(c.current);
          _effort = c.current.reasoningEffort ?? (efforts.isEmpty ? null : efforts.first.id);
        });
      }
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  List<ModelReasoningEffort> _effortsOf(ModelSelection sel) {
    for (final g in _catalog?.groups ?? const <ModelProviderGroup>[]) {
      if (g.id != sel.provider) continue;
      for (final m in g.models) {
        if (m.id == sel.model) {
          return m.reasoning?.efforts ?? const <ModelReasoningEffort>[];
        }
      }
    }
    return const <ModelReasoningEffort>[];
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择模型'),
      content: SizedBox(
        width: 420,
        child: _error != null
            ? Text('加载失败: ' + _error.toString())
            : _catalog == null
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_catalog!.routable == false)
                        Container(
                          padding: const EdgeInsets.all(8),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.errorContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            '当前 provider 不可路由:发送前将得到 model-unavailable',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      for (final group in _catalog!.groups) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Text(group.name,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        ),
                        for (final model in group.models)
                          RadioListTile<String>(
                            dense: true,
                            value: group.id + '' + model.id,
                            groupValue: _picked == null
                                ? null
                                : _picked!.provider + '' + _picked!.model,
                            title: Text(model.name),
                            subtitle: Text(model.id, style: const TextStyle(fontSize: 11)),
                            onChanged: (v) {
                              final parts = v!.split('');
                              setState(() {
                                _picked = ModelSelection(provider: parts[0], model: parts[1]);
                                final efforts = _effortsOf(_picked!);
                                _effort = efforts.isEmpty ? null : efforts.first.id;
                              });
                            },
                          ),
                      ],
                      if (_picked != null && _effortsOf(_picked!).isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: DropdownButtonFormField<String>(
                            initialValue: _effort,
                            decoration: const InputDecoration(
                                labelText: '推理力度', border: OutlineInputBorder(), isDense: true),
                            items: [
                              for (final e in _effortsOf(_picked!))
                                DropdownMenuItem(value: e.id, child: Text(e.name)),
                            ],
                            onChanged: (v) => setState(() => _effort = v),
                          ),
                        ),
                    ],
                  ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: _picked == null
              ? null
              : () => Navigator.pop(
                    context,
                    ModelPickerResult(
                      provider: _picked!.provider,
                      model: _picked!.model,
                      reasoningEffort: _effort,
                    ),
                  ),
          child: const Text('应用'),
        ),
      ],
    );
  }
}
