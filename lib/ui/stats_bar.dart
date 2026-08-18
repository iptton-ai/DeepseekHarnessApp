// SessionStatsBar — A3 会话统计条(web StatsLine 的移动等价物)。
//
// 位置:composer 正上方一行(web conversation.composer.dock 同位)。
// 形态:管道分隔的分组(轮数/步数 · LLM/工具耗时 · TTFT 均值/吞吐 ·
// 缓存命中/token);无数据分组整组缺席;超长省略号(全量在 tooltip)。
// 数据:ChatViewModel.stats(投影优先,本地折叠兜底,见 session_stats.dart)。
import 'package:flutter/material.dart';
import 'package:singleman/sessions/session_stats.dart';

class SessionStatsBar extends StatelessWidget {
  const SessionStatsBar({super.key, required this.stats});
  final SessionStats stats;

  @override
  Widget build(BuildContext context) {
    final groups = _groups();
    if (groups.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final line = groups.join('  |  ');
    return Tooltip(
      message: line,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text(
          line,
          key: const ValueKey('session-stats-bar'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.outline,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  /// 分组构造(镜像 web StatsLine:组内数据缺席即整组缺席)。
  List<String> _groups() {
    final out = <String>[];
    if (stats.steps > 0) {
      out.add('${stats.turns} 轮 · ${stats.steps} 步');
      final durations = <String>[];
      if (stats.llmMs > 0) {
        durations.add('LLM ${formatStatsDuration(stats.llmMs)}');
      }
      if (stats.toolMs > 0) {
        durations.add('工具 ${formatStatsDuration(stats.toolMs)}');
      }
      if (durations.isNotEmpty) out.add(durations.join(' · '));
      final speeds = <String>[];
      if (stats.ttftSteps > 0) {
        speeds.add(
          'TTFT 均值 ${formatStatsDuration(stats.ttftMs / stats.ttftSteps)}',
        );
      }
      final tps = tokensPerSecond(stats.decodeTokens, stats.decodeMs);
      if (tps != null) speeds.add(tps);
      if (speeds.isNotEmpty) out.add(speeds.join(' · '));
    }
    // token 组:有真实计费活动才出现(全失败会话只显示计数)。
    if (stats.inputTokens > 0 || stats.outputTokens > 0) {
      final billed = stats.inputTokens;
      if (billed > 0 && stats.cacheReadTokens > 0) {
        final pct = (stats.cacheReadTokens / billed * 100).round();
        out.add('缓存命中 $pct%');
      }
      out.add(
        '输入 ${formatTokens(stats.inputTokens)} · 输出 ${formatTokens(stats.outputTokens)}',
      );
    }
    return out;
  }
}
