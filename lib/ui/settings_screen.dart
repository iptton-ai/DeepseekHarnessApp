// SettingsScreen — W1-D 设置面板(全屏页面,移动优先)。
//
// 契约(docs/audit/conversation.md §1/2/3/6/7 + DSH-PROTOCOL §6):
// - settings/credentials/llm.discoverModels 仅 loopback 可用(LAN 403);
//   SettingsEntryButton 按 PrivilegeScope 门控,非 loopback 隐藏入口
// - 模型分区:提供方行(状态点+名称+自定义标签)→ 整卡推入二级页编辑
//   (API 密钥只写输入、baseURL、模型列表、获取可用模型、删除提供方确认)
// - 通用分区:默认权限预设(选项从 describe 的 schema 动态读,读不到隐藏该行;
//   danger-full-access 需显式风险确认,不可跳过)+ 打开配置文件
// - revision 冲突(settings-conflict):snackBar「配置已在别处修改,已重新加载」
// - 移动可用性:列表行/按钮触控区 ≥44dp;弹层用 showModalBottomSheet;
//   hover 语义改为常显按钮;宽内容(baseURL/容量)横向可滚/截断
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// CAS 冲突的固定提示(web 同款恢复语义)。
const kSettingsConflictMessage = '配置已在别处修改,已重新加载';

/// 设置入口构件:集成方放侧栏底部。非 loopback 返回空件(特权面门控)。
class SettingsEntryButton extends StatelessWidget {
  const SettingsEntryButton({super.key, required this.scope, required this.store});

  final PrivilegeScope scope;
  final SettingsStoreView store;

  @override
  Widget build(BuildContext context) {
    // 特权围栏:settings/credentials 仅 loopback(LAN 403),非 loopback 隐藏。
    if (!scope.showPrivilegedPanels) return const SizedBox.shrink();
    return ListTile(
      // 触控区 ≥44dp(ListTile 默认 56)。
      leading: const Icon(Icons.settings_outlined, size: 20),
      title: const Text('设置', style: TextStyle(fontSize: 14)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsScreen(store: store),
          ),
        );
      },
    );
  }
}

