// ChatScreen — 会话主界面(W1 集成:workspace 分组/单列侧栏(可切排序)+ 节点流 + jobs/subagent 入口 + 设置;
// <600dp 移动形态 = 抽屉侧栏,桌面 ≥600dp 保持双栏,见 PLAN「W1 集成规格」)。
// 只消费注入的 store 视图与 ChatViewModel,不含任何 socket/HTTP 逻辑。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/connection/credentials.dart';
import 'package:singleman/connection/host_info.dart';
import 'package:singleman/sessions/interactor_store.dart';
import 'package:singleman/sessions/job_store.dart';
import 'package:singleman/sessions/settings_store.dart';
import 'package:singleman/sessions/subagent_store.dart';
import 'package:singleman/sessions/workspace_store.dart';
import 'package:singleman/sessions/attachment_fetch.dart';
import 'package:singleman/sessions/agent_preset_store.dart';
import 'package:singleman/sessions/command_store.dart';
import 'package:singleman/sessions/directory_store.dart';
import 'package:singleman/ui/chat_view_model.dart';
import 'package:singleman/ui/command_menu_sheet.dart';
import 'package:singleman/ui/composer_pro.dart';
import 'package:singleman/ui/directory_browse_sheet.dart';
import 'package:singleman/ui/node_widgets.dart';
import 'package:singleman/sessions/theme_store.dart';
import 'package:singleman/ui/trajectory_page.dart';
import 'package:singleman/ui/connect_config.dart';
import 'package:singleman/wire/generated/wire_generated.dart';
import 'package:singleman/ui/interactor_widgets.dart';
import 'package:singleman/ui/jobs_sheet.dart';
import 'package:singleman/ui/settings_screen.dart';
import 'package:singleman/ui/subagent_catalog.dart';
import 'package:singleman/ui/todo_panel.dart';
import 'package:singleman/ui/workspace_browser.dart';

/// 当前选中会话所属工作区 id(无选中/未分组为 null)。
/// web workspaces.startSession() 无参时的继承语义由此实现。
String? _currentWorkspaceIdOf(
  ChatViewModel vm,
  WorkspaceStoreView? workspaces,
) {
  final sid = vm.selectedId;
  if (sid == null) return null;
  for (final ws in workspaces?.currentWorkspaces ?? const <WorkspaceView>[]) {
    if (ws.sessionIds.contains(sid)) return ws.workspaceId;
  }
  return null;
}

/// 会话操作回调束(M4:模型/搜索/fork/导出/重命名;main 注入)。
class SessionActions {
  const SessionActions({
    this.onPickModel,
    this.onLoadModelLabel,
    this.onRename,
    this.onFork,
    this.onExport,
  });
  final VoidCallback? onPickModel;

