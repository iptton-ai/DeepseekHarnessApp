// DirectoryBrowseSheet — W2-B 应用内目录浏览对话框(web directory-picker-browse 移动化复刻)。
//
// 形态(docs/audit/sidebar-layout.md §3 移动端注意):
// - 全屏底部 sheet(showModalBottomSheet + isScrollControlled + 95% 高度)
// - 顶=标题 + 面包屑(可点回跳,横向滚动)+ 当前路径行;隐藏开关常显(非 hover)
// - 中=单列逐级下钻列表(无 Miller 双栏;行 ≥48dp);加载/失败态内联,失败带重试
// - 底=新建文件夹(嵌套输入,冲突错误目录内提示)+「选择此目录」(当前层)+ 取消
// - 宽内容(面包屑/路径)横向滚动
//
// 集成:showDirectoryBrowseSheet(context, store, onConfirm) — onConfirm 以当前层
// 绝对路径回调(典型接线:确认后调 WorkspaceStore.create(path))。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/sessions/directory_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 打开应用内目录浏览对话框(全屏底部 sheet)。
/// [onConfirm] 在用户点「选择此目录」时以当前层绝对路径回调(弹层先关)。
Future<void> showDirectoryBrowseSheet(
  BuildContext context, {
  required DirectoryBrowserView store,
  required void Function(String path) onConfirm,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.95,
      child: _DirectoryBrowseSheet(store: store, onConfirm: onConfirm),
    ),
  );
}

class _DirectoryBrowseSheet extends StatefulWidget {
  const _DirectoryBrowseSheet({required this.store, required this.onConfirm});
  final DirectoryBrowserView store;
  final void Function(String path) onConfirm;

  @override
  State<_DirectoryBrowseSheet> createState() => _DirectoryBrowseSheetState();
}

class _DirectoryBrowseSheetState extends State<_DirectoryBrowseSheet> {
  DirectoryBrowserSnapshot _snap = const DirectoryBrowserSnapshot(
      currentPath: null, home: '', crumbs: <DirectoryEntry>[],
      entries: <DirectoryEntry>[], truncated: false, loading: false,
      error: null, failedPath: null, showHidden: false);
  StreamSubscription<DirectoryBrowserSnapshot>? _sub;
  final TextEditingController _nameCtrl = TextEditingController();
  String? _createError;
  bool _creating = false;

  /// initState 期间订阅流可能同步收到装载态快照(store 先 emit 再 await);
  /// 该窗口内不 setState(首帧 build 直接用 _snap),之后正常 setState。
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _snap = widget.store.current;
    _sub = widget.store.snapshots.listen((s) {
      if (!mounted) return;
      _snap = s;
      if (_ready) setState(() {});
    });
    // 进入即装载家目录(缺省 path)。
    _startLoad();
    _ready = true;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _startLoad() {
    unawaited(_safeList(null));
  }

  /// 下钻/回跳/重试统一入口;store 失败时快照自带 error(不清空当前层)。
  void _navigate(String? path) {
    setState(() => _createError = null);
    unawaited(_safeList(path));
  }

  /// 装载调用兜底:失败由 store 快照呈现(不清空当前层),这里吞掉 rethrow。
  Future<void> _safeList(String? path) async {
    try {
      await widget.store.listDirectory(path: path);
    } catch (_) {
      // 快照 error 已就绪;无事可做。
    }
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    final current = _snap.currentPath;
    if (name.isEmpty || current == null || _creating) return;
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      await widget.store.createDirectory(current, name);
      if (!mounted) return;
      _nameCtrl.clear();
      // 成功刷新当前层让新文件夹出现(web「自动选中新建项」移动端简化为刷新)。
      _navigate(current);
    } catch (e) {
      if (mounted) {
        setState(() => _createError = directoryCreateErrorMessage(e));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _confirm() {
    final path = _snap.currentPath ??
        (_snap.home.isEmpty ? null : _snap.home);
    if (path == null || _snap.loading) return;
    widget.onConfirm(path);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snap;
    final currentPath = snap.currentPath ??
        (snap.home.isEmpty ? null : snap.home);
    final canAct = currentPath != null && !snap.loading;
    return Padding(
      // 键盘避让(嵌套输入)。
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _title(),
          _breadcrumbBar(snap, currentPath),
          _pathLine(snap, currentPath),
          _hiddenToggle(snap),
          const Divider(height: 1),
          Expanded(child: _listArea(snap)),
          const Divider(height: 1),
          _createBar(snap),
          _actionsBar(canAct),
        ],
      ),
    );
  }

