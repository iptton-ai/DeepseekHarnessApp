// SubagentCatalog UI 测试(W1-C 树形版):假 store 视图注入
// (SubagentStoreView + StreamController 手动 emit,对齐 todo_panel_test 惯例,
// 不碰 socket)。覆盖:入口按钮证据可见性/计数、目录页树形懒展开、
// transcript 页 composer 实时条件(parentAvailable/activity 随目录流)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/subagent_store.dart';
import 'package:singleman/ui/subagent_catalog.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 假 store:目录/后代/摘要手动 emit;prompt/interrupt 记录调用。
class _FakeSubagentStore implements SubagentStoreView {
  final _catalogsCtrl =
      StreamController<Map<String, SubagentCatalogState>>.broadcast();
  final _descCtrl =
      StreamController<Map<String, SubagentDescendants>>.broadcast();
  final Map<String, SubagentCatalogState> _catalogs = {};
  Map<String, SubagentDescendants> _descendants = {};
  final Map<String, SubagentTranscript> _transcripts = {};
  final Map<String, SessionSummary> _summaries = {};

  int promptCalls = 0;
  int interruptCalls = 0;
  List<String> listedParents = [];

  void emitCatalog(String parent, SubagentCatalogState state) {
    _catalogs[parent] = state;
    _catalogsCtrl.add(Map<String, SubagentCatalogState>.of(_catalogs));
  }

  void emitDescendants(Map<String, SubagentDescendants> map) {
    _descendants = map;
    _descCtrl.add(map);
  }

  void emitSummary(SessionSummary summary) {
    _summaries[summary.sessionId] = summary;
  }

  @override
  Stream<Map<String, SubagentCatalogState>> get catalogs => _catalogsCtrl.stream;
  @override
  Stream<Map<String, SubagentDescendants>> get descendants => _descCtrl.stream;
  @override
  Map<String, SubagentDescendants> get currentDescendants => _descendants;
  @override
  SubagentCatalogState? catalogFor(String parentSessionId) =>
      _catalogs[parentSessionId];
  @override
  SessionSummary? summaryFor(String sessionId) => _summaries[sessionId];
  @override
  SubagentTranscript transcriptFor(String childSessionId) =>
      _transcripts.putIfAbsent(
          childSessionId, () => SubagentTranscript(childSessionId));
  @override
  Future<SubagentCatalogState> listChildren(String parentSessionId,
      {bool force = false}) async {
    listedParents.add(parentSessionId);
    return _catalogs[parentSessionId] ??
        const SubagentCatalogState(
            entries: [],
            parentAvailable: false,
            phase: SubagentCatalogPhase.ready);
  }

  @override
  Future<List<SessionEvent>> readTranscript(
      String parentSessionId, String childSessionId,
      {required String mode, int? maxMessages, bool full = false}) async {
    transcriptFor(childSessionId);
    return const [];
  }

  @override
  Future<List<SessionEvent>> loadOlderTranscript(
      String parentSessionId, String childSessionId,
      {required String mode, int? maxMessages}) async {
    return const [];
  }

  @override
  Future<SubagentPromptValue> promptChild(
      String parentSessionId, String childSessionId, String text,
      {String? clientTimeZone}) async {
    promptCalls += 1;
    return const SubagentPromptValue(messageId: 'm1');
  }

  @override
  Future<SubagentInterruptValue> interruptChild(
      String parentSessionId, String childSessionId) async {
    interruptCalls += 1;
    return const SubagentInterruptValue(accepted: true);
  }

  @override
  Future<void> invalidateChildren(String parentSessionId) async {}

  Future<void> dispose() async {
    await _catalogsCtrl.close();
    await _descCtrl.close();
    for (final t in _transcripts.values) {
      await t.dispose();
    }
  }
}

SubagentListEntryChild row(String id, String mode, String activity,
        {String? label, bool hasChildren = false}) =>
    SubagentListEntryChild(
        id: id,
        mode: mode,
        activity: activity,
        hasChildren: hasChildren,
        label: label);

SubagentCatalogState catalog(List<SubagentListEntry> entries,
        {bool parentAvailable = true,
        SubagentCatalogPhase phase = SubagentCatalogPhase.ready}) =>
    SubagentCatalogState(
        entries: entries, parentAvailable: parentAvailable, phase: phase);