  /// 读当前会话模型显示名(composer 模型 chip;main 经 session.models 提供)。
  final Future<String?> Function(String sessionId)? onLoadModelLabel;
  final void Function(String sessionId, String title)? onRename;
  final void Function(String sessionId)? onFork;
  final void Function(String sessionId)? onExport;
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({
    super.key,
    required this.vm,
    this.onNewSession,
    this.actions,
    this.workspaces,
    this.jobs,
    this.subagents,
    this.settings,
    this.scope,
    this.commands,
    this.agentPresets,
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

  /// 新建会话;workspaceId 非空 = 归入该工作区,null = 未分组
  /// (web workspaces.startSession(workspaceId?) 语义)。
  final void Function(String? workspaceId)? onNewSession;
  final SessionActions? actions;

  // W1 域注入(均 optional:测试/过渡期可缺省)。
  final WorkspaceStoreView? workspaces;
  final JobStoreView? jobs;
  final SubagentStore? subagents;
  final SettingsStoreView? settings;
  final PrivilegeScope? scope;

  // W2 域注入。
  final CommandStoreView? commands;

  /// 工作模式域(Agent 预设;composer 上方行的第二个 chip)。
  final AgentPresetStoreView? agentPresets;
  final DirectoryBrowserView? directory;
  final AttachmentFetchView? attachments;

  // W3 域注入。
  final ThemeStoreView? theme;
  final void Function(String sessionId)? onCancelSession;

  // M6/M6.1 远程连接:设置中心「连接」分区子菜单(入口在设置页内)。
  final VoidCallback? onOpenPairing;

  /// M6.4 宿主状态(设置页「已连接 <机器名>」行)。
  final ValueListenable<HostStatus>? hostStatus;
  final ValueListenable<String?>? deviceName;
  final Future<bool> Function(String)? onSetDeviceName;

  /// 方案 A 多主机:主机簿与切换/删除/重连(设置页「连接」分区)。
  final ValueListenable<HostBook>? hosts;
  final Future<void> Function(String hostId)? onSwitchHost;
  final Future<void> Function(String hostId)? onRemoveHost;
  final VoidCallback? onReconnect;

  static const _kWideBreakpoint = 600.0;

  /// 统一构造侧栏(宽屏注入 onCollapse;窄屏抽屉 closeOnSelect)。
  _Sidebar _sidebar({VoidCallback? onCollapse, bool closeOnSelect = false}) {
    return _Sidebar(
      vm: vm,
      onNewSession: onNewSession,
      actions: actions,
      workspaces: workspaces,
      settings: settings,
      scope: scope,
      directory: directory,
      theme: theme,
      onOpenPairing: onOpenPairing,
      hostStatus: hostStatus,
      deviceName: deviceName,
      onSetDeviceName: onSetDeviceName,
      hosts: hosts,
      onSwitchHost: onSwitchHost,
      onRemoveHost: onRemoveHost,
      onReconnect: onReconnect,
      onCollapse: onCollapse,
      closeOnSelect: closeOnSelect,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: vm,
      builder: (context, _) {
        // 标题行归属:窄屏顶部由 Scaffold AppBar 独占(菜单 + 新建
        // icon),pane 内 52dp 标题行仅宽屏渲染 —— 修复窄屏双标题栏
        // (用户实报:顶部出现两根标题栏,只留带菜单/新建 icon 那根)。
        Widget paneFor(bool showTitleRow) => _MessagePane(
          vm: vm,
          jobs: jobs,
          subagents: subagents,
          commands: commands,
          attachments: attachments,
          onCancelSession: onCancelSession,
          workspaces: workspaces,
          actions: actions,
          agentPresets: agentPresets,
          onNewSession: onNewSession,
          onApproval: (a, allow) async {
            final it = vm.interactor;
            if (it == null) return;
            try {
              final receipt = await it.respondApproval(
                a.rpcId,
                a.sessionId,
                a.approvalId,
                allow: allow,
              );
              if (receipt.late) {
                _toast(context, '该审批已被处理(回复过期)');
              } else if (receipt.malformed) {
                _toast(context, '审批应答被拒绝: 响应格式问题');
              }
            } on Object catch (e) {
              _toast(context, '审批应答发送失败: ' + e.toString());
            }
          },
          onQuestion: (q, drafts) async {
            final it = vm.interactor;
            if (it == null) return '交互通道不可用';
            final err = it.validateQuestionAnswers(q, drafts);
            if (err != null) {
              return '应答不完整: ' + err;
            }
            final payload = drafts
                .map(
                  (d) => <String, dynamic>{
                    'id': d.questionId,
                    'selected': d.selected,
                    if (d.custom != null && d.custom!.isNotEmpty)
                      'custom': d.custom,
                  },
                )
                .toList();
            try {
              final receipt = await it.respondQuestions(
                q.rpcId,
                q.sessionId,
                payload,
              );
              if (receipt.late) return '该问题已被处理(回复过期)';
              if (receipt.malformed) return '应答被拒绝: 响应格式问题';
              return null;
            } on Object catch (e) {
              return '应答发送失败: ' + e.toString();
            }
          },
          // 队列动作(session.updateQueue):移除/插话。插话的
          // steer-unavailable / queue-item-not-found 是合法竞态结果
          // (轮次刚结束/项刚被 claim),web 同款静默收敛不报错。
          onQueueRemove: (item) {
            final it = vm.interactor;
            final sid = vm.selectedId;
            final id = QueueDock.itemIdOf(item);
            if (it == null || sid == null || id == null) return;
            unawaited(
              it
                  .removeQueueItem(sid, id)
                  .then(
                    (_) {},
                    onError: (Object e) => _toast(context, '移除失败: 这条消息可能已开始发送'),
                  ),
            );
          },
          onQueueSteer: (item) {
            final it = vm.interactor;
            final sid = vm.selectedId;
            final id = QueueDock.itemIdOf(item);
            if (it == null || sid == null || id == null) return;
            unawaited(
              it
                  .steerQueueItem(sid, id)
                  .then(
                    (_) {},
                    onError: (Object e) {
                      final code = e is RpcBusinessError
                          ? e.error.toJson()['code']
                          : null;
                      if (code == 'steer-unavailable' ||
                          code == 'queue-item-not-found') {
                        return; // 竞态:轮次已结束或消息已开始发送,静默。
                      }
                      _toast(context, '插话失败: 这条消息可能已开始发送');
                    },
                  ),
            );
          },
          showTitleRow: showTitleRow,
        );
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _kWideBreakpoint;
            if (wide) {
              // 宽屏:侧栏支持最小化(_SidebarHost 292dp ↔ 56dp 轨道,参考
              // web ui-sidebar 折叠控件 + ui-layout COLLAPSED 56)。
              return Scaffold(
                body: Row(
                  children: [
                    Builder(
                      builder: (railContext) => _SidebarHost(
                        sidebarBuilder: (onCollapse) =>
                            _sidebar(onCollapse: onCollapse),
                        railBuilder: (onExpand) => _SidebarRail(
                          onExpand: onExpand,
                          // 轨道「+」:在当前选中会话的工作区新建
                          // (web rail New Session 继承语义)。
                          onNewSession: onNewSession == null
                              ? null
                              : () => onNewSession!(
                                  _currentWorkspaceIdOf(vm, workspaces),
                                ),
                          onNewWorkspace:
                              workspaces != null && directory != null
                              ? () => showDirectoryBrowseSheet(
                                  railContext,
                                  store: directory!,
                                  onConfirm: (path) async {
                                    try {
                                      await workspaces!.create(path);
                                    } on Object catch (e) {
                                      debugPrint(
                                        'workspace create failed: ' +
                                            e.toString(),
                                      );
                                    }
                                  },
                                )
                              : null,
                          settingsEntry: settings != null && scope != null
                              ? IconButton(
                                  tooltip: '设置',
                                  icon: const Icon(
                                    Icons.settings_outlined,
                                    size: 20,
                                  ),
                                  onPressed: () => showSettingsHub(
                                    context,
                                    store: settings!,
                                    scope: scope!,
                                    onPickModel: actions?.onPickModel == null
                                        ? null
                                        : () {
                                            // 与侧栏设置行一致:未选会话可感知提示。
                                            if (vm.selectedId == null) {
                                              _toast(context, '请先选择一个会话');
                                              return;
                                            }
                                            actions!.onPickModel!();
                                          },
                                    onOpenPairing: onOpenPairing,
                                    hostStatus: hostStatus,
                                    deviceName: deviceName,
                                    onSetDeviceName: onSetDeviceName,
                                    theme: theme,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    // 宽屏形态无 AppBar:Scaffold 不消费顶部安全区,内容
                    // pane 必须显式避让状态栏/刘海(侧栏各形态自带 SafeArea;
                    // 背景装饰仍全幅绘制,仅内容下移)。
                    Expanded(
                      child: _ConversationBackdrop(
                        child: SafeArea(
                          bottom: false,
                          child: paneFor(true),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }
            // 移动形态(<600dp):侧栏进抽屉,消息 pane 全屏。
            return Scaffold(
              appBar: AppBar(
                // 标题栏显示当前会话标题(用户诉求:替代品牌名 + 连接徽标;
                // 连接状态仍在抽屉侧栏头部可察)。
                title: Text(
                  _selectedSessionTitle(vm),
                  key: const ValueKey('pane-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actions: [
                  // 标题栏动作簇与宽屏标题行同源(命令与技能/轨迹等)。
                  ..._sessionTitleActions(
                    context,
                    vm: vm,
                    sid: vm.selectedId,
                    jobs: jobs,
                    subagents: subagents,
                    commands: commands,
                  ),
                  if (onNewSession != null)
                    IconButton(
                      tooltip: '新建会话',
                      // AppBar「+」同样继承当前选中会话的工作区(web 语义)。
                      onPressed: () =>
                          onNewSession!(_currentWorkspaceIdOf(vm, workspaces)),
                      icon: const Icon(Icons.add),
                    ),
                ],
                leading: Builder(
                  builder: (context) {
                    return IconButton(
                      tooltip: '会话列表',
                      onPressed: () => Scaffold.of(context).openDrawer(),
                      icon: const Icon(Icons.menu),
                    );
                  },
                ),
              ),
              // 窄屏抽屉:closeOnSelect = 选中/新建会话后自动收起抽屉。
              drawer: Drawer(
                width: 320,
                child: SafeArea(child: _sidebar(closeOnSelect: true)),
              ),
              body: _ConversationBackdrop(child: paneFor(false)),
            );
          },
        );
      },
    );
  }
}

/// 宽屏侧栏宿主(参考 web ui-sidebar 折叠控件 + ui-layout COLLAPSED 56):
/// 持有折叠态,展开 292dp ↔ 折叠 56dp 图标轨道;宽度/透明度交叉动画,
/// 展开内容冻结原宽淡出、容器裁剪(与 web 150ms 折叠动画语义一致)。
class _SidebarHost extends StatefulWidget {
  const _SidebarHost({required this.sidebarBuilder, required this.railBuilder});

  final Widget Function(VoidCallback onCollapse) sidebarBuilder;
  final Widget Function(VoidCallback onExpand) railBuilder;

  @override
  State<_SidebarHost> createState() => _SidebarHostState();
}

class _SidebarHostState extends State<_SidebarHost> {
  static const _kAnim = Duration(milliseconds: 160);
  static const _kExpandedWidth = 292.0;
  static const _kRailWidth = 56.0;

  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final toggle = () => setState(() => _collapsed = !_collapsed);
    return AnimatedContainer(
      key: const ValueKey('wide-sidebar-pane'),
      duration: _kAnim,
      curve: Curves.easeOutCubic,
      width: _collapsed ? _kRailWidth : _kExpandedWidth,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: colors.surfaceContainerLow),
      child: Stack(
        children: [
          // 展开态:内容冻结 292dp 宽,折叠时淡出并让出指针。
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _collapsed,
              child: AnimatedOpacity(
                duration: _kAnim,
                opacity: _collapsed ? 0 : 1,
                child: OverflowBox(
                  minWidth: _kExpandedWidth,
                  maxWidth: _kExpandedWidth,
                  alignment: Alignment.centerLeft,
                  child: widget.sidebarBuilder(toggle),
                ),
              ),
            ),
          ),
          // 折叠态:56dp 图标轨道。
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_collapsed,
              child: AnimatedOpacity(
                duration: _kAnim,
                opacity: _collapsed ? 1 : 0,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: widget.railBuilder(toggle),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 折叠轨道(56dp):品牌 / 展开侧栏 / 新建会话(当前工作区)/
/// 新建工作区 竖排;底部设置图标(web rail 四控件同构)。
class _SidebarRail extends StatelessWidget {
  const _SidebarRail({
    this.onExpand,
    this.onNewSession,
    this.onNewWorkspace,
    this.settingsEntry,
  });

  final VoidCallback? onExpand;

  /// 新建会话:在当前选中会话的工作区新建(集成方解析后传入)。
  final VoidCallback? onNewSession;

  /// 新建工作区(应用内目录浏览 → workspaces.create)。
  final VoidCallback? onNewWorkspace;
  final Widget? settingsEntry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 56,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(
            right: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .28),
            ),
          ),
        ),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 16, 0, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: _BrandMark(size: 30)),
                    IconButton(
                      tooltip: '展开侧栏',
                      onPressed: onExpand,
                      icon: const _PanelExpandIcon(),
                    ),
                    IconButton(
                      tooltip: '新建会话(当前工作区)',
                      onPressed: onNewSession,
                      icon: const Icon(Icons.add, size: 20),
                    ),
                    if (onNewWorkspace != null)
                      IconButton(
                        tooltip: '新建工作区',
                        onPressed: onNewWorkspace,
                        icon: const Icon(
                          Icons.create_new_folder_outlined,
                          size: 20,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            if (settingsEntry != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: settingsEntry,
              ),
            const SafeArea(top: false, child: SizedBox(height: 10)),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatefulWidget {
  const _Sidebar({
    required this.vm,
    this.onNewSession,
    this.actions,
    this.workspaces,
    this.settings,
    this.scope,
    this.directory,
    this.theme,
    this.onOpenPairing,
    this.hostStatus,
    this.hosts,
    this.onSwitchHost,
    this.onRemoveHost,
    this.onReconnect,
    this.onCollapse,
    this.deviceName,
    this.onSetDeviceName,
    this.closeOnSelect = false,
  });
  final ChatViewModel vm;

  /// 新建会话;workspaceId 非空 = 归入该工作区,null = 未分组
  /// (web workspaces.startSession(workspaceId?) 语义)。
  final void Function(String? workspaceId)? onNewSession;
  final SessionActions? actions;
  final WorkspaceStoreView? workspaces;
  final SettingsStoreView? settings;
  final PrivilegeScope? scope;
  final DirectoryBrowserView? directory;
  final ThemeStoreView? theme;
  final VoidCallback? onOpenPairing;
  final ValueListenable<HostStatus>? hostStatus;
  final ValueListenable<String?>? deviceName;
  final Future<bool> Function(String)? onSetDeviceName;

  /// 方案 A 多主机:主机簿与切换/删除/重连(设置页「连接」分区)。
  final ValueListenable<HostBook>? hosts;
  final Future<void> Function(String hostId)? onSwitchHost;
  final Future<void> Function(String hostId)? onRemoveHost;
  final VoidCallback? onReconnect;

  /// 折叠侧栏(仅宽屏注入;null = 当前形态无折叠控件可示)。
  final VoidCallback? onCollapse;

  /// 窄屏抽屉模式:选中/新建会话后自动 pop 抽屉(参考 web 切会话即
  /// 回主界面;宽屏常驻形态恒为 false)。
  final bool closeOnSelect;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  final _searchController = TextEditingController();
  String _query = '';

  /// 搜索框展开态:展开时输入框占工具区全行,其余工具按钮让位
  /// (web 区头 searchExpanded 同款语义)。
  bool _searchOpen = false;

  /// 视图模式(web WorkspaceViewStore 复刻,默认与 web 一致:
  /// 按工作区分组 + 最近更新优先)。
  WorkspaceGroupMode _groupMode = WorkspaceGroupMode.workspace;
  WorkspaceOrderMode _orderMode = WorkspaceOrderMode.updated;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 选中会话;窄屏抽屉形态随即收起抽屉(closeOnSelect)。
  void _selectSession(String sessionId) {
    widget.vm.select(sessionId);
    _closeIfDrawer();
  }

  /// 新建会话;窄屏抽屉形态随即收起抽屉。
  /// [workspaceId] 非空 = 归入该工作区(组头「+」);null = 继承当前
  /// 选中会话的工作区,再退到未分组(web startSession 继承语义)。
  void _startNewSession([String? workspaceId]) {
    final cb = widget.onNewSession;
    if (cb == null) return;
    cb(workspaceId ?? _currentWorkspaceIdOf(widget.vm, widget.workspaces));
    _closeIfDrawer();
  }

  void _closeIfDrawer() {
    if (!widget.closeOnSelect) return;
    Navigator.of(context).maybePop();
  }

  List<SessionSummary> get _visible {
    // web sessionVisible:blank 会话仅当前选中那条可见,其余隐藏;
    // 默认按最后更新时间倒序(最新在最上面,sessionRecencyCompare)。
    final base =
        widget.vm.sessions
            .where((s) => !s.blank || s.sessionId == widget.vm.selectedId)
            .toList()
          ..sort(sessionRecencyCompare);
    if (_query.isEmpty) return base;
    final q = _query.toLowerCase();
    return base
        .where(
          (s) =>
              s.sessionId.toLowerCase().contains(q) ||
              (s.cwd ?? '').toLowerCase().contains(q) ||
              sessionDisplayTitle(s).toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 292,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(
            right: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .28),
            ),
          ),
        ),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const _BrandMark(),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'DshAPP',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text('AI 工作台', style: TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        // 连接状态徽标上移头部(原 gen1 徽标独占一行浪费空间;
                        // ready 态显示「已连接」,诊断代际收进 tooltip)。
                        _PhaseBadge(vm: widget.vm),
                        if (widget.onCollapse != null)
                          IconButton(
                            tooltip: '收起侧栏',
                            onPressed: widget.onCollapse,
                            icon: const _PanelCollapseIcon(),
                          )
                        else if (widget.closeOnSelect)
                          // 窄屏抽屉形态:顶部右上角同样给「收起」
                          // (用户诉求;收起 = 关抽屉,与宽屏控件同图标)。
                          IconButton(
                            tooltip: '收起侧栏',
                            onPressed: _closeIfDrawer,
                            icon: const _PanelCollapseIcon(),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // 工具区一行(web 区头复刻):搜索/排序方式/分组方式/
                    // 添加工作区并列;搜索展开后输入框占全行。
                    _sidebarToolbar(),
                  ],
                ),
              ),
            ),
            if (widget.vm.phase == ConnectionPhase.down &&
                widget.vm.failureReason != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Text(
                  '断线原因: ' +
                      (widget.vm.failureReason!.length > 120
                          ? widget.vm.failureReason!.substring(0, 120) + '…'
                          : widget.vm.failureReason!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const Divider(height: 1),
            // W1:workspace 分组浏览器(注入存在时显示;替代纯扁平列表的分组语义)。
            if (widget.workspaces != null)
              Expanded(
                child: WorkspaceBrowser(
                  store: widget.workspaces!,
                  sessionStream: widget.vm.summaries,
                  initialSessions: widget.vm.sessions,
                  selectedSessionId: widget.vm.selectedId,
                  query: _query,
                  groupMode: _groupMode,
                  orderMode: _orderMode,
                  callbacks: WorkspaceBrowserCallbacks(
                    onSelectSession: _selectSession,
                    // 组头「+」显式带组 id;未分组桶为 null(继承当前工作区)。
                    onNewSession: (wsId) => _startNewSession(wsId),
                    onRenameSession: (id, title) =>
                        widget.actions?.onRename?.call(id, title),
                    onFork: (id) => widget.actions?.onFork?.call(id),
                    onArchive: (_) {},
                    // 手动排序落盘:真实工作区账号才到这里(未分组/单列表
                    // 在浏览器内本地生效);失败仅告警,store 广播收敛。
                    onReorderSession: widget.workspaces == null
                        ? null
                        : (wsId, sessionId, beforeSessionId) => widget
                              .workspaces!
                              .insertSessionBefore(
                                wsId,
                                sessionId,
                                beforeSessionId: beforeSessionId,
                              )
                              .then((_) {}),
                  ),
                ),
              ),
            if (widget.workspaces == null)
              Expanded(
                child: visible.isEmpty
                    ? _SidebarEmptyState(hasQuery: _query.isNotEmpty)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        itemCount: visible.length,
                        itemBuilder: (context, i) {
                          final s = visible[i];
                          final selected = s.sessionId == widget.vm.selectedId;
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
                            minVerticalPadding: 7,
                            selected: selected,
                            // 与 WorkspaceBrowser 会话行一致:无专门图标,
                            // running 会话在 18dp 槽内显示 loading 小动画。
                            leading: SizedBox(
                              width: 18,
                              height: 18,
                              child: s.running
                                  ? const Center(
                                      child: SessionRunningIndicator(),
                                    )
                                  : null,
                            ),
                            // 标题 = web displayTitle 链:projections title
                            // → 工作区目录名 → 原始 id;blank 显示「新会话」。
                            title: Text(
                              sessionDisplayTitle(s),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // 相对时间槽仅非 blank(web !row.blank && timeLabel)。
                            subtitle: s.blank
                                ? null
                                : Text(
                                    sessionRelativeTime(s.updatedAt),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            onTap: () => _selectSession(s.sessionId),
                            // 操作菜单仅非 blank(web !row.blank && rowActions)。
                            trailing: !s.blank && _hasActions()
                                ? PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert, size: 16),
                                    itemBuilder: (context) => [
                                      if (widget.actions?.onRename != null)
                                        const PopupMenuItem(
                                          value: 'rename',
                                          child: Text('重命名'),
                                        ),
                                      if (widget.actions?.onFork != null)
                                        const PopupMenuItem(
                                          value: 'fork',
                                          child: Text('在此分叉'),
                                        ),
                                      if (widget.actions?.onExport != null)
                                        const PopupMenuItem(
                                          value: 'export',
                                          child: Text('导出 ZIP'),
                                        ),
                                    ],
                                    onSelected: (v) => _onMenu(v, s.sessionId),
                                  )
                                : null,
                          );
                        },
                      ),
              ),
            // 设置中心(常驻不门控):模型选择/发起配对/主题等
            // 全部作为子菜单收入设置页;特权分区(提供方/通用)在页内按
            // PrivilegeScope 隐藏 —— 手机形态必须能进设置配对。
            if (widget.settings != null && widget.scope != null) ...[
              const Divider(height: 1),
              SettingsEntryButton(
                scope: widget.scope!,
                store: widget.settings!,
                onPickModel: widget.actions?.onPickModel == null
                    ? null
                    : () {
                        // 模型选择针对当前会话;未选会话给出可感知提示
                        // 而非静默无效。
                        if (widget.vm.selectedId == null) {
                          _toast(context, '请先选择一个会话');
                          return;
                        }
                        widget.actions!.onPickModel!();
                      },
                onOpenPairing: widget.onOpenPairing,
                hostStatus: widget.hostStatus,
                deviceName: widget.deviceName,
                onSetDeviceName: widget.onSetDeviceName,
                hosts: widget.hosts,
                onSwitchHost: widget.onSwitchHost,
                onRemoveHost: widget.onRemoveHost,
                onReconnect: widget.onReconnect,
                theme: widget.theme,
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool _hasActions() =>
      widget.actions?.onRename != null ||
      widget.actions?.onFork != null ||
      widget.actions?.onExport != null;

  /// 工具区(web 区头复刻):搜索 / 排序方式 / 分组方式 / 添加工作区
  /// 并列一行;搜索展开时输入框占全行,其余按钮让位(web sectionHeader:
  /// searchExpanded 隐藏 headerActions 同款语义)。新建会话由组头「+」承载。
  Widget _sidebarToolbar() {
    if (_searchOpen) {
      return TextField(
        controller: _searchController,
        autofocus: true,
        decoration: InputDecoration(
          hintText: '搜索会话或工作区',
          prefixIcon: const Icon(Icons.search, size: 18),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 9,
          ),
          suffixIcon: IconButton(
            tooltip: '关闭搜索',
            icon: const Icon(Icons.close, size: 16),
            onPressed: () {
              _searchController.clear();
              setState(() {
                _query = '';
                _searchOpen = false;
              });
            },
          ),
        ),
        style: const TextStyle(fontSize: 13),
        onChanged: (v) => setState(() => _query = v),
      );
    }
    return Row(
      children: [
        // 注:原工具区首位的「新建会话」主按钮已移除(用户诉求:窄屏
        // 抽屉里点它的表现是「收起抽屉」,以 + 呈现很怪);新建会话改由
        // 组头常显「+」承载(web ProjectRowItem 同构)。
        IconButton(
          tooltip: '搜索会话或工作区',
          onPressed: () => setState(() => _searchOpen = true),
          icon: const Icon(Icons.search, size: 20),
        ),
        if (widget.workspaces != null) ...[
          _orderModeButton(),
          _groupModeButton(),
        ],
        // W2:添加工作区(应用内目录浏览,单列下钻;确认即 create)。
        if (widget.workspaces != null && widget.directory != null)
          IconButton(
            tooltip: '添加工作区',
            icon: const Icon(Icons.create_new_folder_outlined, size: 20),
            onPressed: () => showDirectoryBrowseSheet(
              context,
              store: widget.directory!,
              onConfirm: (path) async {
                // 确认即创建 workspace;失败 snackBar,成功由广播刷新浏览器。
                try {
                  await widget.workspaces!.create(path);
                } on Object catch (e) {
                  debugPrint('workspace create failed: ' + e.toString());
                }
              },
            ),
          ),
      ],
    );
  }

  /// 排序方式菜单(最近更新/手动排序;图标反映当前模式)。
  Widget _orderModeButton() {
    return PopupMenuButton<WorkspaceOrderMode>(
      tooltip: '排序方式:${_orderMode.label}',
      initialValue: _orderMode,
      position: PopupMenuPosition.under,
      icon: Icon(
        _orderMode == WorkspaceOrderMode.updated
            ? Icons.schedule
            : Icons.swap_vert,
        size: 20,
      ),
      itemBuilder: (context) => [
        for (final m in WorkspaceOrderMode.values)
          CheckedPopupMenuItem(
            value: m,
            checked: m == _orderMode,
            child: Text(m.label),
          ),
      ],
      onSelected: (m) => setState(() => _orderMode = m),
    );
  }

  /// 分组方式菜单(按工作区/单列表;图标反映当前模式)。
  Widget _groupModeButton() {
    return PopupMenuButton<WorkspaceGroupMode>(
      tooltip: '分组方式:${_groupMode.label}',
      initialValue: _groupMode,
      position: PopupMenuPosition.under,
      icon: Icon(
        _groupMode == WorkspaceGroupMode.workspace
            ? Icons.folder_copy_outlined
            : Icons.view_agenda_outlined,
        size: 20,
      ),
      itemBuilder: (context) => [
        for (final m in WorkspaceGroupMode.values)
          CheckedPopupMenuItem(
            value: m,
            checked: m == _groupMode,
            child: Text(m.label),
          ),
      ],
      onSelected: (m) => setState(() => _groupMode = m),
    );
  }

  Future<void> _onMenu(String action, String sessionId) async {
    final actions = widget.actions;
    if (actions == null) return;
    switch (action) {
      case 'rename':
        final controller = TextEditingController();
        final title = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('重命名会话'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '新标题', isDense: true),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (title != null && title.trim().isNotEmpty) {
          actions.onRename?.call(sessionId, title.trim());
        }
      case 'fork':
        actions.onFork?.call(sessionId);
      case 'export':
        actions.onExport?.call(sessionId);
    }
  }
}

class _BrandMark extends StatelessWidget {
  // 图源是带内边距的整版 icon master,同盒尺寸下视觉比纯色块小一号,
  // 故默认值较旧渐变版 +2,窄轨同理 28→30。
  const _BrandMark({this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .3),
        boxShadow: [
          BoxShadow(
            color: colors.primary.withValues(alpha: .24),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * .3),
        child: Image.asset(
          'assets/singleman_icon_master.png',
          width: size,
          height: size,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}

class _ConversationBackdrop extends StatelessWidget {
  const _ConversationBackdrop({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _BackdropPainter(Theme.of(context).colorScheme)),
        child,
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.colors);
  final ColorScheme colors;

  @override
  void paint(Canvas canvas, Size size) {
    final wash = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [
          colors.primary.withValues(alpha: .07),
          colors.surface.withValues(alpha: .02),
          colors.tertiary.withValues(alpha: .045),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, wash);
    final dot = Paint()..color = colors.primary.withValues(alpha: .05);
    for (var x = 36.0; x < size.width; x += 48) {
      for (var y = 26.0; y < size.height; y += 48) {
        canvas.drawCircle(Offset(x, y), 1.1, dot);
      }
    }
    final glow = Paint()
      ..shader =
          RadialGradient(
            colors: [colors.primary.withValues(alpha: .09), Colors.transparent],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * .86, size.height * .08),
              radius: 220,
            ),
          );
    canvas.drawCircle(Offset(size.width * .86, size.height * .08), 220, glow);
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) =>
      oldDelegate.colors != colors;
}

class _SidebarEmptyState extends StatelessWidget {
  const _SidebarEmptyState({required this.hasQuery});
  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasQuery ? Icons.search_off_rounded : Icons.forum_outlined,
            size: 30,
            color: colors.primary.withValues(alpha: .65),
          ),
          const SizedBox(height: 10),
          Text(
            hasQuery ? '没有找到匹配会话' : '还没有会话',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hasQuery ? '换个关键词试试' : '点上方工具栏的 + 开始新的对话',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.vm});
  final ChatViewModel vm;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final Color color;
    final String label;
    switch (vm.phase) {
      case ConnectionPhase.ready:
        color = colors.tertiary;
        // 「gen N」对用户表意不明:ready 态改说「已连接」,
        // 诊断信息(第几代连接)收进 tooltip 悬停可见。
        label = '已连接';
      case ConnectionPhase.connecting:
        color = colors.secondary;
        label = '连接中';
      case ConnectionPhase.down:
        color = colors.error;
        label = '已断开 · 重试中';
    }
    return Tooltip(
      message: vm.phase == ConnectionPhase.ready
          ? '已连接 · 第 ${vm.generation} 代连接'
          : label,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: .86, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOut,
        builder: (context, scale, child) => Transform.scale(
          scale: scale,
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: .2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 折叠指示「⟨⟨|」:双箭头 + 左缘竖条(web IconPanelLeftOutline 语义;
/// Flutter 图标库无同名面板图标,按用户要求以 <| 形拼出,箭头取双份
/// 保证 20dp 内可读)。
class _PanelCollapseIcon extends StatelessWidget {
  const _PanelCollapseIcon();

  @override
  Widget build(BuildContext context) {
    final color =
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.keyboard_double_arrow_left, size: 18),
        const SizedBox(width: 1),
        Container(
          width: 2.5,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
      ],
    );
  }
}

/// 展开指示「|⟩⟩」:_PanelCollapseIcon 的镜像(折叠轨道内用)。
class _PanelExpandIcon extends StatelessWidget {
  const _PanelExpandIcon();

  @override
  Widget build(BuildContext context) {
    final color =
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 2.5,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
        const SizedBox(width: 1),
        const Icon(Icons.keyboard_double_arrow_right, size: 18),
      ],
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.primary.withValues(alpha: .1),
                border: Border.all(
                  color: colors.primary.withValues(alpha: .16),
                ),
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 34,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '准备好开始了吗？',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              '选择一个会话，或从侧栏创建新的对话。\n你可以直接描述目标、粘贴代码，或使用 / 命令。',
              textAlign: TextAlign.center,
              style: TextStyle(height: 1.55, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: const [
                _HintPill(icon: Icons.code_rounded, label: '代码协作'),
                _HintPill(icon: Icons.lightbulb_outline_rounded, label: '想法梳理'),
                _HintPill(icon: Icons.task_alt_rounded, label: '任务执行'),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '选择或创建一个会话开始对话',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _HintPill extends StatelessWidget {
  const _HintPill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: colors.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// 当前选中会话的显示标题(web displayTitle 链:projections title →
/// 工作区目录名 → 原始 id;blank → 「新会话」);未选中回退应用名。
String _selectedSessionTitle(ChatViewModel vm) {
  final sid = vm.selectedId;
  if (sid == null) return 'DshAPP';
  for (final s in vm.sessions) {
    if (s.sessionId == sid) return sessionDisplayTitle(s);
  }
  return 'DshAPP';
}

/// 会话区标题栏动作簇(窄屏 AppBar actions 与宽屏标题行共用一份):
/// subagent 目录 / 后台任务 / 轨迹 / 命令与技能。
/// [sid] 为空(未选会话)时动作全部让位 —— 它们都是按会话寻址的。
List<Widget> _sessionTitleActions(
  BuildContext context, {
  required ChatViewModel vm,
  required String? sid,
  JobStoreView? jobs,
  SubagentStore? subagents,
  CommandStoreView? commands,
}) {
  if (sid == null) return const <Widget>[];
  return <Widget>[
    if (subagents != null)
      SubagentEntryButton(store: subagents, parentSessionId: sid),
    if (jobs != null) JobsTrigger(store: jobs, sessionId: sid),
    // W3:轨迹视图入口(整页推入;零新 RPC,纯 SessionLog 视图)。
    IconButton(
      tooltip: '轨迹',
      icon: const Icon(Icons.timeline),
      onPressed: () {
        final log = vm.logForSelected;
        if (log == null) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TrajectoryPage(
              sessionId: sid,
              events: log.events,
              eventStream: log.eventStream,
              onLoadOlder: () => vm.loadOlderSelected(),
              hasOlder: vm.hasOlderSelected,
            ),
          ),
        );
      },
    ),
    if (commands != null)
      IconButton(
        tooltip: '命令',
        icon: const Icon(Icons.terminal),
        onPressed: () => _openCommandMenu(context, sid, commands),
      ),
  ];
}

/// 打开命令与技能菜单(composer 底部「+」与标题栏「命令」共用)。
/// 命令 → execute(目录内预校验);skill → prompt 文本('/name' token,
/// dsh-tool-skill 在 pre-step 识别,DSH-PROTOCOL §5)。sheet 自行关闭。
Future<void> _openCommandMenu(
  BuildContext context,
  String sessionId,
  CommandStoreView store,
) {
  return showCommandMenu(
    context,
    sessionId: sessionId,
    store: store,
    onPick: (item) async {
      if (item.kind == CommandMenuItemKind.command) {
        try {
          await store.execute(sessionId, '/${item.name}');
        } on Object catch (e) {
          _toast(context, '命令执行失败: $e');
        }
      } else {
        final sender = ChatSenderBinding.of(context);
        try {
          await sender(sessionId, '/${item.name}');
        } on Object catch (e) {
          _toast(context, '发送失败: $e');
        }
      }
    },
  );
}

/// 当前选中会话所属工作区的显示名(无所属 = 未分组;无工作区域注入 = null)。
String? _workspaceLabelOf(ChatViewModel vm, WorkspaceStoreView? workspaces) {
  if (workspaces == null) return null;
  final sid = vm.selectedId;
  for (final ws in workspaces.currentWorkspaces) {
    if (sid != null && ws.sessionIds.contains(sid)) {
      if (ws.title.isNotEmpty) return ws.title;
      final segs = ws.path.split(RegExp('[/\\]'))
        ..removeWhere((s) => s.isEmpty);
      return segs.isEmpty ? ws.workspaceId : segs.last;
    }
  }
  return '未分组';
}

/// 工作区切换(web hero WorkspaceChip → picker):选中即在所选工作区新建会话
/// (web「在 {name} 中新建会话」语义;对既有会话不存在「移动工作区」)。
Future<void> _pickWorkspace(
  BuildContext context, {
  required ChatViewModel vm,
  required WorkspaceStoreView store,
  required void Function(String? workspaceId)? onNewSession,
}) {
  final current = _currentWorkspaceIdOf(vm, store);
  final newSession = onNewSession;
  if (newSession == null) return Future.value();
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('切换工作区', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          for (final ws in store.currentWorkspaces)
            ListTile(
              leading: const Icon(Icons.workspaces_outlined),
              title: Text(ws.title.isEmpty ? ws.path : ws.title),
              subtitle: Text(
                ws.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: ws.workspaceId == current
                  ? const Icon(Icons.check)
                  : null,
              onTap: () {
                Navigator.pop(sheetContext);
                newSession(ws.workspaceId);
              },
            ),
          ListTile(
            leading: const Icon(Icons.folder_off_outlined),
            title: const Text('未分组'),
            trailing: current == null ? const Icon(Icons.check) : null,
            onTap: () {
              Navigator.pop(sheetContext);
              newSession(null);
            },
          ),
        ],
      ),
    ),
  );
}

/// 预设目录默认项 id(无默认标记取首个;空目录 null)。
String? _defaultPresetIdOf(AgentPresetListValue roster) {
  for (final p in roster.presets) {
    if (p.isDefault) return p.id;
  }
  return roster.presets.isEmpty ? null : roster.presets.first.id;
}

/// 工作模式选择(web hero agentPreset chip → picker):拉取目录后底部 sheet;
/// blank 会话才可切(已开始的会话预设固定,host 拒绝换预设)。
Future<void> _pickWorkMode(
  BuildContext context, {
  required String sessionId,
  required AgentPresetStoreView store,
  required String? currentId,
  required VoidCallback onChanged,
}) async {
  AgentPresetListValue roster;
  try {
    roster = await store.list(force: true);
  } on Object catch (e) {
    _toast(context, '预设目录加载失败: $e');
    return;
  }
  if (!context.mounted) return;
  final current = currentId ?? _defaultPresetIdOf(roster);
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('工作模式', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          for (final p in roster.presets)
            ListTile(
              leading: Icon(
                p.broken != null ? Icons.error_outline : Icons.tune_outlined,
              ),
              title: Text(
                presetDisplayName(p.id, trust: p.trust, name: p.name),
              ),
              subtitle:
                  (presetDisplayDescription(
                        p.id,
                        trust: p.trust,
                        description: p.description,
                      ) ==
                      null)
                  ? null
                  : Text(
                      presetDisplayDescription(
                        p.id,
                        trust: p.trust,
                        description: p.description,
                      )!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.isDefault)
                    const Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: Text(
                        '默认',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (p.id == current) const Icon(Icons.check),
                ],
              ),
              onTap: p.broken != null
                  ? null
                  : () async {
                      final nav = Navigator.of(sheetContext);
                      try {
                        await store.select(sessionId, p.id);
                        nav.pop();
                        onChanged();
                      } on Object catch (e) {
                        nav.pop();
                        _toast(sheetContext, '切换失败: $e');
                      }
                    },
            ),
        ],
      ),
    ),
  );
}

/// 权限档位(web PermissionSelect options 对齐;'custom' 不提供切换入口)。
const List<(String, String)> _permissionChoices = [
  ('read-only', '只读'),
  ('workspace-write', '工作区可写'),
  ('danger-full-access', '完全访问'),
];

/// 权限切换(web PermissionSelect 对齐):经 **commands/execute** 通道执行
/// '/permission <id>'(web session.command(line) → remote.commands.execute;
/// 纯 admission 语义,**不产生用户消息** —— 之前误走 promptText 会把命令
/// 当普通文本发出,host 不执行、web 端也只多一条文本消息)。
/// permission/preset 事件回流后 composer chip 自然收敛。
Future<void> _pickPermission(
  BuildContext context, {
  required String sessionId,
  required String current,
  required CommandStoreView commands,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('访问模式', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          for (final (id, label) in _permissionChoices)
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: Text(label),
              trailing: id == current ? const Icon(Icons.check) : null,
              onTap: () async {
                Navigator.pop(sheetContext);
                if (id == 'danger-full-access') {
                  final ok = await _confirmFullAccess(context);
                  if (ok != true) return;
                }
                try {
                  // execute 的目录预校验需要缓存就绪:先拉目录(命中缓存即免往返)。
                  await commands.listCommands(sessionId);
                  await commands.execute(sessionId, '/permission $id');
                } on Object catch (e) {
                  _toast(context, '切换失败: $e');
                }
              },
            ),
        ],
      ),
    ),
  );
}

/// 显式风险确认(web RiskConfirmation 对齐:danger-full-access 不可跳过)。
Future<bool?> _confirmFullAccess(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('确认启用完全访问?'),
      content: const Text(
        '「完全访问」(danger-full-access)将授予工具不受限的文件系统与命令执行权限。',
        style: TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('我已了解风险,继续'),
        ),
      ],
    ),
  );
}

/// 消息面板:标题栏 + 节点流 + 交互面板 + composer。
///
/// 预设目录/模型名是异步数据,面板持少量本地缓存(按会话 id 失效),
/// 其余状态全部来自 [ChatViewModel](刷新安全纪律同 _InteractorPane)。
class _MessagePane extends StatefulWidget {
  const _MessagePane({
    required this.vm,
    this.onApproval,
    this.onQuestion,
    this.onQueueRemove,
    this.onQueueSteer,
    this.jobs,
    this.subagents,
    this.commands,
    this.attachments,
    this.onCancelSession,
    this.workspaces,
    this.actions,
    this.agentPresets,
    this.onNewSession,
    this.showTitleRow = true,
  });
  final ChatViewModel vm;
  final JobStoreView? jobs;
  final SubagentStore? subagents;
  final CommandStoreView? commands;
  final AttachmentFetchView? attachments;

  /// composer 上方行(web heroWorkspaceRow 对齐)所需域注入。
  final WorkspaceStoreView? workspaces;
  final SessionActions? actions;
  final AgentPresetStoreView? agentPresets;

  /// 新建会话(工作区切换选中即在目标工作区新建)。
  final void Function(String? workspaceId)? onNewSession;

  /// pane 内 52dp 标题行是否渲染:窄屏(<600dp)标题栏由 Scaffold
  /// AppBar 承载(菜单 + 新建 icon + 同源动作簇),此处必须让位,
  /// 否则窄屏出现两根标题栏(用户实报)。
  final bool showTitleRow;
  final void Function(String sessionId)? onCancelSession;
  final Future<void> Function(PendingApproval a, bool allow)? onApproval;
  final Future<String?> Function(
    PendingQuestion q,
    List<QuestionAnswerDraft> drafts,
  )?
  onQuestion;
  final void Function(Map<String, dynamic> item)? onQueueRemove;

  /// 插话:把排队项提升为 steering(session.updateQueue kind:'steer')。
  final void Function(Map<String, dynamic> item)? onQueueSteer;

  @override
  State<_MessagePane> createState() => _MessagePaneState();
}

class _MessagePaneState extends State<_MessagePane> {
  String? _loadedForSid;

  /// 预设目录缓存(id → 显示名)+ 默认预设 id(工作模式 chip)。
  Map<String, String> _presetNames = const <String, String>{};
  String? _defaultPresetId;

  /// 当前会话模型显示名(模型 chip;null = 未加载)。
  String? _modelName;

  @override
  void initState() {
    super.initState();
    _ensureLoaded();
  }

  @override
  void didUpdateWidget(covariant _MessagePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureLoaded();
  }

  /// 会话切换 → 预设目录/模型名按需重拉(同会话不重复)。
  void _ensureLoaded() {
    final sid = widget.vm.selectedId;
    if (sid == _loadedForSid) return;
    _loadedForSid = sid;
    _presetNames = const <String, String>{};
    _defaultPresetId = null;
    _modelName = null;
    _loadRoster();
    _loadModelLabel();
  }

  Future<void> _loadRoster() async {
    final store = widget.agentPresets;
    if (store == null) return;
    try {
      final roster = await store.list();
      if (!mounted || _loadedForSid != widget.vm.selectedId) return;
      setState(() {
        // 显示名走 web presetDisplayText 语义(内置 trust=system → 本地文案,
        // 否则 name ?? id;内置 id 目录未拉到也能凭 presetDisplayName 出名)。
        _presetNames = <String, String>{
          for (final p in roster.presets)
            p.id: presetDisplayName(p.id, trust: p.trust, name: p.name),
        };
        _defaultPresetId = _defaultPresetIdOf(roster);
      });
    } on Object {
      // 目录拉不到:chip 退化为裸 id/兜底名,不阻塞 composer。
    }
  }

  Future<void> _loadModelLabel() async {
    final load = widget.actions?.onLoadModelLabel;
    final sid = widget.vm.selectedId;
    if (load == null || sid == null) return;
    try {
      final name = await load(sid);
      if (!mounted || _loadedForSid != widget.vm.selectedId) return;
      setState(() => _modelName = name);
    } on Object {
      // 模型名读不到:chip 显示占位「模型」。
    }
  }

  /// 工作模式 chip 文案:选中预设名 → 默认预设名 → 内置映射 → 兜底。
  String _workModeLabel() {
    final vm = widget.vm;
    final selected = vm.selectedAgentPreset;
    if (selected != null) {
      return _presetNames[selected] ?? presetDisplayName(selected);
    }
    final def = _defaultPresetId;
    if (def != null) return _presetNames[def] ?? presetDisplayName(def);
    return '标准';
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final sid = vm.selectedId;
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        // 标题栏:当前会话标题 + 动作簇(subagent 目录/后台任务/轨迹/命令与
        // 技能;无动作注入不渲染)。原「对话工作台」文案行已按用户诉求移除。
        // 仅宽屏渲染(showTitleRow):窄屏 AppBar 已承载同款标题 + 动作簇。
        if (widget.showTitleRow &&
            sid != null &&
            (widget.jobs != null ||
                widget.subagents != null ||
                widget.commands != null))
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: .78),
              border: Border(
                bottom: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: .3),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _selectedSessionTitle(vm),
                    key: const ValueKey('pane-title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ..._sessionTitleActions(
                  context,
                  vm: vm,
                  sid: sid,
                  jobs: widget.jobs,
                  subagents: widget.subagents,
                  commands: widget.commands,
                ),
              ],
            ),
          ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: vm.nodes.isNotEmpty
                ? ChatNodeList(
                    key: const ValueKey('node-list'),
                    nodes: vm.nodes,
                    sessionId: vm.selectedId,
                    attachmentFetcher: widget.attachments,
                    // 消息操作区「分叉」:fork 当前会话 → 切换到子会话
                    //(对齐 web sessions.fork → open(childId))。
                    onFork: (seq) => vm.forkSelectedAt(seq),
                  )
                : (vm.bubbles.isEmpty
                      ? (vm.historyLoading && !vm.selectedBlank
                            // 非空会话装载历史中:加载态,不闪「准备好开始了吗」
                            // 的空白会话 UI(blank 会话才配那个空态)。
                            ? const Center(
                                key: ValueKey('history-loading'),
                                child: Padding(
                                  padding: EdgeInsets.all(24),
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            : const _EmptyConversation(
                                key: ValueKey('empty-conversation'),
                              ))
                      : ListView.builder(
                          key: const ValueKey('legacy-bubbles'),
                          padding: const EdgeInsets.all(12),
                          itemCount: vm.bubbles.length,
                          itemBuilder: (context, i) {
                            final b = vm.bubbles[i];
                            final isUser = b.role == 'user';
                            return Align(
                              alignment: isUser
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.78,
                                ),
                                decoration: BoxDecoration(
                                  color: isUser
                                      ? Theme.of(
                                          context,
                                        ).colorScheme.primaryContainer
                                      : Theme.of(
                                          context,
                                        ).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: b.role == 'assistant'
                                    ? MarkdownBody(
                                        data: b.text,
                                        styleSheet:
                                            MarkdownStyleSheet.fromTheme(
                                              Theme.of(context),
                                            ),
                                      )
                                    : Text(
                                        b.text,
                                        style: TextStyle(
                                          color: b.ephemeral
                                              ? Theme.of(context).disabledColor
                                              : null,
                                        ),
                                      ),
                              ),
                            );
                          },
                        )),
          ),
        ),
        _InteractorPane(
          vm: vm,
          onApproval: widget.onApproval,
          onQuestion: widget.onQuestion,
          onQueueRemove: widget.onQueueRemove,
          onQueueSteer: widget.onQueueSteer,
        ),
        // 任务清单面板(web conversation.input.dock order 0):todo/write
        // 投影,挂在输入区正上方;空清单零渲染。
        TodoPanel(todos: vm.todos),
        if (vm.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  size: 14,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    vm.lastError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
                // 常显「重试」:自动重试耗尽后错误不再无限赖着,用户可手动再拉。
                TextButton.icon(
                  onPressed: vm.retryHistory,
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('重试', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: UpgradeComposer(
              key: ValueKey('composer-${sid ?? 'none'}'),
              running: vm.selectedRunning,
              canSend: vm.canSend,
              // ── web InputBar 对齐:上方行(工作区 + 工作模式) ──
              // 仅 blank 会话(尚未开始)渲染 —— web hero 形态专属;会话一旦
              // 开始,工作区/预设都已固定,上方行整体隐藏(用户诉求)。
              workspaceLabel: !vm.selectedBlank
                  ? null
                  : _workspaceLabelOf(vm, widget.workspaces),
              onSwitchWorkspace:
                  (widget.workspaces == null || widget.onNewSession == null)
                  ? null
                  : () => _pickWorkspace(
                      context,
                      vm: vm,
                      store: widget.workspaces!,
                      onNewSession: widget.onNewSession,
                    ),
              workModeLabel: (widget.agentPresets == null || !vm.selectedBlank)
                  ? null
                  : _workModeLabel(),
              // web 语义:运行会话保持开始时的预设;blank 会话才可切换
              //(非 blank 时 chip 本身已不渲染,此标志仅兜底)。
              workModeLocked: !vm.selectedBlank,
              onSwitchWorkMode:
                  (widget.agentPresets == null ||
                      sid == null ||
                      !vm.selectedBlank)
                  ? null
                  : () => _pickWorkMode(
                      context,
                      sessionId: sid,
                      store: widget.agentPresets!,
                      currentId: vm.selectedAgentPreset,
                      onChanged: _loadRoster,
                    ),
              // ── web InputBar 对齐:底部工具行(+ 命令 / 权限 / 模型) ──
              onAddCommand: (widget.commands == null || sid == null)
                  ? null
                  : () => _openCommandMenu(context, sid, widget.commands!),
              // 权限切换依赖 commands/execute 通道:目录域缺席 → 不渲染 chip
              //(无法落地的切换入口只会误导)。
              permissionLabel: (sid == null || widget.commands == null)
                  ? null
                  : (vm.selectedPermissionPreset ?? 'default'),
              onSwitchPermission: (sid == null || widget.commands == null)
                  ? null
                  : () => _pickPermission(
                      context,
                      sessionId: sid,
                      current: vm.selectedPermissionPreset ?? 'default',
                      commands: widget.commands!,
                    ),
              modelLabel: widget.actions?.onLoadModelLabel == null
                  ? null
                  : (_modelName ?? ''),
              onPickModel: (widget.actions?.onPickModel == null)
                  ? null
                  : () {
                      widget.actions!.onPickModel!();
                      // 选择器异步应用后回读当前模型名(无完成信号,延迟重拉)。
                      Future.delayed(
                        const Duration(milliseconds: 1200),
                        _loadModelLabel,
                      );
                    },
              onSend: (text, {required steer}) async {
                final sid = vm.selectedId;
                if (sid == null) return;
                // 发送/插话同一回调;错误由组件内联映射展示。
                final senderWithSteer = ChatSenderBinding.senderWithSteerOf(
                  context,
                );
                vm.send(text, (id, t) => senderWithSteer(id, t, steer));
              },
              onCancel:
                  (widget.onCancelSession != null && vm.selectedId != null)
                  ? () => widget.onCancelSession!(vm.selectedId!)
                  : null,
              onCommandIntent: widget.commands == null
                  ? null
                  : (query) {
                      final sid = vm.selectedId;
                      if (sid == null || query.isEmpty) return;
                      // 占位回调:真正菜单经底部 sheet 打开(见页头动作区)。
                    },
            ),
          ),
        ),
      ],
    );
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      duration: const Duration(milliseconds: 2000),
      content: Text(message),
    ),
  );
}

