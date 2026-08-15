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
import 'package:singleman/sessions/feedback_store.dart';
import 'package:singleman/sessions/goal_store.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/job_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/subagent_store.dart';
import 'package:singleman/sessions/theme_store.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/wire/generated/wire_generated.dart';
import 'package:singleman/ui/goal_skill_widgets.dart';
import 'package:singleman/ui/model_picker.dart';
import 'package:singleman/ui/onboarding_sheet.dart';
import 'package:singleman/ui/theme_mode_row.dart';

const kDefaultBase = 'http://127.0.0.1:3080';

final navigatorKey = GlobalKey<NavigatorState>();

/// ThemeStore 的 SettingsStore 适配通道(ui-theme 命名空间 + host 帧失效转发)。
/// 照抄 test/sessions/theme_store_test.dart 的 _ScopeChannel。
class _ScopeThemeChannel implements ThemeSettingsChannel {
  _ScopeThemeChannel(this._settings, this._connection) {
    _sub = _connection.hostFrames.listen((frame) {
      if (frame is HostFrameHostRemoteEvent &&
          frame.event == 'settings/document-updated') {
        _inv.add(null);
      }
    });
  }

  final SettingsStoreView _settings;
  final ConnectionController _connection;
  final _inv = StreamController<void>.broadcast();
  StreamSubscription<HostFrame>? _sub;

  SettingsScope get _scope => _settings.scope('ui-theme');

  @override
  SettingsMutateValue? get snapshot => _scope.snapshot;

  @override
  Future<void> load() => _scope.load();

  @override
  Future<void> setPreference(String wireValue) => _scope.setField(
        ['preference'],
        wireValue,
      );

  @override
  Stream<void> get invalidations => _inv.stream;

  void dispose() {
    _sub?.cancel();
    _inv.close();
  }
}

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
  // W3 集成:消息反馈 + 主题(ui-theme 命名空间 CAS)。
  final feedback = FeedbackStore(api: api, connection: connection);
  final theme = ThemeStore(channel: _ScopeThemeChannel(settings, connection));

  connection.start();
  store.start();
  workspaces.start();

  final vm = ChatViewModel(store: store, connection: connection)..interactor = interactor;

  // W3-C:首用引导(三步;「不再提示」写 ui-onboarding 命名空间,失败本地兜底)。
  final onboarding = WelcomeOnboardingController(_ScopeOnboardingChannel(settings, connection));
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      await maybeShowWelcomeOnboarding(ctx, controller: onboarding);
    }
  });

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
    feedback: feedback,
    theme: theme,
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
    this.feedback,
    this.theme,
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
  final FeedbackStore? feedback;
  final ThemeStore? theme;
  final void Function(String sessionId)? onCancelSession;

  @override
  Widget build(BuildContext context) {
    return _ThemeWrapper(
      theme: theme,
      builder: (context, mode) => MaterialApp(
        title: 'singleman',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2E5EAA), useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF2E5EAA),
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        themeMode: mode,
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
            feedback: feedback,
            theme: theme,
            onCancelSession: onCancelSession,
          ),
        ),
      ),
    );
  }
}

/// ui-onboarding 命名空间适配(welcomeNoticeVersion 读写;同 _ScopeThemeChannel 模式)。
class _ScopeOnboardingChannel implements OnboardingChannel {
  _ScopeOnboardingChannel(this._settings, this._connection);
  final SettingsStoreView _settings;
  final ConnectionController _connection;
  bool _loaded = false;

  SettingsScope get _scope => _settings.scope('ui-onboarding');

  @override
  String? get welcomeVersion {
    final v = _scope.snapshot?.value;
    return v is Map ? v['welcomeNoticeVersion'] as String? : null;
  }

  @override
  Future<void> load() async {
    await _scope.load();
    _loaded = true;
  }

  @override
  Future<bool> setWelcomeVersion(String version) async {
    try {
      await _scope.setField(['welcomeNoticeVersion'], version);
      return true;
    } on Object {
      return false;
    }
  }
}

/// 主题流 → MaterialApp.themeMode(ThemeStore 缺席时跟随系统)。
class _ThemeWrapper extends StatefulWidget {
  const _ThemeWrapper({this.theme, required this.builder});
  final ThemeStore? theme;
  final Widget Function(BuildContext, ThemeMode) builder;

  @override
  State<_ThemeWrapper> createState() => _ThemeWrapperState();
}

class _ThemeWrapperState extends State<_ThemeWrapper> {
  StreamSubscription<ThemePreference>? _sub;
  ThemePreference _pref = ThemePreference.system;

  @override
  void initState() {
    super.initState();
    final t = widget.theme;
    if (t != null) {
      _pref = t.current;
      _sub = t.preferences.listen((p) {
        if (mounted) setState(() => _pref = p);
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, themeModeOf(_pref));
}
