// CommandMenuSheet — W2-D 斜杠命令菜单(web commands + skill 合并复刻)。
//
// 形态(audit/orchestration.md §1.4/§3.4 + PLAN 移动硬性):
// - 底部 sheet(showModalBottomSheet),顶部搜索框常显 + 分组列表
// - 命令组:/name + description + input.hint;skill 组:现有 skill 菜单格式
//   (图标 auto_awesome/lock_outline + '/name' + description)
// - 行高 ≥48dp(硬性 ≥44);宽内容单行截断;hover 类交互在移动端降级为常显
// - 点击 = onPick(CommandMenuItem),由集成方决定派发(web ui-commands
//   dispatch 决策表:contribution/装饰命令 → 各自交互面;leadingInput 命令 →
//   回填输入框;裸命令 → execute;skill → 回填 '/name ' 文本,DSH-PROTOCOL §5)
// - fuzzy:filterMenu(前缀优先 + 子序列,大小写不敏感),简化版
// - 空目录/加载失败:内联提示 + 重试(搜索词保留)
// - 键盘弹起时 sheet 上移(MediaQuery.viewInsets)
import 'package:flutter/material.dart';
import 'package:singleman/sessions/command_store.dart';

/// 打开斜杠命令菜单(底部 sheet)。
///
/// [onPick] 收到点击项([CommandMenuItem],含 command/skill 类型);
/// 集成方自行决定派发:命令走 [CommandStoreView.execute],
/// skill 走 prompt 文本(session.prompt,dsh-tool-skill 在 pre-step 识别
/// '/name' token,DSH-PROTOCOL §5)。
Future<void> showCommandMenu(
  BuildContext context, {
  required String sessionId,
  required CommandStoreView store,
  required void Function(CommandMenuItem item) onPick,
  List<CommandMenuItem> extraItems = const <CommandMenuItem>[],
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (context) => _CommandMenuSheet(
      sessionId: sessionId,
      store: store,
      onPick: onPick,
      extraItems: extraItems,
    ),
  );
}

class _CommandMenuSheet extends StatefulWidget {
  const _CommandMenuSheet({
    required this.sessionId,
    required this.store,
    required this.onPick,
    this.extraItems = const <CommandMenuItem>[],
  });

  final String sessionId;
  final CommandStoreView store;
  final void Function(CommandMenuItem item) onPick;

  /// 客户端 contribution 行(web 对齐:如 /model 由客户端注册,非宿主目录),
  /// 合并进「命令」组;与宿主目录重名的项静默跳过(宿主行优先)。
  final List<CommandMenuItem> extraItems;

  @override
  State<_CommandMenuSheet> createState() => _CommandMenuSheetState();
}