/// 交互帧面板:审批卡 + 问答表单 + 队列 Dock。
/// 刷新安全(硬性纪律 —— 交互卡不因界面刷新丢渲染):
/// - initState 先用 store.current* 快照播种(错过流事件也能自愈:
///   重连重放 pending 帧发生在面板挂载之前时,纯 listen 会永远漏渲染);
/// - 订阅随 vm.interactor 引用变化重挂(vm 是 Listenable,面板随其重建);
/// - 问答表单/审批卡以 rpcId 为 key,列表增删不丢已选/已输入状态;
/// - 切换会话时从快照重读当前会话队列(队列流只在变更时推送)。
class _InteractorPane extends StatefulWidget {
  const _InteractorPane({
    required this.vm,
    this.onApproval,
    this.onQuestion,
    this.onQueueRemove,
    this.onQueueSteer,
  });
  final ChatViewModel vm;
  final Future<void> Function(PendingApproval a, bool allow)? onApproval;
  final Future<String?> Function(
    PendingQuestion q,
    List<QuestionAnswerDraft> drafts,
  )?
  onQuestion;
  final void Function(Map<String, dynamic> item)? onQueueRemove;

  /// 插话:把排队项提升为 steering(session.updateQueue kind:'steer')。
  final void Function(Map<String, dynamic> item)? onQueueSteer;

