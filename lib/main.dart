// singleman — DSH 原生客户端(M2 最小聊天环)。
// 桌面同机形态(ADR-0004):默认 loopback 3080,全功能。
// M6 远程形态:持久化网关地址 + 设备令牌,经 dsh-gateway 前置网关
// 鉴权中转接入;loopback 行为与旧版完全一致。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/credentials_path.dart';
import 'package:singleman/connection/device_identity.dart';
import 'package:singleman/connection/host_book.dart';
import 'package:singleman/connection/host_info.dart';
import 'package:singleman/connection/remote_auth.dart';
import 'package:singleman/sessions/agent_preset_store.dart';
import 'package:singleman/sessions/attachment_fetch.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/sessions/directory_store.dart';
import 'package:singleman/sessions/goal_store.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/job_store.dart';
import 'package:singleman/sessions/session_store.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/subagent_store.dart';
import 'package:singleman/sessions/theme_store.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/ui/app_theme.dart';
import 'package:singleman/ui/chat_screen.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/ui/pairing_page.dart';
import 'package:singleman/wire/generated/wire_generated.dart';
import 'package:singleman/connection/privacy_consent.dart';
import 'package:singleman/ui/model_picker.dart';
import 'package:singleman/ui/onboarding_sheet.dart';
import 'package:singleman/ui/privacy_gate.dart';
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
  // OHOS 上架合规:首启隐私政策门,同意前不初始化任何网络连接
  // (门在 boot 之前,而非 UI 上盖一层)。其余平台无此门。
  if (Platform.operatingSystem == 'ohos') {
    final consent = PrivacyConsentStore();
    if (!await consent.isAgreed) {
      final agreed = await runPrivacyConsentGate(store: consent);
      if (!agreed) {
        await exitAfterPrivacyDecline();
      }
    }
  }
  // 主机簿(方案 A 多主机):启动载入,活动条目决定连接目标。
  final hosts = HostCoordinator(FileCredentialStore());
  await hosts.hydrate();
  // 本机设备名(配对时上报给宿主):文件优先,缺省生成默认并回写。
  final deviceNames = DeviceNameStore();
  await deviceNames.load();
  // 手机形态(Android/iOS/OHOS)首启即网关配对 —— loopback 默认地址在手机上
  // 永远不可达;桌面保持 loopback 直连零摩擦。
  // OHOS 判定必须走 operatingSystem 而非 Platform.isOhos:后者是 OHOS fork
  // 加的符号,非 OHOS 平台引擎的 dart:io 运行时没有它,直接调用会
  // NoSuchMethodError(fork 只重编 ohos 引擎,macOS 等复用上游产物)。
  final mobileFirst = Platform.isAndroid || Platform.isIOS ||
      Platform.operatingSystem == 'ohos';
  boot(
    plan: planForBook(hosts.book.value, mobileFirst: mobileFirst),
    hosts: hosts,
    mobileFirst: mobileFirst,
    deviceNames: deviceNames,
  );
}

/// 上一次 boot 的活动连接(换 base 整代重装时释放,防旧退避循环永驻)。
ConnectionController? _activeConnection;

/// 整代重装:释放旧连接(退避 Timer/双 WS),以新计划重跑 boot。
/// 配对到新网关 / 设置页切换主机 / 删除活动主机共用这一条路径。
void _reboot(
  ConnectionPlan plan,
  HostCoordinator hosts,
  bool mobileFirst,
  DeviceNameStore deviceNames,
) {
  final old = _activeConnection;
  _activeConnection = null;
  unawaited(old?.dispose());
  boot(
    plan: plan,
    hosts: hosts,
    mobileFirst: mobileFirst,
    deviceNames: deviceNames,
  );
}

