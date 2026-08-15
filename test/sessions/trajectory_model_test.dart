// TrajectoryExtractor 域测试(W3-A):轮次分组 / 未闭合轮 / between-turns /
// 耗时 / 摘要(截断与回退)/ 乱序输入 / 角色分类 / 可重放不变式。
// 模式:自建最小事件流(纯 Dart,不 import 共享 helper;不碰 socket)。
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/trajectory_model.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 探针式假事件:time 缺省 = epoch ms 基准 + seq(单调递增)。
SessionEvent _ev(int seq, String type, dynamic data, {double? time}) => SessionEvent(
      type: type,
      seq: seq,
      time: time ?? 1786723605000 + seq.toDouble(),
      data: data,
    );

/// 便捷构造:turn/start。
SessionEvent _ts(int seq, {double? time}) => _ev(seq, 'turn/start', <String, dynamic>{}, time: time);

/// 便捷构造:turn/end。
SessionEvent _te(int seq, {double? time}) => _ev(seq, 'turn/end', <String, dynamic>{}, time: time);

/// 便捷构造:user 消息(文本块形态,走 event_text.extractText)。
SessionEvent _user(int seq, String text, {double? time}) => _ev(seq, 'user/message', {
      'content': <Map<String, dynamic>>[
        {'type': 'text', 'text': text},
      ],
    }, time: time);

/// 便捷构造:assistant 消息(文本块在 data.message.content,线上形状)。
SessionEvent _assistant(int seq, String text, {double? time}) => _ev(seq, 'assistant/message', {
      'message': <String, dynamic>{
        'content': <Map<String, dynamic>>[
          {'type': 'text', 'text': text},
        ],
      },
    }, time: time);