  Widget _title() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(children: [
        const Icon(Icons.folder_outlined, size: 18),
        const SizedBox(width: 8),
        const Text('选择目录',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        const Spacer(),
        IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ]),
    );
  }

  /// 面包屑:主页 + wire crumbs(去重主页);可点回跳,横向滚动(宽内容纪律)。
  Widget _breadcrumbBar(DirectoryBrowserSnapshot snap, String? currentPath) {
    final crumbs = snap.crumbs.where((c) => c.path != snap.home).toList();
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          _crumbChip(
            label: '主页',
            icon: Icons.home_outlined,
            active: snap.home.isNotEmpty && currentPath == snap.home,
            onTap: snap.loading ? null : () => _navigate(null),
          ),
          for (final c in crumbs)
            _crumbChip(
              label: c.name,
              icon: Icons.chevron_right,
              active: currentPath == c.path,
              onTap: snap.loading ? null : () => _navigate(c.path),
            ),
        ]),
      ),
    );
  }

  Widget _crumbChip({
    required String label,
    required IconData icon,
    required bool active,
    required VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36, maxWidth: 160),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: active ? scheme.primary.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: active ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// 当前绝对路径(横向滚动,宽内容纪律)。
  Widget _pathLine(DirectoryBrowserSnapshot snap, String? currentPath) {
    if (currentPath == null) return const SizedBox.shrink();
    return SizedBox(
      height: 26,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          currentPath,
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).hintColor),
        ),
      ),
    );
  }

  /// 隐藏开关:常显(移动端 hover→常显),SwitchListTile ≥44dp。
  Widget _hiddenToggle(DirectoryBrowserSnapshot snap) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      title: const Text('显示隐藏条目', style: TextStyle(fontSize: 13)),
      value: snap.showHidden,
      onChanged: widget.store.setShowHidden,
    );
  }

  /// 列表区:加载进度 + 错误横幅(带重试) + 单列条目。
  Widget _listArea(DirectoryBrowserSnapshot snap) {
    return Column(children: [
      if (snap.loading) const LinearProgressIndicator(minHeight: 2),
      if (snap.error != null) _errorBanner(snap),
      Expanded(child: _listBody(snap)),
    ]);
  }

  /// 错误横幅内联在列表顶部;重试目标 = 失败路径(首载失败 = 家目录)。
  Widget _errorBanner(DirectoryBrowserSnapshot snap) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer.withValues(alpha: 0.25),
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 2),
      child: Row(children: [
        Expanded(
          child: Text(snap.error!,
              style: TextStyle(fontSize: 12, color: scheme.error)),
        ),
        TextButton(
          style: TextButton.styleFrom(
              minimumSize: const Size(64, 44), padding: const EdgeInsets.symmetric(horizontal: 8)),
          onPressed: () => _navigate(snap.failedPath),
          child: const Text('重试', style: TextStyle(fontSize: 13)),
        ),
      ]),
    );
  }

  /// 单列逐级下钻列表(行 ≥48dp;点行 = 下钻一层)。
  Widget _listBody(DirectoryBrowserSnapshot snap) {
    final entries = snap.entries;
    if (entries.isEmpty && !snap.loading && snap.error == null) {
      return const Center(child: Text('此目录为空', style: TextStyle(fontSize: 13)));
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 52),
      itemBuilder: (context, i) {
        final e = entries[i];
        return ListTile(
          key: ValueKey<String>('dir-row-${e.path}'),
          minTileHeight: 48,
          leading: const Icon(Icons.folder_outlined, size: 20),
          title: Text(e.name,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
          onTap: snap.loading ? null : () => _navigate(e.path),
        );
      },
    );
  }

  /// 新建文件夹(嵌套输入)+ 创建按钮;冲突错误在输入区下方提示。
  Widget _createBar(DirectoryBrowserSnapshot snap) {
    final canCreate = snap.currentPath != null && !snap.loading && !_creating;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _nameCtrl,
                enabled: canCreate,
                decoration: const InputDecoration(
                  hintText: '新建文件夹名称',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _create(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                  minimumSize: const Size(72, 44)),
              onPressed: canCreate ? _create : null,
              child: const Text('创建', style: TextStyle(fontSize: 13)),
            ),
          ]),
          if (_createError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_createError!,
                  style: TextStyle(
                      fontSize: 12, color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }

  /// 底部操作:取消 + 「选择此目录」(当前层;装载中禁用)。
  Widget _actionsBar(bool canAct) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(children: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        const Spacer(),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
          onPressed: canAct ? _confirm : null,
          child: const Text('选择此目录'),
        ),
      ]),
    );
  }
}
