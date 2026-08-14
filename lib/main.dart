// singleman — DSH 原生客户端(M2 最小聊天环)。
// 桌面同机形态(ADR-0004):默认 loopback 3080,全功能。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';

const kDefaultBase = 'http://127.0.0.1:3080';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final base = Uri.parse(kDefaultBase);

  final api = ApiClient(baseUri: base);
  final connection = ConnectionController(baseUri: base);
  final store = SessionStore(api: api, connection: connection);
  final interactor = InteractorStore(api: api, connection: connection);

  connection.start();
  store.start();

  final vm = ChatViewModel(store: store, connection: connection)..interactor = interactor;

  runApp(SinglemanApp(
    vm: vm,
    onNewSession: () async {
      try {
        await store.createSession();
      } on Object catch (e) {
        debugPrint('createSession failed: ' + e.toString());
      }
    },
    sender: (sessionId, text) async {
      await store.promptText(sessionId, text, clientTimeZone: 'UTC');
    },
  ));
}

class SinglemanApp extends StatelessWidget {
  const SinglemanApp({
    super.key,
    required this.vm,
    required this.onNewSession,
    required this.sender,
  });

  final ChatViewModel vm;
  final Future<void> Function() onNewSession;
  final Future<void> Function(String sessionId, String text) sender;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'singleman',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2E5EAA), useMaterial3: true),
      home: ChatSenderBinding(
        sender: sender,
        child: ChatScreen(vm: vm, onNewSession: onNewSession),
      ),
    );
  }
}
