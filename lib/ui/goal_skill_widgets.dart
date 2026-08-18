// GoalPanel + SkillSheet(M4 UI):goal 状态卡 + skill 快捷菜单。
// 域层已就绪(GoalStore/SkillCatalog);这里只做展示与回调。
import 'package:flutter/material.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// goal 面板(A8 接线版):目标正文 + 阶段/轮次 + 操作按钮。
/// 数据 = 会话 `goal` 投影(投影形 Map;与 GoalRef 动作参数互转在此收口)。
class GoalPanel extends StatelessWidget {
  const GoalPanel({
    super.key,
    required this.projection,
    required this.busy,
    this.onCreate,
    this.onPause,
    this.onResume,
    this.onComplete,
    this.onEdit,
  });

  /// 会话 goal 投影值({goal:{…}, roundsStarted,…});null = 无目标。
  final Map<String, dynamic>? projection;
  final bool busy;
  final VoidCallback? onCreate;
  final void Function(GoalRef ref)? onPause;
  final void Function(GoalRef ref)? onResume;
  final void Function(GoalRef ref)? onComplete;
  final void Function(GoalRef ref)? onEdit;

  GoalRef? get _ref {
    final g = projection?['goal'];
    if (g is! Map) return null;
    final id = g['id'];
    final rev = g['revision'];
    if (id is! String || rev is! int) return null;
    return GoalRef(id: id, revision: rev);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final g = projection?['goal'];
    final goal = g is Map ? g : null;
    // 对齐 web GoalBar:有目标才渲染(空会话/无目标零渲染;
    // 新建走 composer 斜杠命令 /goal)。
    if (goal == null) return const SizedBox.shrink();
    final phase = goal['phase'];
    final objective = goal['objective'];
    final rounds = projection?['roundsStarted'];
    final phaseLabel = switch (phase) {
      'active' => '进行中',
      'paused' => '已暂停',
      'blocked' => '受阻',
      'complete' => '已完成',
      _ => null,
    };
    final phaseColor = switch (phase) {
      'active' => theme.colorScheme.primary,
      'paused' => Colors.orange.shade800,
      'blocked' => theme.colorScheme.error,
      'complete' => Colors.green.shade700,
      _ => theme.colorScheme.outline,
    };
    final ref = _ref;
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.flag_outlined, size: 15, color: phaseColor),
              const SizedBox(width: 6),
              const Text('目标',
                  key: ValueKey('goal-panel-title'),
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              if (phaseLabel != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: phaseColor.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(phaseLabel, style: TextStyle(fontSize: 10, color: phaseColor)),
                ),
              ],
              if (rounds is int) ...[
                const SizedBox(width: 6),
                Text('已续 $rounds 轮',
                    style: TextStyle(fontSize: 10, color: theme.colorScheme.outline)),
              ],
              const Spacer(),
              if (busy)
                const SizedBox(
                    width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
            if (objective is String && objective.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  objective,
                  key: const ValueKey('goal-panel-objective'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 0,
              children: [
                if (ref == null)
                  ActionChip(
                    label: const Text('新建目标', style: TextStyle(fontSize: 12)),
                    onPressed: onCreate,
                  )
                else ...[
                  ActionChip(
                      label: const Text('编辑', style: TextStyle(fontSize: 12)),
                      onPressed: () => onEdit?.call(ref)),
                  if (phase == 'active')
                    ActionChip(
                        label: const Text('暂停', style: TextStyle(fontSize: 12)),
                        onPressed: () => onPause?.call(ref))
                  else if (phase == 'paused')
                    ActionChip(
                        label: const Text('恢复', style: TextStyle(fontSize: 12)),
                        onPressed: () => onResume?.call(ref)),
                  if (phase != 'complete')
                    ActionChip(
                        label: const Text('完成', style: TextStyle(fontSize: 12)),
                        onPressed: () => onComplete?.call(ref)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// skill 快捷菜单:底部弹层列出目录,点选即发送 '/name'。
Future<String?> showSkillSheet(
  BuildContext context, {
  required Future<List<SkillEntry>> Function() load,
}) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (context) => FutureBuilder<List<SkillEntry>>(
      future: load(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text('加载失败: ' + snap.error.toString()),
          );
        }
        if (!snap.hasData) {
          return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
        }
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('技能(/name 即普通 prompt)', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              for (final s in snap.data!)
                ListTile(
                  dense: true,
                  leading: Icon(s.modelInvocable ? Icons.auto_awesome : Icons.lock_outline, size: 18),
                  title: Text('/' + s.name),
                  subtitle: Text(s.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, s.name),
                ),
            ],
          ),
        );
      },
    ),
  );
}
