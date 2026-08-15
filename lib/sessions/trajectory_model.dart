// TrajectoryExtractor — 轨迹视图纯客户端模型(W3-A;web trajectory 的移动化复刻)。
//
// 关键事实(DSH-PROTOCOL §9):轨迹视图零新 RPC —— 数据 = SessionLog 事件(已注入);
// web 的 getSnapshot/loadOlder 即 session.history 分页(SessionStore 已有)。本文件
// 是 SessionLog 上的纯客户端视图:轮次分组 / ledger 行 / 检查器数据来源。
//
// 契约(头注释即测试基线):
// - 纯函数、可重放:同输入必同输出,无外部状态
// - 输入乱序先按 seq 排序;turn/start·turn/end 分组
// - 未闭合尾轮 = 进行中(inProgress,endSeq == null);异常新轮出现时前轮按进行中收尾
// - 每轮含 List[TrajectoryRow]:seq/type/角色标记(user·assistant·tool·compaction·
//   retry·error·other)/耗时(与同轮上一事件或 turn/start 的 time 差,毫秒)/
//   摘要行(复用 event_text.extractText,截断 120)
// - Between-turns 区段:轮外事件(compaction/start|end 等落在轮外、无主 turn/end)
// - turn/start·turn/end 本身不进行(是分隔符,不产出行)
import 'dart:convert';

import 'package:singleman/sessions/event_text.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 行角色标记(web trajectory ledger 同款分类的移动化子集)。
enum TrajectoryRole { user, assistant, tool, compaction, retry, error, other }

/// 单行轨迹记录(轮内或轮外)。
class TrajectoryRow {
  const TrajectoryRow({
    required this.seq,
    required this.type,
    required this.role,
    required this.time,
    required this.summary,
    required this.event,
    this.durationMs,
  });

  final int seq;
  final String type;
  final TrajectoryRole role;

  /// 原始事件时间(epoch 毫秒,与 SessionEvent.time 同源)。
  final double time;

  /// 与同轮上一事件(首行为 turn/start)的 time 差,毫秒;轮外行/无可参考时为 null。
  final double? durationMs;

  /// 摘要行(截断 120;检查器用 [TrajectoryExtractor.fullSummary] 取全文)。
  final String summary;

  /// 来源事件(检查器原始 JSON 的出处)。
  final SessionEvent event;
}

/// 一个轮次(turn/start·turn/end 分组)。
class TrajectoryTurn {
  const TrajectoryTurn({
    required this.startSeq,
    required this.startTime,
    required this.rows,
    this.endSeq,
    this.endTime,
  });

  final int startSeq;

  /// 闭合轮 = turn/end 的 seq;进行中轮为 null。
  final int? endSeq;
  final double startTime;
  final double? endTime;

  /// 轮内行(seq 升序;不含 turn/start·turn/end 分隔符)。
  final List<TrajectoryRow> rows;

  /// 未闭合尾轮 = 进行中。
  bool get inProgress => endSeq == null;

  /// 轮耗时:闭合轮 = end-start;进行中轮 = 末行时间-start;空轮为 null。
  double? get durationMs =>
      endTime != null ? endTime! - startTime : (rows.isEmpty ? null : rows.last.time - startTime);

  /// 轮尾 seq(闭合 = endSeq;进行中 = 末行 seq,空轮退化为 startSeq)。
  int get endOrLastSeq => endSeq ?? (rows.isEmpty ? startSeq : rows.last.seq);
}

/// 轮外区段:连续落在所有轮次之外的轨迹行(compaction/start|end 等)。
class TrajectoryBetween {
  const TrajectoryBetween({required this.rows});
  final List<TrajectoryRow> rows; // seq 升序
}

/// 全局有序视图项:轮次或轮外区段(UI 直接消费,保持全局 seq 顺序)。
sealed class TrajectoryItem {
  const TrajectoryItem();
}

class TrajectoryTurnItem extends TrajectoryItem {
  const TrajectoryTurnItem(this.turn);
  final TrajectoryTurn turn;
}

class TrajectoryBetweenItem extends TrajectoryItem {
  const TrajectoryBetweenItem(this.between);
  final TrajectoryBetween between;
}

/// 提取结果:全局有序项 + 轮次表 + 轮外行表(后两者为便捷投影)。
class TrajectoryView {
  const TrajectoryView({required this.items, required this.turns, required this.between});
  final List<TrajectoryItem> items;
  final List<TrajectoryTurn> turns;
  final List<TrajectoryRow> between;
}

/// 提取器(纯静态;纯函数、可重放)。
abstract final class TrajectoryExtractor {
  TrajectoryExtractor._();

  /// 摘要行截断上限。
  static const int summaryMax = 120;

