// singleman — DSH 原生客户端(M2 最小聊天环)。
// 桌面同机形态(ADR-0004):默认 loopback 3080,全功能。
// M6 远程形态:持久化网关地址 + 设备令牌,经 dsh-gateway(example.com)
// 鉴权中转接入;loopback 行为与旧版完全一致。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/credentials_path.dart';
import 'package:singleman/connection/remote_auth.dart';
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
import 'package:singleman/ui/remote_login.dart';
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
  Future<void> setPreference(String wireValue) =>
      _scope.setField(['preference'], wireValue);

  @override
  Stream<void> get invalidations => _inv.stream;

  void dispose() {
    _sub?.cancel();
    _inv.close();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = FileCredentialStore();
  // 手机形态(Android/iOS)首启即网关登录 —— loopback 默认地址在手机上
  // 永远不可达;桌面保持 loopback 直连零摩擦。
  final mobileFirst = Platform.isAndroid || Platform.isIOS;
  final plan = await planFromCredentials(store, mobileFirst: mobileFirst);
  boot(plan: plan, credentialStore: store);
}

/// 上一次 boot 的活动连接(换 base 整代重装时释放,防旧退避循环永驻)。
ConnectionController? _activeConnection;

/// 按既定计划装配并启动整个应用(登录后换 base 会以新计划重跑)。
void boot({
  required ConnectionPlan plan,
  required CredentialStore credentialStore,
}) {
  final authHeaders = plan.tokenProvider.authHeaders;
  final base = plan.baseUri;

  final api = ApiClient(baseUri: base, authHeaders: authHeaders);
  final connection = ConnectionController(
    baseUri: base,
    authHeaders: authHeaders,
  );
  final store = SessionStore(api: api, connection: connection);
  final interactor = InteractorStore(api: api, connection: connection);
  final goals = GoalStore(api: api);
  final skills = SkillCatalog(api: api);
  // W1 集成:四个新域 store,共用 api + connection(见 PLAN「W1 集成规格」)。
  final workspaces = WorkspaceStore(api: api, connection: connection);
  final jobs = JobStore(api: api, connection: connection);
  final subagents = SubagentStore(api: api, connection: connection);
  final settings = SettingsStore(api: api, connection: connection);
  final remote = !isLoopbackBase(base);
  final scope = scopeFor(
    base,
    authenticatedRemote: remote && plan.tokenProvider.hasToken,
  );
  // W2 集成:命令目录(斜杠菜单)/目录浏览(添加 workspace)/附件拉取(图片消息)。
  final commands = CommandStore(
    api: api,
    connection: connection,
    skills: skills,
  );
  final directory = DirectoryBrowserStore(api: api);
  final attachments = AttachmentFetcher(api: api);
  // W3 集成:消息反馈 + 主题(ui-theme 命名空间 CAS)。
  final feedback = FeedbackStore(api: api, connection: connection);
  final theme = ThemeStore(channel: _ScopeThemeChannel(settings, connection));

  void startConnected() {
    connection.start();
    store.start();
    workspaces.start();
  }

  if (!plan.needsLogin) startConnected();

  final vm = ChatViewModel(store: store, connection: connection)
    ..interactor = interactor;

  // 登录成功(首登/手动配置/令牌失效后的重登):写凭证 → 令牌供给原地刷新。
  // base 变化 → 整代重装(所有 store 持有旧 base 的 ApiClient),旧连接释放。
  Future<void> onLoginDone(RemoteLoginSuccess success) async {
    plan.tokenProvider.token = success.token;
    await credentialStore.save(
      StoredCredentials(baseUri: success.baseUri, token: success.token),
    );
    if (success.baseUri != base) {
      final old = _activeConnection;
      _activeConnection = null;
      // 释放旧连接(其退避 Timer/双 WS 都要停);新树随后接管。
      unawaited(old?.dispose());
      boot(
        plan: ConnectionPlan(
          baseUri: success.baseUri,
          tokenProvider: plan.tokenProvider,
          needsLogin: false,
        ),
        credentialStore: credentialStore,
      );
      return;
    }
    if (plan.needsLogin) {
      startConnected();
    } else {
      connection.resume();
    }
  }

  _activeConnection = connection;

  // M6:侧栏「远程网关」常驻入口 —— 手机首启后的配置处、桌面加远程/换网关处。
  final gatewayAuth = RemoteAuthClient();
  String gatewayLabel() => isLoopbackBase(base)
      ? '本机直连 · 点此配置远程'
      : (plan.tokenProvider.hasToken
            ? '已登录 · ${base.host}'
            : '未登录 · ${base.host}');
  void openGatewayLogin() {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => RemoteLoginPage(
          auth: gatewayAuth,
          initialUrl: isLoopbackBase(base)
              ? kDefaultGatewayBase
              : base.toString(),
          title: '远程网关登录',
          onDone: onLoginDone,
        ),
      ),
    );
  }

  // W3-C:首用引导(三步;「不再提示」写 ui-onboarding 命名空间,失败本地兜底)。
  // 远程首登形态跳过(登录页已承担引导职责)。
  if (!plan.needsLogin) {
    final onboarding = WelcomeOnboardingController(
      _ScopeOnboardingChannel(settings, connection),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        await maybeShowWelcomeOnboarding(ctx, controller: onboarding);
      }
    });
  }

  runApp(
    _ConnectionGate(
      connection: connection,
      baseUri: base,
      needsLogin: plan.needsLogin,
      onLoginDone: onLoginDone,
      child: SinglemanApp(
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
            final result = await showModelPicker(
              ctx,
              loadCatalog: () => store.sessionModels(sid),
            );
            if (result == null) return;
            try {
              await store.selectModel(
                sid,
                provider: result.provider,
                model: result.model,
                reasoningEffort: result.reasoningEffort,
              );
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
              await store.promptText(
                sid,
                skills.promptFor(name),
                clientTimeZone: 'UTC',
              );
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
          await store.promptText(
            sessionId,
            text,
            mode: steer ? 'steer' : 'queue',
            clientTimeZone: 'UTC',
          );
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
        onOpenGatewayLogin: openGatewayLogin,
        gatewayLabel: gatewayLabel(),
      ),
    ),
  );
}

