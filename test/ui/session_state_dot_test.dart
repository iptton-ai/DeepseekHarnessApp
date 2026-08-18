// SessionStateDot 渲染测试(M5,对齐 dsh web StateDot 规格):
// - idle 不渲染任何东西(标题左缘对齐保持);
// - running 渲染像素追逐(公开类型 SessionPixelChaseDot,非 loading 环);
// - unread/needsInput/error 渲染 halo 点(10% 光环 + 实心核)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/sessions/session_attention_store.dart';
import 'package:singleman/ui/session_state_dot.dart';

void main() {
  Widget host(SessionRowStatus status) => MaterialApp(
        home: Scaffold(
          body: Center(child: SessionStateDot(status: status)),
        ),
      );

  testWidgets('idle:零渲染', (tester) async {
    await tester.pumpWidget(host(SessionRowStatus.idle));
    expect(find.byType(SessionStateDot), findsOneWidget);
    expect(find.byType(SessionPixelChaseDot), findsNothing);
    expect(tester.getSize(find.byType(SessionStateDot)),
        const Size(0, 0),
        reason: 'SizedBox.shrink 不占空间');
  });

  testWidgets('running:像素追逐动画(非 CircularProgressIndicator)', (tester) async {
    await tester.pumpWidget(host(SessionRowStatus.running));
    expect(find.byType(SessionPixelChaseDot), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 动画在跑:推进 250ms 不抛异常、仍挂载。
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(SessionPixelChaseDot), findsOneWidget);
  });

  testWidgets('unread:halo 点(web success 绿)', (tester) async {
    await tester.pumpWidget(host(SessionRowStatus.unread));
    expect(find.byType(SessionPixelChaseDot), findsNothing);
    final dot = tester.widget<SessionStateDot>(find.byType(SessionStateDot));
    expect(dot.status, SessionRowStatus.unread);
  });

  testWidgets('needsInput / error:同样渲染 halo 点', (tester) async {
    await tester.pumpWidget(host(SessionRowStatus.needsInput));
    expect(find.byType(SessionPixelChaseDot), findsNothing);
    await tester.pumpWidget(host(SessionRowStatus.error));
    expect(find.byType(SessionPixelChaseDot), findsNothing);
    expect(find.byType(SessionStateDot), findsOneWidget);
  });
}
