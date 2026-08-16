// SettingsScreen — 设置中心(全屏页面,移动优先;入口常驻不门控)。
//
// 结构(重构:模型选择/发起配对等收进设置作子菜单):
// - 会话:模型选择(showModelPicker 经回调注入;未选会话时回调内提示)
// - 连接(方案 A 多主机):主机簿列表 —— 活动主机行(实时相位;未连接
//   给手动重连按钮)+ 其他主机行(点击切换,整代重装)+ 每行可删除
//   (确认弹窗;删活动主机自动切到剩余首条)+ 添加主机(发起配对);
//   未注入 hosts 时保持旧形态(authed ? 状态行 : 发起配对)
// - 外观:主题三选一(ThemeModeRow,从侧栏移入)
// - 特权分区(loopback 或已鉴权远程;非特权整段隐藏 + 锁形说明,
//   入口本身不再隐藏 —— 手机也要能进设置发起配对):
//   模型提供方(状态点+名称+自定义标签)→ 整卡推入二级页编辑
//   (API 密钥只写输入、baseURL、模型列表、获取可用模型、删除提供方确认)
//   + 通用:默认权限预设(schema 动态读,读不到隐藏该行;danger-full-access
//   需显式风险确认,不可跳过)+ 打开配置文件
// - 契约(docs/audit/conversation.md §1/2/3/6/7 + DSH-PROTOCOL §6):
//   settings/credentials/llm.discoverModels 仅特权形态可用(LAN 403)
// - revision 冲突(settings-conflict):snackBar「配置已在别处修改,已重新加载」
// - 移动可用性:列表行/按钮触控区 ≥44dp;弹层用 showModalBottomSheet;
//   hover 语义改为常显按钮;宽内容(baseURL/容量)横向可滚/截断
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/host_info.dart';
import 'package:singleman/ui/device_name_dialog.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/theme_store.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/ui/theme_mode_row.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// CAS 冲突的固定提示(web 同款恢复语义)。
const kSettingsConflictMessage = '配置已在别处修改,已重新加载';

String _hostConnectionTitle({
  required bool connected,
  required String machine,
  required String disconnectedFallback,
}) {
  if (connected) {
    if (machine.isEmpty) return '已连接';
    return '已连接 · $machine';
  }
  if (machine.isEmpty) return disconnectedFallback;
  return '$machine · 未连接';
}

/// 设置入口构件:集成方放侧栏底部,常驻不门控 —— 发起配对
/// 是手机形态的必备入口,特权分区(提供方/通用)在页内按 scope 隐藏。
class SettingsEntryButton extends StatelessWidget {
  const SettingsEntryButton({
    super.key,
    required this.scope,
    required this.store,
    this.onPickModel,
    this.onOpenPairing,
    this.hostStatus,
    this.hosts,
    this.onSwitchHost,
    this.onRemoveHost,
    this.onReconnect,
    this.deviceName,
    this.onSetDeviceName,
    this.theme,
  });

  final PrivilegeScope scope;
  final SettingsStoreView store;

  /// 模型选择子菜单(打开 showModelPicker;由集成方注入,通常含会话校验)。
  final VoidCallback? onPickModel;

  /// 发起配对子菜单(PairingPage)。
  final VoidCallback? onOpenPairing;

  /// 宿主状态(已配对时「连接」分区用「已连接 <机器名>」替换「发起配对」)。
  final ValueListenable<HostStatus>? hostStatus;

  /// 主机簿(注入即启用多主机「连接」分区;缺席保持旧形态)。
  final ValueListenable<HostBook>? hosts;
  final Future<void> Function(String hostId)? onSwitchHost;
  final Future<void> Function(String hostId)? onRemoveHost;
  final VoidCallback? onReconnect;

  /// 本机设备名(配对时上报给宿主「已配对设备」表;可改)。
  final ValueListenable<String?>? deviceName;
  final Future<bool> Function(String)? onSetDeviceName;

  /// 主题 store;缺席时设置页不渲染「外观」分区。
  final ThemeStoreView? theme;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      // 触控区 ≥44dp(ListTile 默认 56)。
      leading: const Icon(Icons.settings_outlined, size: 20),
      title: const Text('设置', style: TextStyle(fontSize: 14)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => showSettingsHub(
        context,
        store: store,
        scope: scope,
        onPickModel: onPickModel,
        onOpenPairing: onOpenPairing,
        hostStatus: hostStatus,
        hosts: hosts,
        onSwitchHost: onSwitchHost,
        onRemoveHost: onRemoveHost,
        onReconnect: onReconnect,
        deviceName: deviceName,
        onSetDeviceName: onSetDeviceName,
        theme: theme,
      ),
    );
  }
}