/// 连接门卫(M6):首登/令牌失效时把登录页挡在主界面之前;
/// authBlocked(网关 401)时主动拉起登录页,重登成功后 resume。
class _ConnectionGate extends StatefulWidget {
  const _ConnectionGate({
    required this.connection,
    required this.baseUri,
    required this.needsLogin,
    required this.onLoginDone,
    required this.child,
  });

  final ConnectionController connection;
  final Uri baseUri;
  final bool needsLogin;
  final Future<void> Function(RemoteLoginSuccess) onLoginDone;
  final Widget child;

  @override
  State<_ConnectionGate> createState() => _ConnectionGateState();
}

class _ConnectionGateState extends State<_ConnectionGate> {
  late bool _showLogin = widget.needsLogin;
  StreamSubscription<ConnectionSnapshot>? _sub;
  final _auth = RemoteAuthClient();

  @override
  void initState() {
    super.initState();
    _sub = widget.connection.snapshots.listen((snap) {
      if (snap.phase == ConnectionPhase.down &&
          snap.failureReason == 'unauthorized' &&
          !_showLogin &&
          mounted) {
        setState(() => _showLogin = true);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_showLogin) return widget.child;
    // 首次移动端启动时门卫位于 SinglemanApp 外层,因此这里必须提供
    // MaterialApp(Directionality/Theme/Navigator) 作为登录页根壳。
    return MaterialApp(
      title: 'singleman',
      theme: _buildAppTheme(Brightness.light),
      darkTheme: _buildAppTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: RemoteLoginPage(
        auth: _auth,
        initialUrl: widget.baseUri.toString(),
        title: widget.needsLogin ? '连接到 DSH 网关' : '登录已失效,请重新登录',
        popOnDone: false,
        onDone: (success) async {
          await widget.onLoginDone(success);
          if (mounted) setState(() => _showLogin = false);
        },
      ),
    );
  }
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
    this.onOpenGatewayLogin,
    this.gatewayLabel,
  });

  final ChatViewModel vm;
  final Future<void> Function() onNewSession;
  final Future<void> Function(String sessionId, String text) sender;
  final Future<void> Function(String sessionId, String text, bool steer)?
  steerSender;
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

  // M6 远程网关入口(透传 ChatScreen)。
  final VoidCallback? onOpenGatewayLogin;
  final String? gatewayLabel;

  @override
  Widget build(BuildContext context) {
    return _ThemeWrapper(
      theme: theme,
      builder: (context, mode) => MaterialApp(
        title: 'singleman',
        theme: _buildAppTheme(Brightness.light),
        darkTheme: _buildAppTheme(Brightness.dark),
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
            onOpenGatewayLogin: onOpenGatewayLogin,
            gatewayLabel: gatewayLabel,
          ),
        ),
      ),
    );
  }
}

ThemeData _buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF5B5CE2),
    brightness: brightness,
    surface: dark ? const Color(0xFF12131B) : const Color(0xFFF7F8FC),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 17,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: dark ? .35 : .55),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(
        alpha: dark ? .45 : .62,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: .7),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: .7),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      minVerticalPadding: 6,
      iconColor: scheme.onSurfaceVariant,
      selectedColor: scheme.primary,
      selectedTileColor: scheme.primary.withValues(alpha: dark ? .18 : .1),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(42, 42),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    ),
  );
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