/// 设置全屏页(移动优先):模型分区 + 通用分区。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.store});

  final SettingsStoreView store;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  StreamSubscription<SettingsSnapshot>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.store.snapshots.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      await widget.store.refresh();
    } on Object catch (e) {
      if (!mounted) return;
      _showError(context, '刷新失败: ${_errorText(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = widget.store.current;
    final presetOptions = widget.store.permissionPresetOptions;
    final loaded = snap.providers.isNotEmpty || snap.namespaces.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const _SectionHeader('模型'),
                if (snap.providers.isEmpty)
                  const ListTile(title: Text('无可用提供方'))
                else
                  for (final p in snap.providers) _providerTile(context, p),
                const Divider(height: 24),
                const _SectionHeader('通用'),
                if (presetOptions != null) _permissionPresetTile(context, presetOptions),
                _openDocumentTile(context),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _providerTile(BuildContext context, ProviderEntry p) {
    return ListTile(
      // ≥44dp 触控区。
      leading: _StatusDot(status: p.credentialStatus),
      title: Row(
        children: [
          Flexible(
            child: Text(
              p.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (p.custom) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('自定义', style: TextStyle(fontSize: 10)),
            ),
          ],
        ],
      ),
      subtitle: p.credentialRef == null
          ? Text(p.routable ? '可路由' : '未配置', style: const TextStyle(fontSize: 12))
          : Text(p.credentialRef!, style: const TextStyle(fontSize: 12)),
      trailing: Icon(
        p.routable ? Icons.bolt : Icons.chevron_right,
        size: 18,
        color: p.routable ? Colors.green : null,
      ),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _ProviderEditPage(store: widget.store, entry: p),
          ),
        );
      },
    );
  }

  /// 默认权限预设行:底部选择器(schema 动态读);danger-full-access 需
  /// 显式风险确认对话框(不可跳过)。
  Future<void> _pickPreset(BuildContext context, List<String> options) async {
    final current = widget.store.currentPermissionPreset;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('默认权限预设',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            for (final o in options)
              ListTile(
                leading: o == current ? const Icon(Icons.check) : null,
                title: Text(_titleCase(o)),
                onTap: () => Navigator.pop(context, o),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    if (!context.mounted) return;
    if (picked == 'danger-full-access') {
      final ok = await _confirmDanger(context);
      if (ok != true) return;
    }
    if (!context.mounted) return;
    final ns = widget.store.permissionNamespace;
    if (ns == null) return; // schema 读不到(已降级隐藏),防御。
    await _runSafe(
      context,
      () => widget.store.scope(ns).setField(['defaultPreset'], picked),
      success: '默认权限已更新为 ${_titleCase(picked)}',
    );
  }

  Widget _permissionPresetTile(BuildContext context, List<String> options) {
    final current = widget.store.currentPermissionPreset;
    return ListTile(
      leading: const Icon(Icons.lock_outline, size: 20),
      title: const Text('默认权限预设'),
      subtitle: Text(current == null ? '未设置' : _titleCase(current)),
      trailing: const Icon(Icons.expand_more),
      onTap: () => _pickPreset(context, options),
    );
  }

  Widget _openDocumentTile(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.description_outlined, size: 20),
      title: const Text('打开配置文件'),
      subtitle: const Text('settings.yaml(桌面原生编辑器打开)'),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => _runSafe(
        context,
        () async {
          await widget.store.openDocument();
        },
        success: '已请求打开配置文件',
      ),
    );
  }

  /// 显式风险确认:danger-full-access 不可跳过(barrierDismissible: false)。
  Future<bool?> _confirmDanger(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('风险确认:完全访问'),
        content: const Text(
          '「完全访问」(danger-full-access)将授予工具不受限的文件系统与命令执行权限,'
          '影响之后创建的所有会话。请确认你理解并接受此风险。',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              minimumSize: const Size(96, 44),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('我了解风险,继续'),
          ),
        ],
      ),
    );
  }
}

/// 提供方编辑二级页(移动:整卡推入全屏页)。
/// 字段:API 密钥(只写,已配置显示徽标不清显值)、baseURL、模型列表、
/// 获取可用模型(discoverModels 带草稿端点/密钥)、删除提供方(确认)。
class _ProviderEditPage extends StatefulWidget {
  const _ProviderEditPage({required this.store, required this.entry});

  final SettingsStoreView store;
  final ProviderEntry entry;

  @override
  State<_ProviderEditPage> createState() => _ProviderEditPageState();
}

class _ProviderEditPageState extends State<_ProviderEditPage> {
  final _keyController = TextEditingController();
  final _baseURLController = TextEditingController();
  bool _discovering = false;
  List<DiscoveredModelView>? _discovered;
  final Set<int> _selectedModels = <int>{};
  String? _discoverError;
  @override
  void initState() {
    super.initState();
    _baseURLController.text = widget.entry.field('baseURL') ?? '';
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseURLController.dispose();
    super.dispose();
  }

  Future<void> _saveKey() async {
    final value = _keyController.text.trim();
    if (value.isEmpty) {
      _showError(context, '请输入 API 密钥');
      return;
    }
    final ref = widget.entry.credentialRef;
    if (ref == null) {
      _showError(context, '该提供方没有关联凭据引用(apiKeyEnv),无法写入密钥');
      return;
    }
    final ok = await _runSafe(
      context,
      () => widget.store.setCredential(ref, value),
      success: '密钥已保存',
    );
    if (ok && mounted) _keyController.clear();
  }

  Future<void> _saveBaseURL() async {
    final value = _baseURLController.text.trim();
    if (value.isEmpty) {
      _showError(context, '请输入 Base URL');
      return;
    }
    await _runSafe(
      context,
      () => widget.store
          .scope(widget.entry.namespace)
          .setField([...widget.entry.settingsPath, 'baseURL'], value),
      success: 'Base URL 已保存',
    );
  }