/// 按既定计划装配并启动整个应用(登录后换 base / 主机切换会以新计划重跑)。
void boot({
  required ConnectionPlan plan,
  required HostCoordinator hosts,
  required bool mobileFirst,
  DeviceNameStore? deviceNames,
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
  final skills = SkillCatalog(api: api);
  // W1 集成:四个新域 store,共用 api + connection(见 PLAN「W1 集成规格」)。
  final workspaces = WorkspaceStore(api: api, connection: connection);
  final jobs = JobStore(api: api, connection: connection);
  final subagents = SubagentStore(api: api, connection: connection);
  final settings = SettingsStore(api: api, connection: connection);
  // 工作模式域(Agent 预设;composer 上方行 + web hero agentPreset 对齐)。
  final agentPresets = AgentPresetStore(api: api, connection: connection);
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
  // W3 集成:主题(ui-theme 命名空间 CAS)。消息反馈(FeedbackStore)
  // 已从消息流移除 —— web 侧该功能走可选插件 slot,本机 web 未装,
  // 客户端不对齐出 web 没有的 UI;域与组件保留,web 启用后可再挂。
  final theme = ThemeStore(channel: _ScopeThemeChannel(settings, connection));

  void startConnected() {
    connection.start();
    store.start();
    workspaces.start();
  }

  if (!plan.needsLogin) startConnected();

  // M6.4 宿主状态:设置页「已连接 <机器名>」。authed 动态读令牌供给
  // (首登后 refreshAuthed 翻转);机器名种子来自凭证,连接就绪后被
  // /pair/api/host(dsh-mobile plugin)的当前值覆盖。
  final hostStatus = HostStatusController(
    snapshots: connection.snapshots,
    current: () => connection.current,
    api: api,
    authed: () => !isLoopbackBase(base) && plan.tokenProvider.hasToken,
    seedMachine: plan.seedMachine,
  )..start();

  final vm = ChatViewModel(store: store, connection: connection)
    ..interactor = interactor;

  // 登录成功(首登/手动配置/令牌失效后的重登):入簿(同网关原地刷新
  // 令牌,新网关追加)→ 激活。base 变化 → 整代重装(所有 store 持有旧
  // base 的 ApiClient),旧连接释放。
  Future<void> onLoginDone(RemoteLoginSuccess success) async {
    await hosts.adopt(success);
    plan.tokenProvider.token = success.token;
    hostStatus.seedMachine(success.hostLabel);
    hostStatus.refreshAuthed();
    if (success.baseUri != base) {
      _reboot(
        planForBook(hosts.book.value, mobileFirst: mobileFirst),
        hosts,
        mobileFirst,
        deviceNames ?? DeviceNameStore(),
      );
      return;
    }
    if (plan.needsLogin) {
      startConnected();
    } else {
      connection.resume();
    }
  }

  // 设置页「连接」分区:切换主机(活动指针翻转 + 整代重装到目标网关)。
  Future<void> onSwitchHost(String hostId) async {
    final target = await hosts.switchTo(hostId);
    if (target == null ||
        hostIdForBase(target.baseUri) == hostIdForBase(base)) {
      return;
    }
    _reboot(
      planForBook(hosts.book.value, mobileFirst: mobileFirst),
      hosts,
      mobileFirst,
      deviceNames ?? DeviceNameStore(),
    );
  }

  // 设置页「连接」分区:删除主机条目。删非活动条目只动簿(列表经
  // notifier 即时更新,当前连接不受影响);删活动条目 → 切到剩余首条,
  // 簿删空则落配对页(mobileFirst)/ loopback(桌面)。
  Future<void> onRemoveHost(String hostId) async {
    final wasActive = hosts.book.value.active?.id == hostId;
    await hosts.remove(hostId);
    if (!wasActive) return;
    _reboot(
      planForBook(hosts.book.value, mobileFirst: mobileFirst),
      hosts,
      mobileFirst,
      deviceNames ?? DeviceNameStore(),
    );
  }

  // 设置页「连接」分区:未连接状态行的手动重连(authBlocked 亦复位重启)。
  void onReconnect() => connection.resume();

  _activeConnection = connection;

  // M6.1:配对是唯一远程鉴权渠道(网关密码登录已禁用);
  // 手机首启后的配置处、桌面加远程/换网关处都在这里。
  final gatewayAuth = RemoteAuthClient();

  // 设置中心「连接」分区:发起配对(主鉴权入口,RemoteAuthClient 同源双角色)。
  void openPairing() {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => PairingPage(
          pairing: gatewayAuth,
          initialUrl: isLoopbackBase(base)
              ? kDefaultGatewayBase
              : base.toString(),
          deviceName: deviceNames?.listenable,
          onSetDeviceName: deviceNames?.set,
          onDone: onLoginDone,
        ),
      ),
    );
  }

  // W3-C:首用引导(三步;「不再提示」写 ui-onboarding 命名空间,失败本地兜底)。
  // 远程首登形态跳过(登录页已承担引导职责)。
  if (!plan.needsLogin) {
    final onboarding = WelcomeOnboardingController(
      _ScopeOnboardingChannel(settings),
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
      // 令牌失效被配对页挡住时,其他已配对主机仍可一键切换(不必重配)。
      otherHosts: [
        for (final h in hosts.book.value.hosts)
          if (h.id != hostIdForBase(base)) h,
      ],
      onSwitchHost: onSwitchHost,
      deviceName: deviceNames?.listenable,
      onSetDeviceName: deviceNames?.set,
      child: SinglemanApp(
        vm: vm,
        onNewSession: (workspaceId) async {
          try {
            // workspaceId 非空 = 归入该工作区(组头「+」/轨道「+」解析)。
            final value = await store.createSession(workspaceId: workspaceId);
            // 创建即打开(web startSession 语义):否则轨道/组头「+」按下后
            // 界面毫无反馈,新会话只是侧栏里悄悄多出的一行。
            vm.select(value.sessionId);
          } on Object catch (e) {
            debugPrint('createSession failed: ' + e.toString());
          }
        },
        actions: SessionActions(
          onLoadModelLabel: (sessionId) async {
            // composer 模型 chip:当前选择的显示名(组内找不到退回 model id)。
            try {
              final catalog = await store.sessionModels(sessionId);
              final cur = catalog.current;
              for (final g in catalog.groups) {
                if (g.id != cur.provider) continue;
                for (final m in g.models) {
                  if (m.id == cur.model) return m.name;
                }
              }
              return cur.model;
            } on Object {
              return null;
            }
          },
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
        agentPresets: agentPresets,
        jobs: jobs,
        subagents: subagents,
        settings: settings,
        scope: scope,
        commands: commands,
        directory: directory,
        attachments: attachments,
        theme: theme,
        onCancelSession: (sessionId) async {
          try {
            await interactor.cancelSession(sessionId);
          } on Object catch (e) {
            debugPrint('cancel failed: ' + e.toString());
          }
        },
        onOpenPairing: openPairing,
        hostStatus: hostStatus.status,
        hosts: hosts.book,
        onSwitchHost: onSwitchHost,
        onRemoveHost: onRemoveHost,
        onReconnect: onReconnect,
        deviceName: deviceNames?.listenable,
        onSetDeviceName: deviceNames?.set,
      ),
    ),
  );
}