/// 打开设置中心(侧栏常规行与宽屏折叠轨道图标共用的入口)。
void showSettingsHub(
  BuildContext context, {
  required SettingsStoreView store,
  required PrivilegeScope scope,
  VoidCallback? onPickModel,
  VoidCallback? onOpenPairing,
  ValueListenable<HostStatus>? hostStatus,
  ValueListenable<HostBook>? hosts,
  Future<void> Function(String hostId)? onSwitchHost,
  Future<void> Function(String hostId)? onRemoveHost,
  VoidCallback? onReconnect,
  ValueListenable<String?>? deviceName,
  Future<bool> Function(String)? onSetDeviceName,
  ThemeStoreView? theme,
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(
        store: store,
        scope: scope,
        onPickModel: onPickModel,
        onOpenPairing: onOpenPairing,
        hostStatus: hostStatus,
        hosts: hosts,
        onSwitchHost: onSwitchHost,
        onRemoveHost: onRemoveHost,
        onReconnect: onReconnect,
        deviceName: deviceName,
        onSetDeviceName: onSetDeviceName,
        theme: theme,
      ),
    ),
  );
}

/// 设置中心全屏页(移动优先):会话/连接/外观分区 + 特权(提供方/通用)分区。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.store,
    required this.scope,
    this.onPickModel,
    this.onOpenPairing,
    this.hostStatus,
    this.hosts,
    this.onSwitchHost,
    this.onRemoveHost,
    this.onReconnect,
    this.deviceName,
    this.onSetDeviceName,
    this.theme,
  });

  final SettingsStoreView store;
  final PrivilegeScope scope;
  final VoidCallback? onPickModel;
  final VoidCallback? onOpenPairing;

  /// 宿主状态(实时;缺席时保持旧行为 —— 始终显示「发起配对」)。
  final ValueListenable<HostStatus>? hostStatus;

  /// 主机簿(注入即启用多主机「连接」分区;缺席保持旧形态)。
  final ValueListenable<HostBook>? hosts;
  final Future<void> Function(String hostId)? onSwitchHost;
  final Future<void> Function(String hostId)? onRemoveHost;

  /// 未连接的活动主机行「重连」按钮(触发 connection.resume)。
  final VoidCallback? onReconnect;

  /// 本机设备名(连接分区首行,可改;缺席不渲染)。
  final ValueListenable<String?>? deviceName;
  final Future<bool> Function(String)? onSetDeviceName;
  final ThemeStoreView? theme;

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
    widget.hostStatus?.addListener(_onHostStatus);
    widget.hosts?.addListener(_onHosts);
  }

  void _onHostStatus() {
    if (mounted) setState(() {});
  }

  void _onHosts() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.hostStatus?.removeListener(_onHostStatus);
    widget.hosts?.removeListener(_onHosts);
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
    final privileged = widget.scope.showPrivilegedPanels;
    // 权限预设选项读自 describe schema(特权数据源)—— 非特权形态不读。
    final presetOptions = privileged
        ? widget.store.permissionPresetOptions
        : null;
    final loaded = snap.providers.isNotEmpty || snap.namespaces.isNotEmpty;
    final hasConnection = widget.onOpenPairing != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          // 刷新只作用于特权分区(settings.* 读取);非特权形态点了必 403。
          if (privileged)
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
        ],
      ),
      body: ListView(
        children: [
          const _SectionHeader('会话'),
          _modelTile(context),
          if (hasConnection) ...[
            const Divider(height: 24),
            const _SectionHeader('连接'),
            ..._connectionSection(context),
          ],
          if (widget.theme != null) ...[
            const Divider(height: 24),
            const _SectionHeader('外观'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: ThemeModeRow(store: widget.theme!),
            ),
          ],
          const Divider(height: 24),
          if (privileged) ...[
            const _SectionHeader('模型提供方'),
            if (!loaded)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (snap.providers.isEmpty)
              const ListTile(title: Text('无可用提供方'))
            else
              for (final p in snap.providers) _providerTile(context, p),
            const Divider(height: 24),
            const _SectionHeader('通用'),
            if (presetOptions != null)
              _permissionPresetTile(context, presetOptions),
            _openDocumentTile(context),
          ] else
            const _PrivilegeNote(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 模型选择子菜单:为当前会话挑选模型/推理力度(选择器经回调打开)。
  Widget _modelTile(BuildContext context) {
    return ListTile(
      // ≥44dp 触控区(ListTile 默认 56)。
      leading: const Icon(Icons.tune, size: 20),
      title: const Text('模型选择'),
      subtitle: const Text('为当前会话选择模型与推理力度', style: TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: widget.onPickModel,
    );
  }

  /// 发起配对子菜单:生成亮码,与运行 DSH 的电脑配对(主鉴权入口)。
  Widget _pairingTile(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.phonelink_ring_outlined, size: 20),
      title: const Text('发起配对'),
      subtitle: const Text(
        '生成配对码,与运行 DSH 的电脑配对',
        style: TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: widget.onOpenPairing,
    );
  }

  /// 已配对时 _paired = 持令牌(远程形态);此时「发起配对」让位给状态行。
  bool get _paired => widget.hostStatus?.value.authed ?? false;

  /// 「连接」分区:注入 hosts 即多主机形态(主机列表 + 添加);
  /// 缺席保持旧形态(authed ? 状态行 : 发起配对)。
  List<Widget> _connectionSection(BuildContext context) {
    final book = widget.hosts?.value;
    final deviceTile = _deviceNameTile(context);
    if (book == null) {
      return [
        if (deviceTile != null) deviceTile,
        if (_paired)
          _connectedTile(context) //
        else if (widget.onOpenPairing != null)
          _pairingTile(context),
      ];
    }
    final active = book.active;
    if (active == null) {
      return [
        if (deviceTile != null) deviceTile,
        if (widget.onOpenPairing != null) _pairingTile(context),
      ];
    }
    return [
      if (deviceTile != null) deviceTile,
      _activeHostTile(context, active),
      for (final h in book.hosts) //
        if (h.id != active.id) _otherHostTile(context, h),
      if (widget.onOpenPairing != null) _addHostTile(context),
    ];
  }

  /// 本机名称行:配对/登录时上报给网关的 device 字段(宿主设备表展示)。
  /// 默认「设备类型-无权限机器特征」,随时可改(持久化,下次配对即用新名)。
  Widget? _deviceNameTile(BuildContext context) {
    final name = widget.deviceName;
    final onSet = widget.onSetDeviceName;
    if (name == null || onSet == null) return null;
    return ValueListenableBuilder<String?>(
      valueListenable: name,
      builder: (context, value, _) => ListTile(
        leading: const Icon(Icons.smartphone, size: 20),
        title: Text(
          value == null || value.isEmpty ? '本机名称' : '本机名称 · $value',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: const Text('配对时展示给电脑的设备名', style: TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.edit_outlined, size: 18),
        onTap: () =>
            showDeviceNameDialog(context, current: value ?? '', onSet: onSet),
      ),
    );
  }

  /// 活动主机行:机器名(dsh-mobile plugin 的 label,默认设备名、宿主可改)
  /// + 实时连接相位(事件 WS 就绪 = 绿)。未连接给「重连」按钮(authBlocked
  /// 亦复位重启);每行可删除(删活动主机自动切到剩余首条)。
  Widget _activeHostTile(BuildContext context, StoredCredentials host) {
    final status = widget.hostStatus?.value;
    final up = status?.up ?? false;
    final machine = (status?.machine.isNotEmpty ?? false)
        ? status!.machine
        : host.hostLabel;
    final title = _hostConnectionTitle(
      connected: up,
      machine: machine,
      disconnectedFallback: host.baseUri.authority,
    );
    return ListTile(
      leading: Icon(
        Icons.dns_outlined,
        size: 20,
        color: up ? Colors.green : Theme.of(context).colorScheme.outline,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        up ? 'DSH 服务在线,会话可用' : '连接中断,自动重连中',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!up && widget.onReconnect != null)
            IconButton(
              tooltip: '重连',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: widget.onReconnect,
            ),
          if (widget.onRemoveHost != null)
            IconButton(
              tooltip: '删除主机',
              icon: Icon(
                Icons.delete_outline,
                size: 20,
                color: Theme.of(context).colorScheme.error,
              ),
              onPressed: () =>
                  _confirmRemoveHost(context, host, isActive: true),
            ),
        ],
      ),
    );
  }

  /// 其他已配对主机行:点击切换(整代重装到该网关);行尾删除。
  Widget _otherHostTile(BuildContext context, StoredCredentials host) {
    final label = host.hostLabel.isEmpty
        ? host.baseUri.authority
        : host.hostLabel;
    return ListTile(
      leading: const Icon(Icons.lan_outlined, size: 20),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        host.hostLabel.isEmpty ? '点击切换到此主机' : host.baseUri.authority,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: widget.onRemoveHost == null
          ? const Icon(Icons.swap_horiz, size: 18)
          : IconButton(
              tooltip: '删除主机',
              icon: Icon(
                Icons.delete_outline,
                size: 20,
                color: Theme.of(context).colorScheme.error,
              ),
              onPressed: () =>
                  _confirmRemoveHost(context, host, isActive: false),
            ),
      onTap: widget.onSwitchHost == null
          ? null
          : () => widget.onSwitchHost!(host.id),
    );
  }

  /// 添加主机行:多主机形态下的「发起配对」(向簿追加而非替换)。
  Widget _addHostTile(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.add, size: 20),
      title: const Text('添加主机(配对)'),
      subtitle: const Text(
        '生成配对码,与另一台运行 DSH 的电脑配对',
        style: TextStyle(fontSize: 12),
      ),
      onTap: widget.onOpenPairing,
    );
  }

  /// 删除主机确认(参照提供方删除;活动主机额外说明切换去向)。
  Future<void> _confirmRemoveHost(
    BuildContext context,
    StoredCredentials host, {
    required bool isActive,
  }) async {
    final name = host.hostLabel.isEmpty
        ? host.baseUri.authority
        : host.hostLabel;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除主机'),
        content: Text(
          isActive
              ? '将移除「$name」的配对凭证,当前连接会切换到其他已配对主机。此操作不可撤销。'
              : '将移除「$name」的配对凭证。此操作不可撤销。',
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
    await widget.onRemoveHost?.call(host.id);
  }

  /// 旧形态(hosts 未注入)的状态行,语义同 _activeHostTile 但无操作按钮。
  Widget _connectedTile(BuildContext context) {
    final status = widget.hostStatus!.value;
    final machine = status.machine;
    final title = _hostConnectionTitle(
      connected: status.up,
      machine: machine,
      disconnectedFallback: '未连接',
    );
    return ListTile(
      leading: Icon(
        Icons.dns_outlined,
        size: 20,
        color: status.up ? Colors.green : Theme.of(context).colorScheme.outline,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        status.up ? 'DSH 服务在线,会话可用' : '连接中断,自动重连中',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Icon(
        status.up ? Icons.check_circle : Icons.sync,
        size: 18,
        color: status.up ? Colors.green : null,
      ),
    );
  }

  Widget _providerTile(BuildContext context, ProviderEntry p) {
    String subtitle;
    if (p.credentialRef != null) {
      subtitle = p.credentialRef!;
    } else if (p.routable) {
      subtitle = '可路由';
    } else {
      subtitle = '未配置';
    }

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
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
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
              child: Text(
                '默认权限预设',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
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
      onTap: () => _runSafe(context, () async {
        await widget.store.openDocument();
      }, success: '已请求打开配置文件'),
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
      () => widget.store.scope(widget.entry.namespace).setField([
        ...widget.entry.settingsPath,
        'baseURL',
      ], value),
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
      () => widget.store.scope(widget.entry.namespace).setField([
        ...widget.entry.settingsPath,
        'models',
      ], selected),
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
    final ok = await _runSafe(context, () async {
      await widget.store
          .scope(widget.entry.namespace)
          .unsetField(widget.entry.settingsPath);
      final ref = widget.entry.credentialRef;
      if (ref != null) await widget.store.unsetCredential(ref);
    }, success: '已删除');
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
          _fieldLabel(
            context,
            'API 密钥',
            badge: entry.configured ? '已配置' : null,
          ),
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
          _fullButton(onPressed: _saveKey, label: '保存密钥'),
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
          _fullButton(onPressed: _saveBaseURL, label: '保存 Base URL'),
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
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
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
          const Text(
            '可路由',
            style: TextStyle(fontSize: 12, color: Colors.green),
          ),
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
          Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          if (badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                badge,
                style: const TextStyle(fontSize: 10, color: Colors.green),
              ),
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
        ? FilledButton(style: style, onPressed: onPressed, child: Text(label))
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

/// 非特权形态的特权分区占位说明(入口本身常驻,只有特权段隐藏)。
class _PrivilegeNote extends StatelessWidget {
  const _PrivilegeNote();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(12),
    child: Row(
      children: [
        Icon(Icons.lock_outline, size: 16),
        SizedBox(width: 6),
        Expanded(
          child: Text(
            '模型提供方与通用配置仅在桌面同机(loopback)或已鉴权远程形态可用',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

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
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
    messenger.showSnackBar(
      const SnackBar(content: Text(kSettingsConflictMessage)),
    );
    return false;
  } on Object catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('操作失败: ${_errorText(e)}')));
    return false;
  }
}
