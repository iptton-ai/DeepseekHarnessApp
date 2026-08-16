// 模型选择器(M4):目录分组 + reasoning effort 下拉;提交走 selectModel。
// routable=false 时警示(prompt 前不可路由 → model-unavailable)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class ModelPickerResult {
  const ModelPickerResult({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

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
    widget
        .loadCatalog()
        .then((c) {
          if (mounted) {
            setState(() {
              _catalog = c;
              _picked = c.current;
              final efforts = _effortsOf(c.current);
              _effort = c.current.reasoningEffort;
              if (_effort == null && efforts.isNotEmpty) {
                _effort = efforts.first.id;
              }
            });
          }
        })
        .catchError((Object e) {
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

  Widget _buildContent(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Text('加载失败: $error');
    }

    final catalog = _catalog;
    if (catalog == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // 目录可长(用户实报:列表穿透 dialog 容器)→ 限高 + 滚动,
    // 分组用 ExpansionTile 可展开/收起(默认只展开 current 所在组)。
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (catalog.routable == false)
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
            for (final group in catalog.groups)
              ExpansionTile(
                key: ValueKey('model-group-${group.id}'),
                dense: true,
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                // 默认展开 current 所在组,其余收起(长目录不用
                // 全量铺开;点头部随时展开)。
                initiallyExpanded:
                    _picked != null && _picked!.provider == group.id,
                title: Text(
                  group.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                children: [
                  for (final model in group.models)
                    // 选中判定用 record 值相等((provider, model)
                    // 二元组;Dart 3 record 的 == 是结构化比较)——
                    // 对齐 web ModelSelect 的 selected 判定。
                    // 历史 bug:曾用字符串拼接 + split 反拆,分隔符
                    // 丢失后 split('') 拆出单字符,_picked 变垃圾值
                    // → 点击任一模型后全部选项失去选中(用户实报)。
                    RadioListTile<(String, String)>(
                      dense: true,
                      value: (group.id, model.id),
                      groupValue: _picked == null
                          ? null
                          : (_picked!.provider, _picked!.model),
                      title: Text(model.name),
                      subtitle: Text(
                        model.id,
                        style: const TextStyle(fontSize: 11),
                      ),
                      onChanged: (v) {
                        setState(() {
                          _picked = ModelSelection(
                            provider: v!.$1,
                            model: v.$2,
                          );
                          final efforts = _effortsOf(_picked!);
                          _effort = efforts.isEmpty ? null : efforts.first.id;
                        });
                      },
                    ),
                ],
              ),
            if (_picked != null && _effortsOf(_picked!).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: DropdownButtonFormField<String>(
                  initialValue: _effort,
                  decoration: const InputDecoration(
                    labelText: '推理力度',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择模型'),
      content: SizedBox(width: 420, child: _buildContent(context)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
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
