// SessionStats — A3 会话统计条数据(web StatsLine/deriveStats + session-stats
// projection 的 Dart 等价物)。
//
// 数据优先级(对齐 web:投影优先,窗口折叠兜底):
// 1. `sessionStats` / `tokenUsage` 投影(SessionLog.projections,整日志口径,
//    分页/压缩不改数字);
// 2. 本地折叠 deriveSessionStats(镜像 session-stats projection 的 apply 语义:
//    step/start 锚定 llm 计时与 TTFT、tool/call→result 墙钟、usage 累计)。
//
// 纯 Dart、无 flutter 依赖;格式化对齐 web formatTokens/formatDuration
//(517/12.2K、45.2s/2m42s)。
import 'package:singleman/wire/generated/wire_generated.dart';

/// 会话统计快照(字段名镜像 sessionStats projection)。
class SessionStats {
  const SessionStats({
    this.turns = 0,
    this.steps = 0,
    this.llmMs = 0,
    this.toolMs = 0,
    this.ttftMs = 0,
    this.ttftSteps = 0,
    this.decodeMs = 0,
    this.decodeTokens = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
  });

  final int turns;
  final int steps;
  final double llmMs;
  final double toolMs;
  final double ttftMs;
  final int ttftSteps;
  final double decodeMs;
  final int decodeTokens;

  /// tokenUsage 投影字段(本地折叠时按 assistant/message usage 累计)。
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;

  bool get isEmpty => turns == 0 && steps == 0;

  /// 从投影构造(sessionStats + tokenUsage 两个 key;缺失字段回退 0)。
  factory SessionStats.fromProjections(
    Map<String, dynamic> stats,
    Map<String, dynamic>? usage,
  ) {
    int i(Map m, String k) => m[k] is num ? (m[k] as num).toInt() : 0;
    double d(Map m, String k) => m[k] is num ? (m[k] as num).toDouble() : 0.0;
    return SessionStats(
      turns: i(stats, 'turns'),
      steps: i(stats, 'steps'),
      llmMs: d(stats, 'llmMs'),
      toolMs: d(stats, 'toolMs'),
      ttftMs: d(stats, 'ttftMs'),
      ttftSteps: i(stats, 'ttftSteps'),
      decodeMs: d(stats, 'decodeMs'),
      decodeTokens: i(stats, 'decodeTokens'),
      inputTokens: usage == null ? 0 : i(usage, 'inputTokens'),
      outputTokens: usage == null ? 0 : i(usage, 'outputTokens'),
      cacheReadTokens: usage == null ? 0 : i(usage, 'cacheReadTokens'),
    );
  }
}