  /// 获取可用模型:按当前草稿(未保存的 baseURL/密钥)询问主机。
  Future<void> _discover() async {
    setState(() {
      _discovering = true;
      _discoverError = null;
    });
    try {
      final result = await widget.store.discoverModels(
        settingsNs: widget.entry.namespace,
        provider: widget.entry.providerId,
        baseURL: _trimOrNull(_baseURLController.text),
        apiKey: _trimOrNull(_keyController.text),
      );
      if (mounted) {
        setState(() {
          _discovered = result.models;
          _selectedModels.clear();
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _discoverError = _errorText(e));
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  /// 应用勾选的可用模型(整体替换 models 数组,web 同款语义)。
  Future<void> _applyDiscovered() async {
    final selected = [
      for (final i in _selectedModels) _discovered![i].toJson(),
    ];
    await _runSafe(
      context,
      () => widget.store
          .scope(widget.entry.namespace)
          .setField([...widget.entry.settingsPath, 'models'], selected),
      success: '模型列表已更新',
    );
  }

  Future<void> _confirmDelete() async {
    final refNote = widget.entry.credentialRef != null
        ? ',并清除其关联凭据 ${widget.entry.credentialRef}'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除提供方'),
        content: Text(
          '将删除「${widget.entry.displayName}」的配置$refNote。此操作不可撤销。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              minimumSize: const Size(96, 44),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await _runSafe(
      context,
      () async {
        await widget.store.scope(widget.entry.namespace).unsetField(widget.entry.settingsPath);
        final ref = widget.entry.credentialRef;
        if (ref != null) await widget.store.unsetCredential(ref);
      },
      success: '已删除',
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return Scaffold(
      appBar: AppBar(title: Text(entry.displayName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusRow(context, entry),
          const SizedBox(height: 16),
          _fieldLabel(context, 'API 密钥', badge: entry.configured ? '已配置' : null),
          TextField(
            controller: _keyController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: '输入密钥以覆盖(值只写,不清显)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          _fullButton(
            onPressed: _saveKey,
            label: '保存密钥',
          ),
          const SizedBox(height: 20),
          _fieldLabel(context, 'Base URL'),
          TextField(
            controller: _baseURLController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: 'https://api.example.com/v1',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 8),
          _fullButton(
            onPressed: _saveBaseURL,
            label: '保存 Base URL',
          ),
          const SizedBox(height: 20),
          _fieldLabel(context, '模型'),
          if (entry.models.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text('暂无模型', style: TextStyle(fontSize: 12)),
            )
          else
            for (final m in entry.models) _modelRow(m),
          const SizedBox(height: 12),
          _fullButton(
            onPressed: _discovering ? null : _discover,
            label: _discovering ? '获取中…' : '获取可用模型',
            icon: Icons.cloud_download_outlined,
          ),
          if (_discovering) const LinearProgressIndicator(minHeight: 2),
          if (_discoverError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '获取失败: ${_discoverError!}',
                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_discovered != null && _discovered!.isNotEmpty) ...[
            const SizedBox(height: 12),
            _fieldLabel(context, '可用模型(勾选后应用)'),
            for (var i = 0; i < _discovered!.length; i++)
              CheckboxListTile(
                dense: true,
                value: _selectedModels.contains(i),
                title: Text(
                  _discovered![i].name ?? _discovered![i].id,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  _discovered![i].id +
                      (_discovered![i].contextWindow != null
                          ? ' · ctx ${_formatCapacity(_discovered![i].contextWindow)}'
                          : ''),
                  style: const TextStyle(fontSize: 11),
                ),
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedModels.add(i);
                    } else {
                      _selectedModels.remove(i);
                    }
                  });
                },
              ),
            const SizedBox(height: 8),
            _fullButton(
              onPressed: _selectedModels.isEmpty ? null : _applyDiscovered,
              label: '应用所选模型',
            ),
          ],
          const Divider(height: 32),
          _fullButton(
            onPressed: _confirmDelete,
            label: '删除提供方',
            icon: Icons.delete_outline,
            destructive: true,
          ),
        ],
      ),
    );
  }

  Widget _statusRow(BuildContext context, ProviderEntry entry) {
    final (dot, label) = switch (entry.credentialStatus) {
      CredentialStatus.configured => (Colors.green, '密钥已配置'),
      CredentialStatus.missing => (Colors.red, '凭据缺失'),
      CredentialStatus.none => (Colors.grey, '无凭据引用'),
    };
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 13)),
        if (entry.routable) ...[
          const SizedBox(width: 8),
          const Text('可路由', style: TextStyle(fontSize: 12, color: Colors.green)),
        ],
      ],
    );
  }

  Widget _modelRow(Map<String, dynamic> m) {
    final id = (m['id'] as String?) ?? '';
    final name = (m['name'] as String?) ?? id;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(name, style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        '$id · ctx ${_formatCapacity(m['contextWindow'] as int?)} / out '
            '${_formatCapacity(m['maxTokens'] as int?)}',
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis, // 宽容量文本截断,不破行
      ),
    );
  }

  Widget _fieldLabel(BuildContext context, String text, {String? badge}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(text, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          if (badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(badge, style: const TextStyle(fontSize: 10, color: Colors.green)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _fullButton({
    required VoidCallback? onPressed,
    required String label,
    IconData? icon,
    bool destructive = false,
  }) {
    final style = FilledButton.styleFrom(
      // 触控区 ≥44dp。
      minimumSize: const Size(double.infinity, 48),
      backgroundColor: destructive ? Theme.of(context).colorScheme.error : null,
    );
    final child = icon == null
        ? FilledButton(
            style: style,
            onPressed: onPressed,
            child: Text(label),
          )
        : FilledButton.icon(
            style: style,
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(label),
          );
    return SizedBox(width: double.infinity, child: child);
  }
}

// ---- 小组件与工具 ----

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}

/// 提供方状态点:绿=已配置,红=引用缺失,灰=无引用(web 同款)。
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final CredentialStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      CredentialStatus.configured => Colors.green,
      CredentialStatus.missing => Colors.red,
      CredentialStatus.none => Colors.grey,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// kebab-case → Title Case(workspace-write → Workspace Write)。
String _titleCase(String s) => s
    .split('-')
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');

/// 容量后缀:256000 → 256K,1000000 → 1M。
String _formatCapacity(int? n) {
  if (n == null) return '—';
  if (n >= 1000000 && n % 1000000 == 0) return '${n ~/ 1000000}M';
  if (n >= 1000 && n % 1000 == 0) return '${n ~/ 1000}K';
  return n.toString();
}

String? _trimOrNull(String s) {
  final t = s.trim();
  return t.isEmpty ? null : t;
}

/// 统一错误呈现:冲突走固定文案,其余显示业务消息,不许静默吞。
String _errorText(Object e) {
  if (e is RpcBusinessError) {
    try {
      final json = e.error.toJson();
      final message = json['message'];
      if (message is String && message.isNotEmpty) return message;
      final code = json['code'];
      if (code is String) return code;
    } on Object {
      // toJson 兜底失败退化为 toString。
    }
    return e.toString();
  }
  return e.toString();
}

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}

/// 执行写操作:成功可选提示;SettingsConflictError → 固定冲突文案(已自动重读);
/// 其他错误 → 业务消息。返回是否成功。
Future<bool> _runSafe(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    if (success != null) {
      messenger.showSnackBar(SnackBar(content: Text(success)));
    }
    return true;
  } on SettingsConflictError {
    messenger.showSnackBar(const SnackBar(content: Text(kSettingsConflictMessage)));
    return false;
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('操作失败: ${_errorText(e)}')));
    return false;
  }
}