  @override
  State<_InteractorPane> createState() => _InteractorPaneState();
}

class _InteractorPaneState extends State<_InteractorPane> {
  List<PendingApproval> _approvals = const [];
  List<PendingQuestion> _questions = const [];
  List<Map<String, dynamic>> _queue = const [];
  InteractorStore? _subscribedTo;
  final _subs = <StreamSubscription<dynamic>>[];
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    widget.vm.addListener(_onVmChanged);
    _connect();
  }

  void _onVmChanged() {
    if (!mounted) return;
    // interactor 换引用(测试注入/未来重装)→ 重挂订阅。
    if (widget.vm.interactor != _subscribedTo) {
      _connect();
    }
    // 会话切换 → 队列从快照重读。
    if (widget.vm.selectedId != _selectedId) {
      _selectedId = widget.vm.selectedId;
      final queues = _subscribedTo?.currentQueues;
      final sid = _selectedId;
      setState(
        () => _queue = (sid != null && queues != null)
            ? (queues[sid] ?? const [])
            : const [],
      );
    }
  }

  void _connect() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final it = widget.vm.interactor;
    _subscribedTo = it;
    if (it == null) return;
    // 播种:current* 是最新收敛快照(广播流不重放,纯 listen 会漏)。
    _approvals = it.currentApprovals;
    _questions = it.currentQuestions;
    _selectedId = widget.vm.selectedId;
    final sid0 = _selectedId;
    _queue = sid0 == null ? const [] : (it.currentQueues[sid0] ?? const []);
    _subs.add(
      it.approvals.listen((l) {
        if (mounted) setState(() => _approvals = l);
      }),
    );
    _subs.add(
      it.questions.listen((l) {
        if (mounted) setState(() => _questions = l);
      }),
    );
    _subs.add(
      it.queues.listen((m) {
        final sid = widget.vm.selectedId;
        if (mounted && sid != null) {
          setState(() => _queue = m[sid] ?? const []);
        }
      }),
    );
  }

  @override
  void dispose() {
    widget.vm.removeListener(_onVmChanged);
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    super.dispose();
  }

  /// 会话短标签:当前会话 → null(不显示);其它会话 → '会话·后 4 位'。
  String? _labelFor(String sessionId) {
    final selected = widget.vm.selectedId;
    if (selected == sessionId) return null;
    final tail = sessionId.length <= 4
        ? sessionId
        : sessionId.substring(sessionId.length - 4);
    return '会话 ·$tail';
  }

  @override
  Widget build(BuildContext context) {
    // 多卡并存时限高滚动:待办审批/问答/队列可能同时堆积,不限高会把
    // composer 挤出屏幕(Column 溢出);限到视口 45%,内部滚动。
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .45,
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            ApprovalCards(
              approvals: _approvals,
              onRespond: (a, allow) => widget.onApproval?.call(a, allow),
              sessionLabel: {
                for (final a in _approvals)
                  if (_labelFor(a.sessionId) != null)
                    a.rpcId: _labelFor(a.sessionId)!,
              },
            ),
            for (final q in _questions)
              QuestionForm(
                key: ValueKey('question-form-${q.rpcId}'),
                question: q,
                onSubmit: (drafts) =>
                    widget.onQuestion?.call(q, drafts) ?? Future.value(null),
                sessionLabel: _labelFor(q.sessionId),
              ),
            QueueDock(
              items: _queue,
              running: widget.vm.selectedRunning,
              onRemove: widget.onQueueRemove,
              onSteer: widget.onQueueSteer,
            ),
          ],
        ),
      ),
    );
  }
}