void main() {
  group('轮次分组', () {
    test('闭合轮:turn/start·turn/end 分组,分隔符不进行,角色/摘要正确', () {
      final view = TrajectoryExtractor.extract([
        _ts(1),
        _user(2, '你好'),
        _assistant(3, '收到'),
        _te(4),
      ]);
      expect(view.turns, hasLength(1));
      final turn = view.turns.single;
      expect(turn.inProgress, isFalse);
      expect(turn.startSeq, 1);
      expect(turn.endSeq, 4);
      expect(turn.rows, hasLength(2));
      expect(turn.rows[0].role, TrajectoryRole.user);
      expect(turn.rows[0].summary, '你好');
      expect(turn.rows[1].role, TrajectoryRole.assistant);
      expect(turn.rows[1].summary, '收到');
      // 全局有序项:只有一轮。
      expect(view.items, hasLength(1));
      expect(view.items.single, isA<TrajectoryTurnItem>());
    });

    test('未闭合尾轮 = 进行中(endSeq null;耗时取末行时间-start)', () {
      final view = TrajectoryExtractor.extract([
        _ts(1, time: 1000),
        _user(2, '进行中提问', time: 2500),
        _assistant(3, '尚未结束', time: 4000),
      ]);
      final turn = view.turns.single;
      expect(turn.inProgress, isTrue);
      expect(turn.endSeq, isNull);
      expect(turn.endTime, isNull);
      expect(turn.rows, hasLength(2));
      expect(turn.durationMs, 3000); // 4000 - 1000。
    });

    test('异常:新 turn/start 到来前轮未闭合 → 前轮按进行中收尾,再开新一轮', () {
      final view = TrajectoryExtractor.extract([
        _ts(1),
        _user(2, '第一轮'),
        _ts(3), // 缺 turn/end。
        _user(4, '第二轮'),
        _te(5),
      ]);
      expect(view.turns, hasLength(2));
      expect(view.turns[0].inProgress, isTrue);
      expect(view.turns[0].rows.single.summary, '第一轮');
      expect(view.turns[1].inProgress, isFalse);
      expect(view.turns[1].rows.single.summary, '第二轮');
      // 全局顺序:两轮依次。
      expect(view.items.map((e) => (e as TrajectoryTurnItem).turn.startSeq), [1, 3]);
    });

    test('空轮:turn/start 紧跟 turn/end → 零行轮,耗时 = end-start', () {
      final view = TrajectoryExtractor.extract([
        _ts(1, time: 1000),
        _te(2, time: 3000),
      ]);
      final turn = view.turns.single;
      expect(turn.rows, isEmpty);
      expect(turn.inProgress, isFalse);
      expect(turn.durationMs, 2000);
    });
  });

  group('between-turns', () {
    test('轮外 compaction 落 between 区段;轮内 compaction 归行', () {
      final view = TrajectoryExtractor.extract([
        _ts(1),
        _user(2, '第一轮'),
        _te(3),
        _ev(4, 'compaction/start', <String, dynamic>{}),
        _ev(5, 'compaction/summary', <String, dynamic>{'summary': '已压缩', 'messages': 3}),
        _ev(6, 'compaction/end', <String, dynamic>{}),
        _ts(7),
        _ev(8, 'compaction/summary', <String, dynamic>{'summary': '轮内压缩', 'messages': 1}),
        _te(9),
      ]);
      expect(view.turns, hasLength(2));
      expect(view.between, hasLength(3));
      expect(view.between[0].role, TrajectoryRole.compaction);
      expect(view.between[0].type, 'compaction/start');
      expect(view.between[1].summary, '已压缩');
      expect(view.between[2].type, 'compaction/end');
      // 轮内 compaction 是行(角色 compaction)。
      expect(view.turns[1].rows.single.type, 'compaction/summary');
      expect(view.turns[1].rows.single.role, TrajectoryRole.compaction);
      expect(view.turns[1].rows.single.summary, '轮内压缩');
    });

    test('无主 turn/end 与轮前事件归 between,全局顺序保持', () {
      final view = TrajectoryExtractor.extract([
        _ev(1, 'llm/retry', <String, dynamic>{'reason': '限流', 'attempt': 2}),
        _te(2), // 无主 turn/end。
        _ts(3),
        _user(4, '提问'),
        _te(5),
        _ev(6, 'turn/error', <String, dynamic>{'message': 'boom'}),
      ]);
      expect(view.between.map((r) => r.type).toList(), ['llm/retry', 'turn/end', 'turn/error']);
      expect(view.turns, hasLength(1));
      expect(view.turns.single.rows.single.summary, '提问');
      // 全局有序:轮外段(1,2)→ 轮(3..5)→ 轮外段(6)。
      final kinds = view.items.map((e) => e is TrajectoryTurnItem ? 'turn' : 'between').toList();
      expect(kinds, ['between', 'turn', 'between']);
      // 轮外行耗时无参考 → null。
      expect(view.between[0].durationMs, isNull);
    });
  });

  group('耗时', () {
    test('行耗时 = 与同轮上一事件(首行为 turn/start)的 time 差', () {
      final view = TrajectoryExtractor.extract([
        _ts(1, time: 1000),
        _user(2, 'a', time: 2500),
        _assistant(3, 'b', time: 4000),
        _ev(4, 'tool/call', <String, dynamic>{'toolName': 'bash'}, time: 7000),
        _te(5, time: 8000),
      ]);
      final turn = view.turns.single;
      expect(turn.rows[0].durationMs, 1500); // 2500-1000(turn/start)。
      expect(turn.rows[1].durationMs, 1500); // 4000-2500。
      expect(turn.rows[2].durationMs, 3000); // 7000-4000。
      expect(turn.durationMs, 7000); // 8000-1000。
    });
  });

  group('摘要', () {
    test('复用 extractText(assistant 嵌套 message.content)+ 换行折叠为单行', () {
      final view = TrajectoryExtractor.extract([
        _ts(1),
        _assistant(2, '第一行\n第二行\n\n第三行'),
        _te(3),
      ]);
      expect(view.turns.single.rows.single.summary, '第一行 第二行 第三行');
      expect(TrajectoryExtractor.fullSummary(view.turns.single.rows.single.event),
          '第一行\n第二行\n\n第三行');
    });

    test('截断 120:超长摘要裁剪并追加省略号', () {
      final long = '字' * 130;
      final view = TrajectoryExtractor.extract([
        _ts(1),
        _user(2, long),
        _te(3),
      ]);
      final s = view.turns.single.rows.single.summary;
      expect(s.length, 121); // 120 + '…'。
      expect(s.endsWith('…'), isTrue);
      expect(s.substring(0, 120), '字' * 120);
    });

    test('无文本回退:已知键(summary/error)优先,再紧凑 JSON 兜底', () {
      expect(TrajectoryExtractor.summaryOf(_ev(1, 'compaction/summary',
              <String, dynamic>{'summary': '已压缩到关键上下文', 'messages': 12})),
          '已压缩到关键上下文');
      expect(TrajectoryExtractor.summaryOf(_ev(1, 'turn/error',
              <String, dynamic>{'error': <String, dynamic>{'message': 'boom'}})),
          'boom');
      final tool = TrajectoryExtractor.summaryOf(_ev(
          1, 'tool/call', <String, dynamic>{'toolName': 'bash', 'args': <String, dynamic>{'cmd': 'ls'}}));
      expect(tool, '{"toolName":"bash","args":{"cmd":"ls"}}');
      // 标量 data 直出。
      expect(TrajectoryExtractor.summaryOf(_ev(1, 'x/y', '裸文本')), '裸文本');
    });
  });

  group('排序与可重放', () {
    test('乱序输入:按 seq 排序后分组(倒序输入同正序结果)', () {
      final events = <SessionEvent>[
        _te(5),
        _assistant(3, '收到'),
        _user(2, '你好'),
        _ts(1),
        _ts(7),
        _user(8, '第二轮'),
        _te(9),
      ];
      final view = TrajectoryExtractor.extract(events);
      expect(view.turns, hasLength(2));
      expect(view.turns[0].rows.map((r) => r.seq).toList(), [2, 3]);
      expect(view.turns[1].rows.map((r) => r.seq).toList(), [8]);
      expect(view.items, hasLength(2));
    });

    test('可重放:同输入两次提取逐字段一致', () {
      final events = <SessionEvent>[
        _ts(1),
        _user(2, '你好'),
        _ev(3, 'tool/call', <String, dynamic>{'toolName': 'bash'}),
        _te(4),
        _ev(5, 'compaction/start', <String, dynamic>{}),
      ];
      TrajectoryRow copy(TrajectoryRow r) =>
          TrajectoryRow(seq: r.seq, type: r.type, role: r.role, time: r.time,
              durationMs: r.durationMs, summary: r.summary, event: r.event);
      bool sameView(TrajectoryView a, TrajectoryView b) {
        if (a.turns.length != b.turns.length || a.between.length != b.between.length) {
          return false;
        }
        for (var i = 0; i < a.turns.length; i++) {
          final ta = a.turns[i];
          final tb = b.turns[i];
          if (ta.startSeq != tb.startSeq || ta.endSeq != tb.endSeq ||
              ta.inProgress != tb.inProgress || ta.rows.length != tb.rows.length) {
            return false;
          }
          for (var j = 0; j < ta.rows.length; j++) {
            final ra = copy(ta.rows[j]);
            final rb = copy(tb.rows[j]);
            if (ra.seq != rb.seq || ra.type != rb.type || ra.role != rb.role ||
                ra.time != rb.time || ra.durationMs != rb.durationMs ||
                ra.summary != rb.summary) {
              return false;
            }
          }
        }
        for (var i = 0; i < a.between.length; i++) {
          final ra = copy(a.between[i]);
          final rb = copy(b.between[i]);
          if (ra.seq != rb.seq || ra.type != rb.type || ra.summary != rb.summary) {
            return false;
          }
        }
        return true;
      }

      final first = TrajectoryExtractor.extract(events);
      final second = TrajectoryExtractor.extract(events);
      expect(sameView(first, second), isTrue);
    });

    test('空输入 → 空视图;纯 between 无轮', () {
      final empty = TrajectoryExtractor.extract(const <SessionEvent>[]);
      expect(empty.turns, isEmpty);
      expect(empty.between, isEmpty);
      expect(empty.items, isEmpty);
      final onlyBetween = TrajectoryExtractor.extract([
        _ev(1, 'compaction/start', <String, dynamic>{}),
        _ev(2, 'compaction/end', <String, dynamic>{}),
      ]);
      expect(onlyBetween.turns, isEmpty);
      expect(onlyBetween.between, hasLength(2));
    });
  });

  group('角色分类', () {
    test('全部角色:user/assistant/tool/compaction/retry/error/other', () {
      expect(TrajectoryExtractor.roleOf('user/message'), TrajectoryRole.user);
      expect(TrajectoryExtractor.roleOf('assistant/message'), TrajectoryRole.assistant);
      expect(TrajectoryExtractor.roleOf('tool/call'), TrajectoryRole.tool);
      expect(TrajectoryExtractor.roleOf('tool:bash'), TrajectoryRole.tool);
      expect(TrajectoryExtractor.roleOf('compaction/summary'), TrajectoryRole.compaction);
      expect(TrajectoryExtractor.roleOf('llm/retry'), TrajectoryRole.retry);
      expect(TrajectoryExtractor.roleOf('turn/error'), TrajectoryRole.error);
      expect(TrajectoryExtractor.roleOf('queue/update'), TrajectoryRole.other);
    });
  });
}
