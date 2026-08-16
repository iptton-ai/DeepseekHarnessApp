// AgentPresetStore — 工作模式(Agent 预设)域状态(composer 上方行消费)。
//
// 契约(对齐 web ui-agent-preset 插件行为):
// - agentPreset.list:空 payload → {presets, authorable, hasDocument};
//   presets 含 id/name/description/trust/isDefault/broken
// - agentPreset.select:{sessionId, agentPreset} → 选中值回流;
//   会话开始后预设固定(host 拒绝 → agent-preset-locked 等业务错误原样抛)
// 方法名是 RpcMethodMap 的点命名(agentPreset.*),常量在生成 RpcMethods 里;
// ⚠️ 不要仿 commands/list 用斜杠 —— 那是 typert 直连端点,预设是普通 unary
//   路由,斜杠名 host 直接 404(曾致「预设目录加载失败」,见 PROGRESS)。
// - 缓存:list 结果缓存到代际翻转(重连)或预设目录失效事件
// - web 语义:「即将开始的会话」用 hero chip 选择;已开始的会话只读展示。
//   移动端 composer 上方行常显 chip,blank 会话可切,非 blank 只读。
import 'dart:async';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// UI 依赖的窄视图(widget 测试可注入假实现,不碰 socket)。
abstract class AgentPresetStoreView {
  /// 拉取预设目录(缓存优先;force 绕过)。
  Future<AgentPresetListValue> list({bool force = false});

  /// 为 [sessionId] 选择预设;会话已开始时服务端拒绝(业务错误上抛)。
  Future<AgentPresetSelectValue> select(String sessionId, String agentPreset);
}

/// 内置预设的本地显示文案(web ui-agent-preset 的 BUILT_IN_PRESET_KEYS +
/// zh locale 对齐;注意内置 id `code` 的中文显示名是「PTC 模式」)。
const Map<String, (String, String)> builtinPresetCopy = {
  'standard': ('标准模式', '功能完整的编码 Agent,支持文件编辑、Shell、文件与网页检索、Skills、计划、目标、子代理和工作流。'),
  'code': ('PTC 模式', '具备标准模式的全部能力,并通过 Code Mode SDK 呈现工具,让模型用一个 TypeScript 程序组合多步操作。'),
  'minimal': ('极简模式', '仅提供持久 bash 与 str_replace_editor 的双工具编码 Agent。'),
  'cordis': ('创造模式', '用于创建自定义 Agent preset:具备标准模式的全部能力,并提供运行时检查、插件实验和 preset 创作指导。'),
};

/// 预设显示名(web presetDisplayText 对齐):内置(trust=='system' 且 id 命中)
/// → 本地文案;否则取 name;再退内置映射(目录未拉到时凭 id 也能出名);
/// 最后裸 id。
String presetDisplayName(String id, {Object? trust, String? name}) {
  if (trust is String && trust == 'system') {
    final copy = builtinPresetCopy[id];
    if (copy != null) return copy.$1;
  }
  if (name != null && name.isNotEmpty) return name;
  return builtinPresetCopy[id]?.$1 ?? id;
}

/// 预设显示描述(同上语义;无可用描述返回 null)。
String? presetDisplayDescription(String id,
    {Object? trust, String? description}) {
  if (trust is String && trust == 'system') {
    final copy = builtinPresetCopy[id];
    if (copy != null) return copy.$2;
  }
  return (description == null || description.isEmpty) ? null : description;
}

class AgentPresetStore implements AgentPresetStoreView {
  AgentPresetStore({required this.api, required this.connection}) {
    _snapshotsSub = connection.snapshots.listen(_onSnapshot);
    _hostSub = connection.hostFrames.listen(_onHostFrame);
  }

  final ApiClient api;
  final ConnectionController connection;

  AgentPresetListValue? _cache;
  StreamSubscription<ConnectionSnapshot>? _snapshotsSub;
  StreamSubscription<HostFrame>? _hostSub;
  int _lastReadyGeneration = 0;
  bool _disposed = false;

  /// 测试钩子:agent-presets/list 实际 HTTP 调用次数(缓存命中不计数)。
  int listCalls = 0;

  @override
  Future<AgentPresetListValue> list({bool force = false}) async {
    if (!force && _cache != null) return _cache!;
    listCalls += 1;
    final value = await api.call<AgentPresetListValue>(
      RpcMethods.agentPresetList,
      <String, dynamic>{},
      parse: AgentPresetListValue.fromJson,
    );
    _cache = value;
    return value;
  }

  @override
  Future<AgentPresetSelectValue> select(String sessionId, String agentPreset) =>
      api.call<AgentPresetSelectValue>(
        RpcMethods.agentPresetSelect,
        <String, dynamic>{'sessionId': sessionId, 'agentPreset': agentPreset},
        parse: AgentPresetSelectValue.fromJson,
      );

  void _onSnapshot(ConnectionSnapshot snap) {
    if (_disposed) return;
    // 代际翻转(重连):缓存作废,重拉。
    if (snap.phase == ConnectionPhase.ready &&
        snap.generation != _lastReadyGeneration) {
      _lastReadyGeneration = snap.generation;
      _cache = null;
    }
  }

  void _onHostFrame(HostFrame frame) {
    if (_disposed) return;
    // 预设目录变更(remote-event:agent-preset/selected)→ 丢弃缓存
    //(同 CommandStore 的软失效;select 成功只是换会话预设,目录不变)。
    if (frame is HostFrameHostRemoteEvent &&
        frame.event == 'agent-preset/selected') {
      _cache = null;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _snapshotsSub?.cancel();
    await _hostSub?.cancel();
  }
}