/// 本地折叠兜底(事件窗口口径;镜像 session-stats projection 的 apply):
/// - turns:assistant/message 出现过的 distinct turn;
/// - steps:非空 content 的 assistant/message 计数;
/// - llmMs:step/start → assistant/message 墙钟(同 turn/step);
/// - ttftMs:step/start → 首个含文本的 assistant/chunk 墙钟;
/// - decodeMs/decodeTokens:首 chunk → message 墙钟 × outputTokens(同步);
/// - toolMs:tool/call → tool/result 墙钟(callId 配对;未结算不计);
/// - tokens:各 message 的 usage 累计(inputTokens/outputTokens/cacheRead)。
SessionStats deriveSessionStats(List<SessionEvent> events) {
  final turns = <int>{};
  var steps = 0;
  var llmMs = 0.0;
  var toolMs = 0.0;
  var ttftMs = 0.0;
  var ttftSteps = 0;
  var decodeMs = 0.0;
  var decodeTokens = 0;
  var inputTokens = 0;
  var outputTokens = 0;
  var cacheReadTokens = 0;

  // step/start 计时锚 + 首 chunk 锚(键 'turn:step')。
  final stepStart = <String, double>{};
  final firstChunk = <String, double>{};
  final stepTtftDone = <String>{};
  // tool 计时:callId(或退化键)→ call 时间。
  final pendingCalls = <String, double>{};

  for (final e in events) {
    final d = e.data;
    switch (e.type) {
      case 'step/start':
        if (d is Map && d['turn'] is num && d['step'] is num) {
          stepStart['${d['turn']}:${d['step']}'] = e.time;
        }
      case 'assistant/chunk':
        if (d is Map && d['turn'] is num && d['step'] is num) {
          final chunk = d['chunk'];
          final hasText = chunk is Map &&
              ((chunk['type'] == 'text-delta' &&
                      chunk['text'] is String &&
                      (chunk['text'] as String).trim().isNotEmpty) ||
                  chunk['type'] == 'block-end');
          if (hasText) {
            final key = '${d['turn']}:${d['step']}';
            firstChunk.putIfAbsent(key, () => e.time);
          }
        }
      case 'assistant/message':
        if (d is! Map) continue;
        final msg = d['message'];
        final content = msg is Map ? msg['content'] : null;
        final hasContent = content is List && content.isNotEmpty;
        final key = d['turn'] is num && d['step'] is num
            ? '${d['turn']}:${d['step']}'
            : null;
        if (hasContent) {
          steps += 1;
          if (d['turn'] is num) {
            turns.add((d['turn'] as num).toInt());
          }
        }
        if (key != null) {
          final start = stepStart[key];
          if (start != null && hasContent) {
            llmMs += (e.time - start).clamp(0, double.infinity);
          }
          final fc = firstChunk[key];
          if (fc != null && start != null && !stepTtftDone.contains(key)) {
            ttftMs += (fc - start).clamp(0, double.infinity);
            ttftSteps += 1;
            stepTtftDone.add(key);
          }
          final usage = d['usage'];
          final out = usage is Map && usage['outputTokens'] is num
              ? (usage['outputTokens'] as num).toInt()
              : 0;
          if (fc != null && out > 0 && hasContent) {
            decodeMs += (e.time - fc).clamp(0, double.infinity);
            decodeTokens += out;
          }
        }
        final usage = d['usage'];
        if (usage is Map) {
          if (usage['inputTokens'] is num) {
            inputTokens += (usage['inputTokens'] as num).toInt();
          }
          if (usage['outputTokens'] is num) {
            outputTokens += (usage['outputTokens'] as num).toInt();
          }
          if (usage['cacheReadTokens'] is num) {
            cacheReadTokens += (usage['cacheReadTokens'] as num).toInt();
          }
        }
      case 'tool/call':
        if (d is Map) {
          final callId = d['callId'] is String ? d['callId'] as String? : null;
          final key = callId ?? 'seq:${e.seq}';
          pendingCalls[key] = e.time;
        }
      case 'tool/result':
        if (d is Map) {
          final msg = d['message'];
          final source = msg is Map ? msg['source'] : null;
          final callId =
              source is Map && source['callId'] is String
              ? source['callId'] as String?
              : null;
          final key = callId ?? 'seq:${e.seq}';
          final start = pendingCalls.remove(key);
          if (start != null) {
            toolMs += (e.time - start).clamp(0, double.infinity);
          }
        }
      default:
        break;
    }
  }
  return SessionStats(
    turns: turns.length,
    steps: steps,
    llmMs: llmMs,
    toolMs: toolMs,
    ttftMs: ttftMs,
    ttftSteps: ttftSteps,
    decodeMs: decodeMs,
    decodeTokens: decodeTokens,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cacheReadTokens: cacheReadTokens,
  );
}

/// 会话统计口径:投影优先,缺失时本地折叠(web StatsLine 同款决策)。
SessionStats sessionStatsOf(List<SessionEvent> events, Map<String, dynamic> projections) {
  final stats = projections['sessionStats'];
  if (stats is Map) {
    final usage = projections['tokenUsage'];
    return SessionStats.fromProjections(
      Map<String, dynamic>.from(stats),
      usage is Map ? Map<String, dynamic>.from(usage) : null,
    );
  }
  return deriveSessionStats(events);
}

/// web formatTokens:517 / 12.2K / 517K / 1.2M(三位数内一位小数)。
String formatTokens(int n) {
  String scaled(double v) =>
      v >= 100 ? v.round().toString() : ((v * 10).round() / 10).toString();
  if (n < 1000) return n.toString();
  if (n < 1000000) return '${scaled(n / 1000)}K';
  return '${scaled(n / 1000000)}M';
}

/// web formatDuration:45.2s(<1min)/ 2m42s。
String formatStatsDuration(double ms) {
  final s = ms / 1000;
  if (s < 60) return '${(s * 10).round() / 10}s';
  final whole = s.round();
  return '${whole ~/ 60}m${whole % 60}s';
}

/// 吞吐 tok/s(decodeMs>0 时)。
String? tokensPerSecond(int tokens, double decodeMs) {
  if (decodeMs <= 0 || tokens <= 0) return null;
  final v = tokens / (decodeMs / 1000);
  return v >= 100 ? '${v.round()}/s' : '${(v * 10).round() / 10} tok/s';
}
