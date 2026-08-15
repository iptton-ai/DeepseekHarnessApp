// ProducedFilesRow — W3-B 产出文件行(web dsh-client-ui-deliverables 复刻)。
//
// 输入契约(数据来源由集成方供给;本 widget 只消费路径列表):
// - [paths]:本轮完成产出的文件路径列表。集成方通常从修改工具调用附带的
//   locations 提取(渲染意图:diff 卡片或 kind=edit 的通用卡片),同路径一轮
//   首见一次去重 —— 提取属集成职责,见 docs/audit/settings-system.md §9
// - [onOpenFile]:可空;非空时 chip 可点,回调收到完整路径(集成方按会话 cwd
//   解析相对路径;loopback 特权可接 host.openPath)
//
// 形态(audit §9.3 + PLAN 移动硬性):
// - 单行 lane,最多 6 个 chip + 剩余计数 '+N 个文件';不换行不横向滚动
// - fitProducedFiles(web 同名算法):按可用宽/gap/chip 宽/精确余数宽取最大前缀,
//   剩余计数恒可见(Flutter 用 LayoutBuilder + TextPainter 测量)
// - chip = 文件名(basename),完整路径作 tooltip/title;chip 宽度上限 + 省略号
// - 触控目标 ≥44dp
import 'dart:math';

import 'package:flutter/material.dart';

/// chip 宽度上限(过长文件名省略号;保证 lane 总宽可收敛)。
const double kDeliverablesChipMaxWidth = 160;

/// chip 间距。
const double kDeliverablesGap = 8;

/// 单行 lane 最大 chip 数(web:至多 6 个,剩余计 '+N 个文件')。
const int kDeliverablesChipCap = 6;

/// fit 结果:可展示的前缀 chip 数 + 剩余计数。
class ProducedFilesFit {
  const ProducedFilesFit({required this.shownCount, required this.moreCount});
  final int shownCount;
  final int moreCount;
  bool get hasMore => moreCount > 0;
}

/// web fitProducedFiles 的纯函数版:给定每项自然宽度(含内边距)与可用宽,
/// 从大到小试前缀,取能放下的最大前缀;剩余计数恒可见。
/// [moreLabelWidth] 是 '+N 个文件' 的宽度测量(依赖 N,随前缀增大而缩小)。
ProducedFilesFit fitProducedFiles({
  required List<double> chipWidths,
  required double availableWidth,
  required double Function(int moreCount) moreLabelWidth,
  double gap = kDeliverablesGap,
  int cap = kDeliverablesChipCap,
}) {
  final n = chipWidths.length;
  if (n == 0) return const ProducedFilesFit(shownCount: 0, moreCount: 0);
  final maxShown = min(cap, n);
  for (var k = maxShown; k >= 0; k--) {
    final more = n - k;
    var width = 0.0;
    for (var i = 0; i < k; i++) {
      if (i > 0) width += gap;
      width += chipWidths[i];
    }
    if (more > 0 && k > 0) width += gap; // chip → 计数 label 的间隙。
    if (more > 0) width += moreLabelWidth(more);
    if (width <= availableWidth) {
      return ProducedFilesFit(shownCount: k, moreCount: more);
    }
  }
  // 防御:连计数 label 都放不下时只渲染计数。
  return ProducedFilesFit(shownCount: 0, moreCount: n);
}

/// 单行产出文件 lane:至多 6 chip + '+N 个文件',不换行不横向滚动。
class ProducedFilesRow extends StatelessWidget {
  const ProducedFilesRow({super.key, required this.paths, this.onOpenFile});

  /// 完整/相对路径列表(相对路径由集成方按会话 cwd 解析,见头注释)。
  final List<String> paths;

  /// 可空;非空时 chip 可点,回调收到完整路径。
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final chipStyle = TextStyle(
      fontSize: 13,
      color: theme.colorScheme.onSurfaceVariant,
    );
    final labelStyle = TextStyle(
      fontSize: 12,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final widths = <double>[
          for (final p in paths)
            min(_textWidth(context, _basename(p), chipStyle) + 20,
                kDeliverablesChipMaxWidth),
        ];
        double moreLabelWidth(int more) =>
            _textWidth(context, moreLabel(more), labelStyle);
        final fit = fitProducedFiles(
          chipWidths: widths,
          availableWidth: available,
          moreLabelWidth: moreLabelWidth,
        );
        return Row(
          key: const ValueKey('deliverables-lane'),
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < fit.shownCount; i++) ...[
              if (i > 0) const SizedBox(width: kDeliverablesGap),
              _chip(context, paths[i], i, chipStyle, widths[i]),
            ],
            if (fit.hasMore) ...[
              if (fit.shownCount > 0) const SizedBox(width: kDeliverablesGap),
              Text(
                moreLabel(fit.moreCount),
                key: const ValueKey('deliverables-more'),
                style: labelStyle,
              ),
            ],
          ],
        );
      },
    );
  }

  String moreLabel(int more) => '+' + more.toString() + ' 个文件';

  Widget _chip(
    BuildContext context,
    String path,
    int index,
    TextStyle style,
    double measuredWidth,
  ) {
    return Tooltip(
      message: path, // 完整路径:桌面 hover / 移动长按。
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: ValueKey('deliverables-chip-' + index.toString()),
          onTap: onOpenFile == null ? null : () => onOpenFile!(path),
          borderRadius: BorderRadius.circular(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: 44,
              maxWidth: measuredWidth,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Center(
                child: Text(
                  _basename(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 路径 basename('/' 与 '\\' 都认);无分隔符原样返回。
String _basename(String path) {
  final i = path.lastIndexOf('/');
  final j = path.lastIndexOf('\\');
  final k = i > j ? i : j;
  return k >= 0 ? path.substring(k + 1) : path;
}

double _textWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    maxLines: 1,
  )..layout();
  return painter.width;
}
