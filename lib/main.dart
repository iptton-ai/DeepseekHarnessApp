// singleman — DSH 原生客户端(M2 最小聊天环)。
// 桌面同机形态(ADR-0004):默认 loopback 3080,全功能。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/attachment_fetch.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/sessions/directory_store.dart';
import 'package:singleman/sessions/goal_store.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/job_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/subagent_store.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/ui/goal_skill_widgets.dart';
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
  final goals = GoalStore(api: api);
  final skills = SkillCatalog(api: api);
  // W1 集成:四个新域 store,共用 api + connection(见 PLAN「W1 集成规格」)。
  final workspaces = WorkspaceStore(api: api, connection: connection);
  final jobs = JobStore(api: api, connection: connection);
  final subagents = SubagentStore(api: api, connection: connection);
  final settings = SettingsStore(api: api, connection: connection);
  final scope = scopeFor(base);
  // W2 集成:命令目录(斜杠菜单)/目录浏览(添加 workspace)/附件拉取(图片消息)。
  final commands = CommandStore(api: api, connection: connection, skills: skills);
  final directory = DirectoryBrowserStore(api: api);
  final attachments = AttachmentFetcher(api: api);

  connection.start();
  store.start();
  workspaces.start();

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
      onPickSkill: (_) async {
        final ctx = navigatorKey.currentContext;
        if (ctx == null) return;
        final name = await showSkillSheet(ctx, load: skills.list);
        if (name == null) return;
        final sid = vm.selectedId;
        if (sid == null) return;
        try {
          await store.promptText(sid, skills.promptFor(name), clientTimeZone: 'UTC');
        } on Object catch (e) {
          debugPrint('skill prompt failed: ' + e.toString());
        }
      },
    ),
    sender: (sessionId, text) async {
      await store.promptText(sessionId, text, clientTimeZone: 'UTC');
    },
    steerSender: (sessionId, text, steer) async {
      // W2:插话 = mode 'steer'(DSH-PROTOCOL §9);静止会话会收 steer-unavailable。
      await store.promptText(sessionId, text,
          mode: steer ? 'steer' : 'queue', clientTimeZone: 'UTC');
    },
    workspaces: workspaces,
    jobs: jobs,
    subagents: subagents,
    settings: settings,
    scope: scope,
    commands: commands,
    directory: directory,
    attachments: attachments,
    onCancelSession: (sessionId) async {
      try {
        await interactor.cancelSession(sessionId);
      } on Object catch (e) {
        debugPrint('cancel failed: ' + e.toString());
      }
    },
  ));
}

class SinglemanApp extends StatelessWidget {
  const SinglemanApp({
    super.key,
    required this.vm,
    required this.onNewSession,
    required this.sender,
    this.steerSender,
    this.actions,
    this.workspaces,
    this.jobs,
    this.subagents,
    this.settings,
    this.scope,
    this.commands,
    this.directory,
    this.attachments,
    this.onCancelSession,
  });

  final ChatViewModel vm;
  final Future<void> Function() onNewSession;
  final Future<void> Function(String sessionId, String text) sender;
  final Future<void> Function(String sessionId, String text, bool steer)? steerSender;
  final SessionActions? actions;
  final WorkspaceStore? workspaces;
  final JobStore? jobs;
  final SubagentStore? subagents;
  final SettingsStore? settings;
  final PrivilegeScope? scope;
  final CommandStore? commands;
  final DirectoryBrowserStore? directory;
  final AttachmentFetcher? attachments;
  final void Function(String sessionId)? onCancelSession;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'singleman',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2E5EAA), useMaterial3: true),
      navigatorKey: navigatorKey,
      home: ChatSenderBinding(
        sender: sender,
        steerSender: steerSender,
        child: ChatScreen(
          vm: vm,
          onNewSession: onNewSession,
          actions: actions,
          workspaces: workspaces,
          jobs: jobs,
          subagents: subagents,
          settings: settings,
          scope: scope,
          commands: commands,
          directory: directory,
          attachments: attachments,
          onCancelSession: onCancelSession,
        ),
      ),
    );
  }
}
