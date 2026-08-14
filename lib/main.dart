// singleman — DSH 原生客户端(M2 最小聊天环)。
// 桌面同机形态(ADR-0004):默认 loopback 3080,全功能。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/model_picker.dart';

const kDefaultBase = 'http://127.0.0.1:3080';

final navigatorKey = GlobalKey<NavigatorState>();

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
    actions: SessionActions(
      onPickModel: () async {
        final sid = vm.selectedId;
        if (sid == null) return;
        final ctx = navigatorKey.currentContext;
        if (ctx == null) return;
        final result = await showModelPicker(ctx, loadCatalog: () => store.sessionModels(sid));
        if (result == null) return;
        try {
          await store.selectModel(sid,
              provider: result.provider,
              model: result.model,
              reasoningEffort: result.reasoningEffort);
        } on Object catch (e) {
          debugPrint('selectModel failed: ' + e.toString());
        }
      },
      onRename: (sessionId, title) async {
        try {
          await store.renameSession(sessionId, title);
        } on Object catch (e) {
          debugPrint('rename failed: ' + e.toString());
        }
      },
      onFork: (sessionId) async {
        try {
          await store.forkSession(sessionId);
        } on Object catch (e) {
          debugPrint('fork failed: ' + e.toString());
        }
      },
      onExport: (sessionId) async {
        try {
          final path = Directory.systemTemp.path + '/' + sessionId + '.zip';
          await store.exportSessionZip(sessionId, path);
          debugPrint('exported to ' + path);
        } on Object catch (e) {
          debugPrint('export failed: ' + e.toString());
        }
      },
    ),
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
    this.actions,
  });

  final ChatViewModel vm;
  final Future<void> Function() onNewSession;
  final Future<void> Function(String sessionId, String text) sender;
  final SessionActions? actions;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'singleman',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2E5EAA), useMaterial3: true),
      navigatorKey: navigatorKey,
      home: ChatSenderBinding(
        sender: sender,
        child: ChatScreen(vm: vm, onNewSession: onNewSession, actions: actions),
      ),
    );
  }
}
