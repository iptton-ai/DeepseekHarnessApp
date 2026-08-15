// CommandStore — W2-D 斜杠命令体系统一(web commands + skill 菜单合并复刻)。
//
// 契约(DSH-PROTOCOL §9 + docs/audit/orchestration.md §1/§3):
// - commands/list 远程端点:payload 必须为 {args:{agentId}};响应是双层信封
//   (外层 server-response.result.ok 之后,内层再一层 {ok, value/error},解析剥两层)
// - commands/list 返回裸数组 [{name, description, input?:{hint}}];
//   subagent 会话作 agentId → agent-busy(ownership fence)→ 空目录+错误位,
//   菜单降级为 skill-only(内联提示 + 重试)
// - commands/execute {agentId, line} 成功返回 void(外层 ok:true 无 value);
//   未知命令服务端静默吞 → 客户端必须目录内预校验,否则本地拒绝
// - 缓存 per-session(只缓存成功目录,失败不缓存,重试=重新拉取);
//   失效:host/remote-event commands/change 与 agent-preset/selected → 丢弃;
//   代际翻转(重连)→ 清空全部缓存
// - skill 源:注入 SkillCatalog(goal_store.dart);listAll 合并 commands + skills
//   ('/name' 形式)为分组菜单;skill.list 失败 → 技能组静默丢弃(audit §3)
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/sessions/goal_store.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 远程端点方法名(斜杠命名,不在生成 RpcMethods 里)。
abstract final class CommandMethods {
  CommandMethods._();
  static const String list = 'commands/list';
  static const String execute = 'commands/execute';
}

/// 转发的远程失效事件(host/remote-event 的 event 字符串,DSH-PROTOCOL §9)。
abstract final class CommandInvalidationEvents {
  CommandInvalidationEvents._();
  static const String commandsChange = 'commands/change';
  static const String agentPresetSelected = 'agent-preset/selected';
}

/// 一条命令目录条目(裸数组元素 {name, description, input?:{hint}})。
class CommandEntry {
  const CommandEntry({
    required this.name,
    required this.description,
    this.hint,
  });

  factory CommandEntry.fromJson(Map<String, dynamic> json) {
    final input = json['input'];
    return CommandEntry(
      name: json['name'] is String ? json['name'] as String : '',
      description:
          json['description'] is String ? json['description'] as String : '',
      hint: input is Map<String, dynamic> && input['hint'] is String
          ? input['hint'] as String
          : null,
    );
  }

  final String name;
  final String description;

  /// input.hint(leadingInput 占位提示;无则 null)。
  final String? hint;
}

/// 目录错误(错误位);isAgentBusy 供菜单降级为 skill-only 判定。
class CommandListError {
  const CommandListError(this.code, this.message);
  final String code;
  final String? message;
  bool get isAgentBusy => code == 'agent-busy';
  @override
  String toString() =>
      'CommandListError($code${message == null ? '' : ', $message'})';
}

/// commands/list 的结果:成功目录 or 失败降级(空目录 + 错误位)。
///
/// 只缓存成功结果;失败(含 agent-busy)不缓存 —— 重试天然重新拉取。
class CommandListResult {
  CommandListResult.ok(List<CommandEntry> commands)
      : commands = List<CommandEntry>.unmodifiable(commands),
        error = null;

  CommandListResult.degraded(this.error)
      : commands = const <CommandEntry>[];

  final List<CommandEntry> commands;
  final CommandListError? error;

  bool get isDegraded => error != null;
  bool get isAgentBusy => error?.isAgentBusy ?? false;
}

/// 合并菜单条目的类型:host 命令 / skill。
enum CommandMenuItemKind { command, skill }

/// 合并菜单条目(listAll 的输出,UI 只消费这个)。
class CommandMenuItem {
  CommandMenuItem.command(CommandEntry entry)
      : kind = CommandMenuItemKind.command,
        name = entry.name,
        description = entry.description,
        hint = entry.hint,
        skillModelInvocable = null;

  CommandMenuItem.skill(SkillEntry skill)
      : kind = CommandMenuItemKind.skill,
        name = skill.name,
        description = skill.description,
        hint = null,
        skillModelInvocable = skill.modelInvocable;

  final CommandMenuItemKind kind;
  final String name;

  /// command.description / skill.description(现有 skill 菜单格式)。
  final String description;

  /// 仅命令有:input.hint(占位提示)。
  final String? hint;

  /// 点击派发的行文本:'/name'。
  String get slash => '/' + name;

  /// 仅 skill 有:modelInvocable(现有 skill 菜单用图标区分)。
  final bool? skillModelInvocable;

  bool get isCommand => kind == CommandMenuItemKind.command;
  bool get isSkill => kind == CommandMenuItemKind.skill;
}

/// 合并菜单目录(分组:命令/skill)。
class CommandMenu {
  const CommandMenu({
    required this.commands,
    required this.skills,
    required this.degraded,
    this.errorCode,
    this.errorMessage,
  });