/// 连接门卫(M6):首登/令牌失效时把配对页挡在主界面之前;
/// authBlocked(网关 401)时主动拉起配对页,重配成功后 resume。
/// 多主机形态:簿里还有其他主机时,配对页尾部提供切换入口。
class _ConnectionGate extends StatefulWidget {
  const _ConnectionGate({
    required this.connection,
    required this.baseUri,
    required this.needsLogin,
    required this.onLoginDone,
    this.otherHosts = const [],
    this.onSwitchHost,
    this.deviceName,
    this.onSetDeviceName,
    required this.child,
  });

  final ConnectionController connection;
  final Uri baseUri;
  final bool needsLogin;
  final Future<void> Function(RemoteLoginSuccess) onLoginDone;
  final List<StoredCredentials> otherHosts;
  final Future<void> Function(String hostId)? onSwitchHost;
  final ValueListenable<String?>? deviceName;
  final Future<bool> Function(String)? onSetDeviceName;
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
    // MaterialApp(Directionality/Theme/Navigator) 作为配对页根壳。
    // 配对是唯一鉴权渠道(网关密码登录已禁用)。
    return MaterialApp(
      title: 'DshAPP',
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: PairingPage(
        pairing: _auth,
        initialUrl: widget.baseUri.toString(),
        popOnDone: false,
        otherHosts: widget.otherHosts,
        onSwitchHost: widget.onSwitchHost,
        deviceName: widget.deviceName,
        onSetDeviceName: widget.onSetDeviceName,
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
    this.agentPresets,
    this.jobs,
    this.subagents,
    this.settings,
    this.scope,
    this.commands,
    this.directory,
    this.attachments,
    this.theme,
    this.onCancelSession,
    this.onOpenPairing,
    this.hostStatus,
    this.hosts,
    this.onSwitchHost,
    this.onRemoveHost,
    this.onReconnect,
    this.deviceName,
    this.onSetDeviceName,
  });