/// composer 插话/发送统一入口壳(sender 必备,steerSender 可选;缺省插话
/// 退化为 queue)。由 SinglemanApp 注入,composer 经 dependOnInherited 取用。
class ChatSenderBinding extends InheritedWidget {
  const ChatSenderBinding({
    super.key,
    required this.sender,
    this.steerSender,
    required super.child,
  });

  final Future<void> Function(String sessionId, String text) sender;
  final Future<void> Function(String sessionId, String text, bool steer)?
  steerSender;

  /// 便捷取用:普通发送(命令/skill/权限切换等 prompt 语义,无插话)。
  static Future<void> Function(String sessionId, String text) of(
    BuildContext context,
  ) {
    final w = context.dependOnInheritedWidgetOfExactType<ChatSenderBinding>();
    assert(w != null, 'ChatSenderBinding missing in tree');
    return w!.sender;
  }

  /// W2:composer 插话/发送统一入口;steerSender 缺席时插话退化为 queue。
  static Future<void> Function(String sessionId, String text, bool steer)
  senderWithSteerOf(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<ChatSenderBinding>();
    assert(w != null, 'ChatSenderBinding missing in tree');
    final withSteer = w!.steerSender;
    final plain = w.sender;
    if (withSteer != null) return withSteer;
    return (id, text, steer) => plain(id, text);
  }

  @override
  bool updateShouldNotify(ChatSenderBinding oldWidget) =>
      oldWidget.sender != sender;
}
