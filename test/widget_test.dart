// 冒烟:app 入口组装(SinglemanApp + ChatScreen)可构建。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:singleman/main.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

class _EmptyView implements SessionStoreView {
  @override
  Stream<List<SessionSummary>> get summaries => const Stream.empty();
  @override
  List<SessionSummary> get currentSummaries => const <SessionSummary>[];
  @override
  SessionLog logFor(String sessionId) => SessionLog(sessionId);

  @override
  Future<void> loadHistory(String sessionId) async {}

  @override
  Future<void> loadOlder(String sessionId) async {}

  @override
  Future<String> fork(String sessionId, {int? atSeq}) async => 'forked';
}

void main() {
  testWidgets('SinglemanApp builds with empty state', (tester) async {
    final vm = ChatViewModel(store: _EmptyView(), connection: null);
    await tester.pumpWidget(SinglemanApp(
      vm: vm,
      onNewSession: (_) async {},
      sender: (id, text) async {},
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('选择或创建一个会话开始对话'), findsOneWidget);
    vm.dispose();
  });
}