  final ChatViewModel vm;

  /// 新建会话;workspaceId 非空 = 归入该工作区。
  final Future<void> Function(String? workspaceId) onNewSession;
  final Future<void> Function(String sessionId, String text) sender;
  final Future<void> Function(String sessionId, String text, bool steer)?
  steerSender;
  final SessionActions? actions;
  final WorkspaceStore? workspaces;

  /// 工作模式域(composer 上方行;透传 ChatScreen)。
  final AgentPresetStore? agentPresets;
  final JobStore? jobs;
  final SubagentStore? subagents;
  final SettingsStore? settings;
  final PrivilegeScope? scope;
  final CommandStore? commands;
  final DirectoryBrowserStore? directory;
  final AttachmentFetcher? attachments;
  final ThemeStore? theme;
  final void Function(String sessionId)? onCancelSession;

  // M6/M6.1 远程连接入口(透传 ChatScreen → 设置中心「连接」分区)。
  final VoidCallback? onOpenPairing;

  /// M6.4 宿主状态(设置页「已连接 <机器名>」行)。
  final ValueListenable<HostStatus>? hostStatus;

  /// 本机设备名(设置页「连接」分区;透传 ChatScreen)。
  final ValueListenable<String?>? deviceName;
  final Future<bool> Function(String)? onSetDeviceName;

  /// 方案 A 多主机:主机簿(设置页「连接」分区列表)与切换/删除/重连。
  final ValueListenable<HostBook>? hosts;
  final Future<void> Function(String hostId)? onSwitchHost;
  final Future<void> Function(String hostId)? onRemoveHost;
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context) {
    return _ThemeWrapper(
      theme: theme,
      builder: (context, mode) => MaterialApp(
        title: 'DshAPP',
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
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
            agentPresets: agentPresets,
            jobs: jobs,
            subagents: subagents,
            settings: settings,
            scope: scope,
            commands: commands,
            directory: directory,
            attachments: attachments,
            theme: theme,
            onCancelSession: onCancelSession,
            onOpenPairing: onOpenPairing,
            hostStatus: hostStatus,
            deviceName: deviceName,
            onSetDeviceName: onSetDeviceName,
            hosts: hosts,
            onSwitchHost: onSwitchHost,
            onRemoveHost: onRemoveHost,
            onReconnect: onReconnect,
          ),
        ),
      ),
    );
  }
}

/// ui-onboarding 命名空间适配(welcomeNoticeVersion 读写;同 _ScopeThemeChannel 模式)。
class _ScopeOnboardingChannel implements OnboardingChannel {
  _ScopeOnboardingChannel(this._settings);
  final SettingsStoreView _settings;

  SettingsScope get _scope => _settings.scope('ui-onboarding');

  @override
  String? get welcomeVersion {
    final v = _scope.snapshot?.value;
    return v is Map ? v['welcomeNoticeVersion'] as String? : null;
  }

  @override
  Future<void> load() => _scope.load();

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