  /// 核心入口:事件日志 → 全局有序视图。
  static TrajectoryView extract(List<SessionEvent> events) {
    final sorted = List<SessionEvent>.of(events)
      ..sort((a, b) => a.seq.compareTo(b.seq));
    final items = <TrajectoryItem>[];
    final turns = <TrajectoryTurn>[];
    final between = <TrajectoryRow>[];

    var inTurn = false;
    var openStartSeq = 0;
    var openStartTime = 0.0;
    final open = <SessionEvent>[]; // 轮内事件(不含 turn/start|end)
    final pending = <SessionEvent>[]; // 轮外事件缓冲

    void flushPending() {
      if (pending.isEmpty) return;
      final rows = <TrajectoryRow>[for (final e in pending) _row(e, null)];
      between.addAll(rows);
      items.add(TrajectoryBetweenItem(TrajectoryBetween(rows: rows)));
      pending.clear();
    }

    void closeTurn(SessionEvent? end) {
      final rows = <TrajectoryRow>[];
      double? prevTime = openStartTime; // 首行耗时相对 turn/start。
      for (final e in open) {
        rows.add(_row(e, prevTime));
        prevTime = e.time;
      }
      final turn = TrajectoryTurn(
        startSeq: openStartSeq,
        startTime: openStartTime,
        endSeq: end?.seq,
        endTime: end?.time,
        rows: rows,
      );
      turns.add(turn);
      items.add(TrajectoryTurnItem(turn));
      open.clear();
    }

    for (final e in sorted) {
      if (e.type == 'turn/start') {
        if (inTurn) closeTurn(null); // 异常:前轮未闭合 → 按进行中收尾。
        flushPending(); // 轮外缓冲先于新一轮落地,保持全局顺序。
        inTurn = true;
        openStartSeq = e.seq;
        openStartTime = e.time;
      } else if (e.type == 'turn/end') {
        if (inTurn) {
          closeTurn(e);
          inTurn = false;
        } else {
          pending.add(e); // 无主 turn/end → 轮外。
        }
      } else if (inTurn) {
        open.add(e);
      } else {
        pending.add(e);
      }
    }
    if (inTurn) closeTurn(null); // 未闭合尾轮 = 进行中。
    flushPending();
    return TrajectoryView(items: items, turns: turns, between: between);
  }

  /// 便捷投影:轮次表(按 startSeq 升序)。
  static List<TrajectoryTurn> turns(List<SessionEvent> events) => extract(events).turns;

  /// 便捷投影:轮外行表(按 seq 升序)。
  static List<TrajectoryRow> betweenRows(List<SessionEvent> events) => extract(events).between;

  /// 角色标记:按事件类型前缀分类(user·assistant·tool·compaction·retry·error·other)。
  static TrajectoryRole roleOf(String type) {
    if (type.startsWith('user/')) return TrajectoryRole.user;
    if (type.startsWith('assistant/')) return TrajectoryRole.assistant;
    if (type.startsWith('tool/') || type.startsWith('tool:')) return TrajectoryRole.tool;
    if (type.startsWith('compaction')) return TrajectoryRole.compaction;
    if (type.startsWith('llm/retry')) return TrajectoryRole.retry;
    if (type.startsWith('turn/error')) return TrajectoryRole.error;
    return TrajectoryRole.other;
  }

  /// 完整摘要(不截断;检查器用)。优先复用 event_text.extractText;
  /// 无文本时按已知键(summary/text/message/reason/error)回退,最后紧凑 JSON 兜底。
  static String fullSummary(SessionEvent event) {
    final text = extractText(event.data).trim();
    if (text.isNotEmpty) return text;
    return _fallbackText(event);
  }

  /// 摘要行(截断 [summaryMax];换行折叠为单行)。
  static String summaryOf(SessionEvent event, {int max = summaryMax}) =>
      _truncate(fullSummary(event), max);

  static String _fallbackText(SessionEvent event) {
    final data = event.data;
    if (data is! Map) {
      if (data is String) return data.trim();
      return _compact(data);
    }
    for (final k in const ['summary', 'text', 'message', 'reason', 'error']) {
      final v = data[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      // 嵌套错误/消息对象:{error: {message: '...'}} 等,解一层取可读文本。
      if (v is Map) {
        for (final ik in const ['message', 'text', 'summary']) {
          final iv = v[ik];
          if (iv is String && iv.trim().isNotEmpty) return iv.trim();
        }
      }
    }
    return _compact(data);
  }

  static String _compact(dynamic data) {
    if (data == null) return '';
    if (data is String || data is num || data is bool) return data.toString();
    try {
      return const JsonEncoder().convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  static String _truncate(String s, int max) {
    final out = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (out.length <= max) return out;
    return '${out.substring(0, max)}…';
  }

  static TrajectoryRow _row(SessionEvent e, double? prevTime) => TrajectoryRow(
        seq: e.seq,
        type: e.type,
        role: roleOf(e.type),
        time: e.time,
        durationMs: prevTime == null ? null : e.time - prevTime,
        summary: summaryOf(e),
        event: e,
      );
}
