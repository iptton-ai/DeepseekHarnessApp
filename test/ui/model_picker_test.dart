// 模型选择器 widget 测试(回归:点击模型后选中态必须跟随,应用返回正确值)。
// 历史 bug:RadioListTile 用字符串拼接 + split('') 反拆 provider/model,
// 分隔符丢失后点击任何模型 → _picked 变垃圾值 → 全部选项失去选中。
// 修复后选中判定走 record (provider, model) 值相等(对齐 web 结构化比较)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/ui/model_picker.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

SessionModelsValue _catalog() => SessionModelsValue(
      current: const ModelSelection(provider: 'p1', model: 'm1'),
      routable: true,
      groups: const [
        ModelProviderGroup(
          id: 'p1',
          name: '提供方一',
          models: [
            ModelCatalogModel(
              id: 'm1',
              name: '模型甲',
              reasoning: ModelReasoning(
                efforts: [
                  ModelReasoningEffort(id: 'low', name: '低'),
                  ModelReasoningEffort(id: 'high', name: '高'),
                ],
              ),
            ),
            ModelCatalogModel(id: 'm2', name: '模型乙'),
          ],
        ),
        ModelProviderGroup(
          id: 'p2',
          name: '提供方二',
          models: [ModelCatalogModel(id: 'm3', name: '模型丙')],
        ),
      ],
      failures: const [],
    );

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            key: const ValueKey('open'),
            onPressed: () => showModelPicker(
              context,
              loadCatalog: () async => _catalog(),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pumpAndSettle();
}

/// 展开指定分组(默认只有 current 所在组展开,其余收起)。
Future<void> _expand(WidgetTester tester, String groupName) async {
  await tester.tap(find.text(groupName));
  await tester.pumpAndSettle();
}

/// 选中不变式:groupValue 全局一致、非空,且**恰好一个** tile 的 value 命中
/// (零命中 = bug 形态「全部未选中」;多命中 = 选中态歧义)。
void expectExactlyOneSelected(WidgetTester tester) {
  // byType(RadioListTile) 推断为 RadioListTile<dynamic>,匹配不到具体泛型
  // 实例 —— 必须用 is 判型的 predicate。
  final tiles = tester
      .widgetList<RadioListTile<(String, String)>>(
          find.byWidgetPredicate((w) => w is RadioListTile<(String, String)>))
      .toList();
  expect(tiles, isNotEmpty);
  final combo = tiles.first.groupValue;
  expect(combo, isNotNull, reason: 'groupValue 不允许为 null(全部未选中)');
  for (final t in tiles) {
    expect(t.groupValue, combo, reason: 'groupValue 必须全局一致');
  }
  final hits =
      tiles.where((t) => t.value == (combo as (String, String))).length;
  expect(hits, 1,
      reason: '恰好一个 tile 选中;0 = 全部未选中(用户实报 bug),>1 = 歧义');
}

void main() {
  testWidgets('打开即选中 current(p1/m1)', (tester) async {
    await _open(tester);
    expectExactlyOneSelected(tester);
    final m1 = tester.widget<RadioListTile<(String, String)>>(
        find.byWidgetPredicate((w) =>
            w is RadioListTile<(String, String)> && w.value.$2 == 'm1'));
    expect(m1.value, m1.groupValue, reason: 'current 模型应处于选中态');
  });

  testWidgets('点击同组其它模型:选中态跟随到新模型(回归:曾全部失去选中)',
      (tester) async {
    await _open(tester);
    await tester.tap(find.text('模型乙'));
    await tester.pump();
    expectExactlyOneSelected(tester);
    final m2 = tester.widget<RadioListTile<(String, String)>>(
        find.byWidgetPredicate((w) =>
            w is RadioListTile<(String, String)> && w.value.$2 == 'm2'));
    expect(m2.value, m2.groupValue, reason: '点击的模型应选中');
  });

  testWidgets('点击跨组模型:groupValue 切到 (p2, m3) 且仍恰一个选中', (tester) async {
    await _open(tester);
    await _expand(tester, '提供方二');
    await tester.tap(find.text('模型丙'));
    await tester.pump();
    expectExactlyOneSelected(tester);
    final m3 = tester.widget<RadioListTile<(String, String)>>(
        find.byWidgetPredicate((w) =>
            w is RadioListTile<(String, String)> && w.value.$2 == 'm3'));
    expect(m3.groupValue, const ('p2', 'm3'));
    expect(m3.value, m3.groupValue);
  });

  testWidgets('推理力度随模型切换联动;无力度模型下拉消失', (tester) async {
    await _open(tester);
    // m1 带推理力度:下拉出现。
    expect(find.text('推理力度'), findsOneWidget);
    // 切到 m3(无推理力度)→ 下拉消失。
    await _expand(tester, '提供方二');
    await tester.tap(find.text('模型丙'));
    await tester.pump();
    expect(find.text('推理力度'), findsNothing);
    // 切回 m1 → 下拉恢复,默认 efforts.first。
    await tester.tap(find.text('模型甲'));
    await tester.pump();
    expect(find.text('推理力度'), findsOneWidget);
  });

  testWidgets('应用返回所点的 provider/model', (tester) async {
    ModelPickerResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () async {
                result = await showModelPicker(
                  context,
                  loadCatalog: () async => _catalog(),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    await _expand(tester, '提供方二');
    await tester.tap(find.text('模型丙'));
    await tester.pump();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.provider, 'p2');
    expect(result!.model, 'm3');
    expect(result!.reasoningEffort, isNull);
  });

  testWidgets('长目录不穿透 dialog:小屏 30 模型无溢出异常(用户实报回归)',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final bigCatalog = SessionModelsValue(
      current: const ModelSelection(provider: 'g0', model: 'm0'),
      routable: true,
      groups: [
        for (var g = 0; g < 3; g++)
          ModelProviderGroup(
            id: 'g$g',
            name: '组$g',
            models: [
              for (var m = 0; m < 10; m++)
                ModelCatalogModel(id: 'm$g-$m', name: '模型$g-$m'),
            ],
          ),
      ],
      failures: const [],
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () => showModelPicker(
                context,
                loadCatalog: () async => bigCatalog,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    // 红线:任何 RenderFlex 溢出都会以异常形式抛出。
    expect(tester.takeException(), isNull, reason: '长目录必须限高滚动,不穿透容器');
    // 全部展开也不溢出。
    for (var g = 1; g < 3; g++) {
      await tester.tap(find.text('组$g'));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('分组可展开/收起;默认只展开 current 所在组', (tester) async {
    await _open(tester);

    // p1(current 所在)默认展开;m1 tile 可见。
    expect(find.text('模型甲'), findsOneWidget);
    // p2 默认收起:m3 tile 不在树中。
    expect(find.text('模型丙'), findsNothing);

    // 展开 p2 → m3 出现;再收起 → 消失。
    await _expand(tester, '提供方二');
    expect(find.text('模型丙'), findsOneWidget);
    await _expand(tester, '提供方二');
    expect(find.text('模型丙'), findsNothing);

    // 展开态在选择变化后保持:p2 展开着选 m3;p1 从未动过仍展开,
    // 可直接切回 m1(点头部是 toggle,已展开的组再点会收起)。
    await _expand(tester, '提供方二');
    await tester.tap(find.text('模型丙'));
    await tester.pump();
    await tester.tap(find.text('模型甲'));
    await tester.pump();
    expectExactlyOneSelected(tester);
  });
}
