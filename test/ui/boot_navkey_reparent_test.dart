// 回归(2026-08-18 真机实锤的坑):切主机换键重挂 + navigatorKey 必须
// 每代一份。
//
// 陷阱机制:MaterialApp 的 navigatorKey 是 GlobalKey。整代重装时新树
// 以同键注册,框架的 GlobalKey 改宗(reparenting)会把旧代「已停用但
// 未终结」的 Navigator 元素整体过继进新树 —— 旧 home(旧 vm/store 的
// 整个界面)存活于新树,换根键的重挂名存实亡:切主机界面不动、仅退出
// 重启可见。生产代码已改为 boot() 内每代创建独立键(main.dart
// `navKey`);本文件钉死两个方向:
//   1) 共享键(错误做法)→ 旧内容滞留(若框架语义变化此用例会红,提示
//      重新评估);
//   2) 每代新键(生产行为)→ 新内容接管。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({
  required Key rootKey,
  required GlobalKey<NavigatorState> navKey,
  required String label,
}) {
  return MaterialApp(
    key: rootKey,
    navigatorKey: navKey,
    home: Scaffold(body: Center(child: Text('page-$label'))),
  );
}

void main() {
  testWidgets('共享 navigatorKey(错误做法):换根键重挂后旧页面经 GlobalKey 改宗滞留',
      (tester) async {
    final shared = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_app(
      rootKey: const ValueKey('boot-a'),
      navKey: shared,
      label: 'gen-a',
    ));
    expect(find.text('page-gen-a'), findsOneWidget);

    await tester.pumpWidget(_app(
      rootKey: const ValueKey('boot-b'),
      navKey: shared,
      label: 'gen-b',
    ));
    await tester.pump();
    // 现行框架语义:同键 Navigator 被过继,旧 home 滞留(陷阱实录)。
    expect(find.text('page-gen-a'), findsOneWidget,
        reason: '若此断言失败 = 框架改宗语义变化,重新评估 navKey 策略');
    expect(find.text('page-gen-b'), findsNothing);
  });

  testWidgets('每代独立 navigatorKey(生产行为):换根键重挂后新页面接管',
      (tester) async {
    await tester.pumpWidget(_app(
      rootKey: const ValueKey('boot-a'),
      navKey: GlobalKey<NavigatorState>(),
      label: 'gen-a',
    ));
    expect(find.text('page-gen-a'), findsOneWidget);

    await tester.pumpWidget(_app(
      rootKey: const ValueKey('boot-b'),
      navKey: GlobalKey<NavigatorState>(),
      label: 'gen-b',
    ));
    await tester.pump();
    expect(find.text('page-gen-b'), findsOneWidget);
    expect(find.text('page-gen-a'), findsNothing,
        reason: '旧代页面必须随重挂消失 —— 切主机会话列表换新的机制前提');
  });
}
