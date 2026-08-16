// TodoPanel — 会话任务列表面板(web dsh-client-ui-conversation TodoDock 复刻)。
//
// 数据语义(web dsh-client-connection projectionValuesOf/backscanTodos):
// - host 工具 tool-todo(todo_write)每次调用向会话日志追加一条
//   todo/write 快照事件(data.todos = 整份清单,whole-list replacement);
// - 客户端 backscan:从日志尾部向前找,先遇 turn/start → 清单随上一轮
//   退役(返回空),先遇 todo/write → 该份即当前清单;
// - 面板挂在输入区上方(web conversation.input.dock order 0),空清单不渲染。
//
// 形态(web TodoPanel):默认折叠;头行 = checklist 图标 + 「任务」 +
// 进度摘要(N 已完成 · N 进行中 · N 待处理,零计数段省略)+ 展开箭头;
// 展开后逐项:状态图形(completed 实心对勾圈 / in_progress 旋转环 /
// pending 虚线环)+ 内容文本。触控目标 ≥44dp。
import 'package:flutter/material.dart';

import 'package:singleman/wire/generated/wire_generated.dart';

/// 单条任务(host TodoItem:content + status 三态)。
class SessionTodoItem {
  const SessionTodoItem({required this.content, required this.status});
  final String content;
  final String status;

  bool get completed => status == 'completed';
  bool get inProgress => status == 'in_progress';
}

/// 从 todo/write 事件的 data 解析;形状异常按缺省丢弃(容错,不抛)。
List<SessionTodoItem> parseTodoItems(dynamic data) {
  if (data is! Map) return const <SessionTodoItem>[];
  final raw = data['todos'];
  if (raw is! List) return const <SessionTodoItem>[];
  return [
    for (final item in raw)
      if (item is Map && item['content'] is String)
        SessionTodoItem(
          content: item['content'] as String,
          status: item['status'] is String ? item['status'] as String : 'pending',
        ),
  ];
}

/// 当前任务清单(web backscanTodos 的纯函数版):尾部向前,先遇
/// turn/start → 上一轮清单退役(空);先遇 todo/write → 该份清单。
List<SessionTodoItem> backscanSessionTodos(List<SessionEvent> events) {
  for (var i = events.length - 1; i >= 0; i--) {
    final e = events[i];
    if (e.type == 'turn/start') return const <SessionTodoItem>[];
    if (e.type == 'todo/write') return parseTodoItems(e.data);
  }
  return const <SessionTodoItem>[];
}

/// 进度摘要(web progressLabel):零计数段省略,· 连接。
String todoProgressLabel(List<SessionTodoItem> todos) {
  final done = todos.where((t) => t.completed).length;
  final active = todos.where((t) => t.inProgress).length;
  final pending = todos.length - done - active;
  final segments = <String>[
    if (done > 0) '$done 已完成',
    if (active > 0) '$active 进行中',
    if (pending > 0) '$pending 待处理',
  ];
  return segments.isEmpty ? '0 项' : segments.join(' · ');
}

/// 任务面板:默认折叠,点击头行展开/收起;空清单不渲染。
class TodoPanel extends StatefulWidget {
  const TodoPanel({super.key, required this.todos});

  final List<SessionTodoItem> todos;

  @override
  State<TodoPanel> createState() => _TodoPanelState();
}

class _TodoPanelState extends State<TodoPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final todos = widget.todos;
    if (todos.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '任务',
      child: Container(
        key: const ValueKey('todo-panel'),
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow.withValues(alpha: .92),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: .5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 头行:checklist + 标题 + 进度摘要 + 箭头;整行可点(≥44dp)。
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _expanded = !_expanded),
              child: SizedBox(
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Icon(Icons.checklist, size: 16, color: colors.primary),
                      const SizedBox(width: 8),
                      Text(
                        '任务',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          todoProgressLabel(todos),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final t in todos)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: _TodoStatusGlyph(
                                completed: t.completed,
                                inProgress: t.inProgress,
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                t.content,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: t.completed
                                      ? colors.onSurfaceVariant
                                      : colors.onSurface,
                                  decoration: t.completed
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                            ),
                          ],
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
}

/// 状态图形:completed 实心对勾圈 / in_progress 旋转环 / pending 虚线环
/// (web StatusGlyph 14dp 语义)。
class _TodoStatusGlyph extends StatelessWidget {
  const _TodoStatusGlyph({required this.completed, required this.inProgress});

  final bool completed;
  final bool inProgress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (completed) {
      return Icon(Icons.check_circle, size: 16, color: colors.primary);
    }
    if (inProgress) {
      return SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: colors.tertiary,
        ),
      );
    }
    return CustomPaint(
      size: const Size(16, 16),
      painter: _DashedRingPainter(colors.onSurfaceVariant),
    );
  }
}

/// pending 虚线环(web PendingGlyph:r6.4 stroke1.2 dash 2.4)。
class _DashedRingPainter extends CustomPainter {
  const _DashedRingPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final radius = size.width / 2 - 1;
    final c = Offset(size.width / 2, size.height / 2);
    // 8 段虚线近似 web dash 2.4 2.4 的视觉密度。
    const segments = 8;
    const tau = 6.283185307179586;
    final sweep = tau / segments;
    for (var i = 0; i < segments; i++) {
      final start = i * sweep + sweep * .18;
      canvas.drawArc(Rect.fromCircle(center: c, radius: radius),
          start, sweep * .64, false, paint);
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
}