  final List<CommandMenuItem> commands;
  final List<CommandMenuItem> skills;

  /// 命令目录降级(agent-busy/失败)→ UI 显示错误位 + 重试,菜单 skill-only。
  final bool degraded;
  final String? errorCode;
  final String? errorMessage;

  bool get isEmpty => commands.isEmpty && skills.isEmpty;
}

/// UI 依赖的窄视图(widget 测试注入假实现,不碰 socket/HTTP)。
abstract class CommandStoreView {
  /// 拉取某会话命令目录(缓存命中即返回;force 强制重取)。
  Future<CommandListResult> listCommands(String sessionId,
      {bool force = false});

  /// 合并目录:commands + skills('/name' 形式),分组:命令/skill。
  Future<CommandMenu> listAll(String sessionId, {bool force = false});

  /// 执行命令:客户端目录内预校验,未知命令本地拒绝(服务端静默吞)。
  Future<void> execute(String sessionId, String line);
}

/// 域异常基类。
class CommandStoreException implements Exception {
  const CommandStoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 本地预校验拒绝:命令名不在目录 / 目录未就绪。
class UnknownCommandException extends CommandStoreException {
  UnknownCommandException(String name, {bool directoryReady = true})
      : super(directoryReady
            ? '未知命令 /$name'
            : '命令目录未就绪,拒绝执行 /$name');
}

/// 远程执行失败(载波/业务/内层错误)。
class CommandExecuteException extends CommandStoreException {
  const CommandExecuteException(super.message);
}

/// 从行文本解析命令名:'/goal set x' → 'goal';非斜杠行返回 null。
String? commandNameOf(String line) {
  final t = line.trim();
  if (!t.startsWith('/')) return null;
  final rest = t.substring(1);
  var end = rest.length;
  for (var i = 0; i < rest.length; i++) {
    if (_isWhitespace(rest.codeUnitAt(i))) {
      end = i;
      break;
    }
  }
  final name = rest.substring(0, end);
  return name.isEmpty ? null : name;
}

bool _isWhitespace(int codeUnit) =>
    codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0A || codeUnit == 0x0D;

/// fuzzy:子序列不区分大小写匹配;前缀优先,其余保持原序
/// (简化版,不追 web 全序;空查询返回原序)。
List<CommandMenuItem> filterMenu(List<CommandMenuItem> items, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return List<CommandMenuItem>.of(items);
  final prefix = <CommandMenuItem>[];
  final subseq = <CommandMenuItem>[];
  for (final item in items) {
    final name = item.name.toLowerCase();
    if (name.startsWith(q)) {
      prefix.add(item);
    } else if (_isSubsequence(name, q)) {
      subseq.add(item);
    }
  }
  return <CommandMenuItem>[...prefix, ...subseq];
}

bool _isSubsequence(String haystack, String needle) {
  if (needle.isEmpty) return true;
  var i = 0;
  for (var j = 0; j < haystack.length && i < needle.length; j++) {
    if (haystack.codeUnitAt(j) == needle.codeUnitAt(i)) i++;
  }
  return i == needle.length;
}

class CommandStore implements CommandStoreView {
  CommandStore({
    required this.api,
    required this.connection,
    required this.skills,
  }) {
    _snapshotsSub = connection.snapshots.listen(_onSnapshot);
    _hostSub = connection.hostFrames.listen(_onHostFrame);
  }

  final ApiClient api;
  final ConnectionController connection;
  final SkillCatalog skills;

  final Map<String, CommandListResult> _cache = <String, CommandListResult>{};
  StreamSubscription<ConnectionSnapshot>? _snapshotsSub;
  StreamSubscription<HostFrame>? _hostSub;
  int _lastReadyGeneration = 0;
  bool _disposed = false;

  /// 测试钩子:commands/list 实际 HTTP 调用次数(缓存命中不计数)。
  int listCalls = 0;

  /// 测试钩子:commands/execute 实际 HTTP 调用次数(本地拒绝不计数)。
  int executeCalls = 0;

  @override
  Future<CommandListResult> listCommands(String sessionId,
      {bool force = false}) async {
    if (!force) {
      final cached = _cache[sessionId];
      if (cached != null) return cached;
    }
    listCalls += 1;
    try {
      final commands = await api.call<List<CommandEntry>>(
        CommandMethods.list,
        <String, dynamic>{'args': <String, dynamic>{'agentId': sessionId}},
        parse: _parseCommandList,
      );
      final result = CommandListResult.ok(commands);
      _cache[sessionId] = result;
      return result;
    } on _InnerError catch (e) {
      // 内层信封 ok:false(typert 业务错误,如 agent-busy)。
      return CommandListResult.degraded(CommandListError(e.code, e.message));
    } on RpcBusinessError catch (e) {
      // 外层 RpcResult ok:false(防御:远程端点也可能在外层拒绝)。
      return CommandListResult.degraded(
          CommandListError(_rpcErrorCode(e.error), null));
    } on ApiTimeout {
      return CommandListResult.degraded(const CommandListError('timeout', null));
    } on CarrierError catch (e) {
      return CommandListResult.degraded(
          CommandListError('transport', e.toString()));
    } catch (e) {
      // 畸形响应等:降级 + 重试,绝不让 UI 崩。
      return CommandListResult.degraded(
          CommandListError('malformed', e.toString()));
    }
  }

