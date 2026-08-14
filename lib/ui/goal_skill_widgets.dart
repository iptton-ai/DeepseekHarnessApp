// GoalPanel + SkillSheet(M4 UI):goal 状态卡 + skill 快捷菜单。
// 域层已就绪(GoalStore/SkillCatalog);这里只做展示与回调。
import 'package:flutter/material.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// goal 面板:当前 goalRef + 四个操作按钮。
class GoalPanel extends StatelessWidget {
  const GoalPanel({
    super.key,
    required this.ref,
    required this.busy,
    this.onCreate,
    this.onPause,
    this.onResume,
    this.onComplete,
    this.onEdit,
  });
  final GoalRef? ref;
  final bool busy;
  final VoidCallback? onCreate;
  final void Function(GoalRef ref)? onPause;
  final void Function(GoalRef ref)? onResume;
  final void Function(GoalRef ref)? onComplete;
  final void Function(GoalRef ref)? onEdit;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.flag, size: 16),
              const SizedBox(width: 6),
              Text('目标(ref rev ' + (ref?.revision.toString() ?? '-') + ')',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const Spacer(),
              if (busy) const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                if (ref == null)
                  ActionChip(label: const Text('新建目标', style: TextStyle(fontSize: 12)), onPressed: onCreate)
                else ...[
                  ActionChip(label: const Text('编辑', style: TextStyle(fontSize: 12)), onPressed: () => onEdit?.call(ref!)),
                  ActionChip(label: const Text('暂停', style: TextStyle(fontSize: 12)), onPressed: () => onPause?.call(ref!)),
                  ActionChip(label: const Text('恢复', style: TextStyle(fontSize: 12)), onPressed: () => onResume?.call(ref!)),
                  ActionChip(label: const Text('完成', style: TextStyle(fontSize: 12)), onPressed: () => onComplete?.call(ref!)),
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
