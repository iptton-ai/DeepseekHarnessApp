// ThemeModeRow — W3-C 主题设置行(设置页内嵌)。
//
// 复刻(docs/audit/sidebar-layout.md §8.3):Appearance 行三态选择 light/dark/system,
// 写入 settings ui-theme.preference;无其他 UI。
//
// 形态与移动硬性:
// - 三选一分段控件(浅色/深色/跟随系统),段高 48dp(硬性 ≥44)
// - 即时生效:点选先触发 onChanged 回调(集成方立即应用 MaterialApp themeMode),
//   再异步 CAS 持久化(经 ThemeStoreView.setMode);冲突/失败经 SnackBar 提示,
//   权威值由 store.preferences 流回写(本行自监听)
// - 域枚举 ThemePreference → Flutter ThemeMode 的映射在这里(themeModeOf),
//   域层保持纯 Dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/sessions/theme_store.dart';

/// ThemePreference(域枚举)→ Flutter ThemeMode 的 1:1 映射。
ThemeMode themeModeOf(ThemePreference preference) => switch (preference) {
  ThemePreference.system => ThemeMode.system,
  ThemePreference.light => ThemeMode.light,
  ThemePreference.dark => ThemeMode.dark,
};

/// 主题设置行:标题 + 三选一分段控件。
///
/// [onChanged] 在点选瞬间同步触发(即时生效);持久化由内部
/// [ThemeStoreView.setMode] 异步完成,冲突/失败 SnackBar 提示。
class ThemeModeRow extends StatefulWidget {
  const ThemeModeRow({super.key, required this.store, this.onChanged});

  final ThemeStoreView store;

  /// 点选即时回调(集成方在此应用主题,如 setState 切 MaterialApp.themeMode)。
  final ValueChanged<ThemePreference>? onChanged;

  @override
  State<ThemeModeRow> createState() => _ThemeModeRowState();
}

class _ThemeModeRowState extends State<ThemeModeRow> {
  StreamSubscription<ThemePreference>? _sub;
  late ThemePreference _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.store.current;
    _sub = widget.store.preferences.listen((p) {
      if (!mounted || p == _selected) return;
      setState(() => _selected = p);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _select(ThemePreference mode) {
    if (mode == _selected) return;
    setState(() => _selected = mode); // 即时视觉反馈。
    widget.onChanged?.call(mode); // 回调上抛,集成方即时应用。
    unawaited(_persist(mode));
  }

  Future<void> _persist(ThemePreference mode) async {
    try {
      await widget.store.setMode(mode);
    } on ThemeSettingsConflictError {
      _toast('配置已在别处修改,已重新加载');
    } catch (_) {
      _toast('主题保存失败,已恢复为当前值');
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '外观',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          _SegmentedControl(selected: _selected, onSelect: _select),
        ],
      ),
    );
  }
}

/// 三选一分段控件:浅色 / 深色 / 跟随系统;每段 48dp 触控区。
class _SegmentedControl extends StatelessWidget {
  const _SegmentedControl({required this.selected, required this.onSelect});

  final ThemePreference selected;
  final ValueChanged<ThemePreference> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          _segment(context, ThemePreference.light, Icons.light_mode, '浅色'),
          _segment(context, ThemePreference.dark, Icons.dark_mode, '深色'),
          _segment(
            context,
            ThemePreference.system,
            Icons.brightness_auto,
            '跟随系统',
          ),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    ThemePreference mode,
    IconData icon,
    String label,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isSelected = mode == selected;
    final fg = isSelected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        key: ValueKey('theme-segment-${mode.wireValue}'),
        borderRadius: BorderRadius.circular(9),
        onTap: () => onSelect(mode),
        child: Container(
          height: 48, // 硬性 ≥44dp 触控区。
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isSelected) ...[
                Icon(Icons.check, size: 16, color: fg),
                const SizedBox(width: 4),
              ],
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