  @override
  Future<CommandMenu> listAll(String sessionId, {bool force = false}) async {
    final result = await listCommands(sessionId, force: force);
    var skills = <SkillEntry>[];
    try {
      skills = await this.skills.list(force: force);
    } catch (_) {
      // skill.list 失败 → 技能组静默丢弃(audit §3:只显示可用组)。
    }
    return CommandMenu(
      commands: <CommandMenuItem>[
        for (final c in result.commands) CommandMenuItem.command(c),
      ],
      skills: <CommandMenuItem>[
        for (final s in skills) CommandMenuItem.skill(s),
      ],
      degraded: result.isDegraded,
      errorCode: result.error?.code,
      errorMessage: result.error?.message,
    );
  }

  @override
  Future<void> execute(String sessionId, String line) async {
    final name = commandNameOf(line);
    final directory = _cache[sessionId];
    if (directory == null) {
      // 目录未就绪(未拉取/已被失效事件丢弃):本地拒绝,不碰服务端。
      throw UnknownCommandException(name ?? '', directoryReady: false);
    }
    if (name == null || !directory.commands.any((c) => c.name == name)) {
      throw UnknownCommandException(name ?? '');
    }
    executeCalls += 1;
    try {
      await api.call<void>(
        CommandMethods.execute,
        <String, dynamic>{
          'args': <String, dynamic>{'agentId': sessionId, 'line': line},
        },
        parse: _parseExecute,
      );
    } on _InnerError catch (e) {
      throw CommandExecuteException('命令执行失败: ' +
          e.code +
          (e.message == null ? '' : ' ' + e.message!));
    } on RpcBusinessError catch (e) {
      throw CommandExecuteException('命令执行失败: ' + _rpcErrorCode(e.error));
    } on ApiTimeout {
      throw const CommandExecuteException('命令执行超时');
    } on CarrierError catch (e) {
      throw CommandExecuteException('传输失败: ' + e.toString());
    }
  }

  /// commands/list 解析:剥双层信封 —— parse 收到内层 {ok, value/error}。
  static List<CommandEntry> _parseCommandList(Map<String, dynamic> inner) {
    if (inner['ok'] == false) {
      final err = inner['error'];
      throw _InnerError(
        err is Map<String, dynamic>
            ? (err['code'] as String? ?? 'unknown')
            : 'unknown',
        err is Map<String, dynamic> ? err['message'] as String? : null,
      );
    }
    final value = inner['value'];
    if (value is! List) {
      throw const FormatException('commands/list: value 不是数组');
    }
    return <CommandEntry>[
      for (final e in value)
        e is Map<String, dynamic>
            ? CommandEntry.fromJson(e)
            : const CommandEntry(name: '', description: ''),
    ];
  }

  /// commands/execute 解析:成功 void(外层 ok:true 无 value);防御内层信封。
  static void _parseExecute(Map<String, dynamic> inner) {
    if (inner['ok'] == false) {
      final err = inner['error'];
      throw _InnerError(
        err is Map<String, dynamic>
            ? (err['code'] as String? ?? 'unknown')
            : 'unknown',
        err is Map<String, dynamic> ? err['message'] as String? : null,
      );
    }
  }

  /// RpcError 变体没有统一 code 字段,防御读 toJson()['code']。
  static String _rpcErrorCode(RpcError e) {
    final code = e.toJson()['code'];
    return code is String ? code : 'rpc-error';
  }

  void _onSnapshot(ConnectionSnapshot snap) {
    if (_disposed) return;
    if (snap.phase == ConnectionPhase.ready &&
        snap.generation > _lastReadyGeneration) {
      _lastReadyGeneration = snap.generation;
      // 重连=新代际:命令目录可能已变,清空全部缓存。
      _cache.clear();
    }
  }

  void _onHostFrame(HostFrame frame) {
    if (_disposed) return;
    if (frame is HostFrameHostRemoteEvent &&
        (frame.event == CommandInvalidationEvents.commandsChange ||
            frame.event == CommandInvalidationEvents.agentPresetSelected)) {
      // 目录属 preset/命令集:软失效,丢弃全部会话缓存(消费端自行重拉)。
      _cache.clear();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _snapshotsSub?.cancel();
    await _hostSub?.cancel();
  }
}

/// typert 内层信封的业务错误(code + message 裸 JSON)。
class _InnerError implements Exception {
  const _InnerError(this.code, this.message);
  final String code;
  final String? message;
}