class _CommandMenuSheetState extends State<_CommandMenuSheet> {
  final _searchController = TextEditingController();
  String _query = '';
  CommandMenu? _menu;
  Object? _loadError;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load(force: false);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({required bool force}) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final menu = await widget.store.listAll(widget.sessionId, force: force);
      if (!mounted) return;
      setState(() {
        _menu = menu;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  void _pick(CommandMenuItem item) {
    Navigator.pop(context);
    widget.onPick(item);
  }

  @override
  Widget build(BuildContext context) {
    final menu = _menu;
    return Padding(
      // 键盘弹起时 sheet 整体上移(移动端硬性:搜索框始终可见可输入)。
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              _buildSearch(),
              const Divider(height: 1),
              Flexible(child: _buildContent(menu)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '命令与技能',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          // 常显关闭钮(移动端无键盘 Escape 依赖,audit §1.4)。
          IconButton(
            key: const ValueKey('command-menu-close'),
            tooltip: '关闭',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TextField(
        key: const ValueKey('command-menu-search'),
        controller: _searchController,
        onChanged: (v) => setState(() => _query = v),
        decoration: const InputDecoration(
          hintText: '搜索命令或技能',
          prefixIcon: Icon(Icons.search, size: 18),
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        ),
        style: const TextStyle(fontSize: 14),
      ),
    );
  }

  Widget _buildContent(CommandMenu? menu) {
    if (_loading) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final error = _loadError;
    if (error != null || menu == null) {
      return _ErrorPane(
        message: '加载失败: ' + (error?.toString() ?? '未知错误'),
        onRetry: () => _load(force: true),
      );
    }
    // 客户端 contribution 行并入命令组(重名跳过,宿主目录优先 —— web
    // contribution 与宿主命令冲突时 fail loud,移动端降级为宿主行胜出)。
    final hostNames = menu.commands.map((c) => c.name).toSet();
    final allCommands = <CommandMenuItem>[
      ...menu.commands,
      for (final e in widget.extraItems)
        if (!hostNames.contains(e.name)) e,
    ];
    final filteredCommands = filterMenu(allCommands, _query);
    final filteredSkills = filterMenu(menu.skills, _query);
    final hasAny = filteredCommands.isNotEmpty || filteredSkills.isNotEmpty;

    // 扁平描述符 + ListView.builder 虚拟化:插件清单可达百级,一次性
    // children(shrinkWrap 全量测高)会卡滚动;widget 在 itemBuilder 懒构建。
    final entries = <_MenuEntry>[
      // 命令组错误位(agent-busy/失败)→ 内联提示 + 重试,菜单降级 skill-only。
      if (menu.degraded) const _MenuEntry.degraded(),
      if (filteredCommands.isNotEmpty) const _MenuEntry.header('命令'),
      for (final item in filteredCommands) _MenuEntry.item(item),
      if (filteredSkills.isNotEmpty) const _MenuEntry.header('技能'),
      for (final item in filteredSkills) _MenuEntry.item(item),
      if (!hasAny) const _MenuEntry.empty(),
    ];
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        return switch (e.kind) {
          _MenuEntryKind.degraded => _DegradedBanner(
              errorCode: menu.errorCode,
              errorMessage: menu.errorMessage,
              onRetry: () => _load(force: true),
            ),
          _MenuEntryKind.header => _GroupHeader(
              key: ValueKey('command-group-${e.title}'), title: e.title!),
          _MenuEntryKind.item => _itemRow(e.item!),
          _MenuEntryKind.empty => Padding(
              key: const ValueKey('command-menu-empty'),
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  _query.isEmpty ? '没有可用命令或技能' : '没有匹配项',
                  style: TextStyle(
                      fontSize: 13, color: Theme.of(context).disabledColor),
                ),
              ),
            ),
        };
      },
    );
  }

  Widget _itemRow(CommandMenuItem item) {
    final theme = Theme.of(context);
    final subtitle = _subtitle(item);
    return InkWell(
      key: ValueKey('command-item-' + item.name),
      onTap: () => _pick(item),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              item.isCommand
                  ? Icons.terminal
                  : (item.skillModelInvocable == false
                      ? Icons.lock_outline
                      : Icons.auto_awesome),
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.slash,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 命令组:description + input.hint;skill 组:description。
  String _subtitle(CommandMenuItem item) {
    final parts = <String>[];
    if (item.description.isNotEmpty) parts.add(item.description);
    if (item.hint != null && item.hint!.isNotEmpty) {
      parts.add('输入: ' + item.hint!);
    }
    return parts.join(' · ');
  }
}

/// 菜单扁平条目描述符(widget 构建推迟到 itemBuilder,列表虚拟化)。
enum _MenuEntryKind { degraded, header, item, empty }

class _MenuEntry {
  const _MenuEntry.degraded()
      : kind = _MenuEntryKind.degraded,
        title = null,
        item = null;
  const _MenuEntry.header(this.title)
      : kind = _MenuEntryKind.header,
        item = null;
  const _MenuEntry.item(this.item)
      : kind = _MenuEntryKind.item,
        title = null;
  const _MenuEntry.empty()
      : kind = _MenuEntryKind.empty,
        title = null,
        item = null;
  final _MenuEntryKind kind;
  final String? title;
  final CommandMenuItem? item;
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _DegradedBanner extends StatelessWidget {
  const _DegradedBanner({
    required this.errorCode,
    required this.errorMessage,
    required this.onRetry,
  });

  final String? errorCode;
  final String? errorMessage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = errorCode == 'agent-busy'
        ? '该会话不提供命令(子代理会话)'
        : ('命令目录加载失败'
            + (errorCode == null ? '' : ' (' + errorCode! + ')'));
    return Container(
      key: const ValueKey('command-menu-degraded'),
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason + (errorMessage == null || errorMessage!.isEmpty ? '' : ' · ' + errorMessage!),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
          ),
          TextButton(
            key: const ValueKey('command-menu-retry'),
            onPressed: onRetry,
            child: const Text('重试', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('command-menu-error'),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Colors.red)),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