void main() {
  late _FakeSubagentStore store;

  setUp(() => store = _FakeSubagentStore());
  tearDown(() => store.dispose());

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('入口按钮:无目录且后代 0 → 不渲染', (tester) async {
    await tester.pumpWidget(wrap(SubagentEntryButton(
        store: store, parentSessionId: 'p1')));
    await tester.pump();
    expect(find.byIcon(Icons.account_tree_outlined), findsNothing);
  });

  testWidgets('入口按钮:目录空但后代>0 → 渲染(后代聚合是证据)', (tester) async {
    store.emitDescendants(
        {'p1': const SubagentDescendants(count: 3, runningCount: 0)});
    await tester.pumpWidget(wrap(SubagentEntryButton(
        store: store, parentSessionId: 'p1')));
    await tester.pump();
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    // running 0:tooltip 为总数,无 running 徽标文本。
    expect(find.byTooltip('3 个子代理'), findsOneWidget);
    expect(find.descendant(
        of: find.byType(Badge), matching: find.byType(Text)), findsNothing);
  });

  testWidgets('入口按钮:running 后代>0 → 徽标显 running 数;点击进目录页', (tester) async {
    store.emitCatalog('p1',
        catalog([row('c1', 'one-shot', 'inactive', label: '甲')]));
    store.emitDescendants(
        {'p1': const SubagentDescendants(count: 2, runningCount: 1)});
    await tester.pumpWidget(wrap(SubagentEntryButton(
        store: store, parentSessionId: 'p1')));
    await tester.pump();
    expect(find.byType(Badge), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // 徽标 running 数

    await tester.tap(find.byIcon(Icons.account_tree_outlined));
    await tester.pumpAndSettle();
    expect(find.text('子代理'), findsOneWidget);
    expect(find.text('甲'), findsOneWidget);
  });

  testWidgets('目录页:hasChildren 行展开触发子目录拉取,孙行出现;收起消失', (tester) async {
    // c1 的目录初始未装:展开动作本身触发拉取(懒展开)。
    store.emitCatalog('p1', catalog(
        [row('c1', 'continuable', 'inactive', label: '子', hasChildren: true)]));
    await tester.pumpWidget(wrap(SubagentCatalogPage(
        store: store, parentSessionId: 'p1')));
    await tester.pumpAndSettle();
    expect(find.text('子'), findsOneWidget);
    expect(find.text('孙'), findsNothing);

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(store.listedParents, contains('c1')); // 展开即拉子目录

    // 拉取完成回填(模拟响应到达):孙行出现。
    store.emitCatalog(
        'c1', catalog([row('g1', 'one-shot', 'inactive', label: '孙')]));
    await tester.pumpAndSettle();
    expect(find.text('孙'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    expect(find.text('孙'), findsNothing);
  });

  testWidgets('目录页:parentAvailable=false → 顶部横幅说明', (tester) async {
    store.emitCatalog('p1', catalog([row('c1', 'continuable', 'inactive')],
        parentAvailable: false));
    await tester.pumpWidget(wrap(SubagentCatalogPage(
        store: store, parentSessionId: 'p1')));
    await tester.pumpAndSettle();
    expect(find.text('父会话已结束,子代理仅可查看,无法续聊'), findsOneWidget);
  });

  testWidgets('目录页:行指标来自摘要投影 tokenUsage(键缺席隐藏)', (tester) async {
    store.emitCatalog(
        'p1', catalog([row('c1', 'one-shot', 'inactive', label: '甲')]));
    store.emitSummary(const SessionSummary(
      sessionId: 'c1',
      updatedAt: 1,
      running: false,
      blank: false,
      projections: SessionProjectionsBlock(asOfSeq: 1, values: {
        'tokenUsage': {
          'uncachedInputTokens': 1500,
          'outputTokens': 400,
          'cacheReadTokens': 0,
          'cacheWriteTokens': 0,
        },
      }),
    ));
    await tester.pumpWidget(wrap(SubagentCatalogPage(
        store: store, parentSessionId: 'p1')));
    await tester.pumpAndSettle();
    expect(find.text('1.9K tok'), findsOneWidget);
  });

  testWidgets('transcript 页:parentAvailable=false → 只读说明,无输入框', (tester) async {
    store.emitCatalog('p1', catalog(
        [row('c1', 'continuable', 'inactive', label: '甲')],
        parentAvailable: false));
    await tester.pumpWidget(wrap(SubagentTranscriptPage(
      store: store,
      parentSessionId: 'p1',
      child: row('c1', 'continuable', 'inactive', label: '甲'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('父会话不可用,无法续聊'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('transcript 页:one-shot → 一次性只读说明', (tester) async {
    store.emitCatalog(
        'p1', catalog([row('c1', 'one-shot', 'inactive', label: '乙')]));
    await tester.pumpWidget(wrap(SubagentTranscriptPage(
      store: store,
      parentSessionId: 'p1',
      child: row('c1', 'one-shot', 'inactive', label: '乙'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('一次性执行记录,已结束,不可续聊'), findsOneWidget);
  });

  testWidgets('transcript 页:可续聊 → 输入框;目录流翻 running → 输入换停止', (tester) async {
    store.emitCatalog('p1',
        catalog([row('c1', 'continuable', 'inactive', label: '甲')]));
    await tester.pumpWidget(wrap(SubagentTranscriptPage(
      store: store,
      parentSessionId: 'p1',
      child: row('c1', 'continuable', 'inactive', label: '甲'),
    )));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('停止'), findsNothing);

    // 目录流更新:行 activity → running(composer 实时切换)。
    store.emitCatalog('p1',
        catalog([row('c1', 'continuable', 'running', label: '甲')]));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('停止'), findsOneWidget);
  });

  testWidgets('transcript 页:可续聊发送走 promptChild', (tester) async {
    store.emitCatalog('p1',
        catalog([row('c1', 'continuable', 'inactive', label: '甲')]));
    await tester.pumpWidget(wrap(SubagentTranscriptPage(
      store: store,
      parentSessionId: 'p1',
      child: row('c1', 'continuable', 'inactive', label: '甲'),
    )));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '继续');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(store.promptCalls, 1);
    expect(find.text('已发送'), findsOneWidget);
  });

  // ---- 渲染节拍与主消息列表一致(StreamRebuildThrottle 共用)----

  SessionEvent ev(int seq, String type, Map<String, dynamic> data) =>
      SessionEvent(seq: seq, type: type, time: 0, data: data);

  Map<String, dynamic> chunkData(String text) => <String, dynamic>{
        'turn': 1,
        'step': 1,
        'chunk': <String, dynamic>{
          'type': 'text-delta',
          'text': text,
          'index': 0,
        },
      };

  testWidgets('transcript 页:纯 chunk 流走 250ms 慢档(窗口内不重算)',
      (tester) async {
    store.emitCatalog('p1',
        catalog([row('c1', 'continuable', 'running', label: '甲')]));
    await tester.pumpWidget(wrap(SubagentTranscriptPage(
      store: store,
      parentSessionId: 'p1',
      child: row('c1', 'continuable', 'running', label: '甲'),
    )));
    await tester.pumpAndSettle();

    bool markdownHas(String substring) => tester
        .widgetList<MarkdownBody>(find.byType(MarkdownBody))
        .any((w) => w.data.contains(substring));
    final transcript = store.transcriptFor('c1');

    // 空闲后首个 delta:leading 立即落地。
    // (广播流投递是独立 microtask,节流落地又排一层 microtask → 双 pump
    //  骑过微任务链 + 帧构建;与 ChatViewModel 既有节流测试的驱动方式同构。)
    transcript.append(ev(2, 'assistant/chunk', chunkData('首段')));
    await tester.pump();
    await tester.pump();
    expect(markdownHas('首段'), isTrue);

    // 窗口内后续 delta:推迟到尾沿(250ms),窗口内不出现。
    transcript.append(ev(3, 'assistant/chunk', chunkData('第二段')));
    await tester.pump();
    await tester.pump();
    expect(markdownHas('第二段'), isFalse);

    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(markdownHas('第二段'), isTrue);
  });

  testWidgets('transcript 页:结构变化(user/message)一帧不等待(快档)',
      (tester) async {
    store.emitCatalog('p1',
        catalog([row('c1', 'continuable', 'running', label: '甲')]));
    await tester.pumpWidget(wrap(SubagentTranscriptPage(
      store: store,
      parentSessionId: 'p1',
      child: row('c1', 'continuable', 'running', label: '甲'),
    )));
    await tester.pumpAndSettle();

    final transcript = store.transcriptFor('c1');
    // 先制造一次慢档落地(窗口起算)。
    transcript.append(ev(2, 'assistant/chunk', chunkData('流式中')));
    await tester.pump();
    await tester.pump();

    // 窗口内到达结构事件:立即渲染,不等 250ms 尾沿。
    transcript.append(ev(3, 'user/message', <String, dynamic>{
      'content': <Map<String, dynamic>>[
        {'type': 'text', 'text': '结构插入'},
      ],
    }));
    await tester.pump();
    await tester.pump();
    expect(find.text('结构插入'), findsOneWidget);
  });
}
