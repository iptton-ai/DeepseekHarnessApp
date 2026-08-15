// PromptMode 域(W2-A):session.prompt 的 mode 枚举 + 插话判定 + 错误文案映射。
//
// 契约(DSH-PROTOCOL §5/§9 + 任务冻结结论):
// - mode 枚举 zod 实证为 'queue' | 'steer'(steer = 插话进运行中轮次);
//   生成代码里 mode 是 Object,调用方必须传字符串字面量 —— 本文件提供 wire 串
// - canSteer:客户端侧预判 —— 会话 running 才可能插话;服务端仍是权威
//   (steer-unavailable / agent-busy 等错误码照样拒绝),UI 必须内联展示拒绝原因
// - 纯 Dart:不 import flutter / wire / connection,错误映射只吃裸 code 字符串;
//   从异常提取 code 的胶水在 UI 层(composer_pro.dart 的 promptErrorCode)

/// 会话提示模式(映射 wire 的 'queue' | 'steer')。
///
/// - [PromptMode.queue]:排队发送(会话静止时;AgentLoop 空闲即认领)
/// - [PromptMode.steer]:插话(running 轮次中途插入;服务端可拒)
enum PromptMode {
  queue('queue', '发送'),
  steer('steer', '插话');

  const PromptMode(this.wire, this.label);

  /// wire 字符串字面量(传给 session.prompt 的 mode 字段)。
  final String wire;

  /// 动作按钮的用户可读文案(发送 / 插话)。
  final String label;

  /// wire 字符串 → 枚举;未知值按 queue 兜底(防御 wire 变化)。
  static PromptMode fromWire(Object? mode) =>
      mode is String && mode == 'steer' ? PromptMode.steer : PromptMode.queue;

  /// 当前运行态下的发送模式:running → steer,否则 queue。
  static PromptMode forRunning(bool running) =>
      running ? PromptMode.steer : PromptMode.queue;
}

/// 客户端侧插话预判:会话 running 才可能插话。
///
/// 这只是 UI 前置条件(running 时主按钮变「插话」);服务端仍可能因
/// steer-unavailable / agent-busy 等拒绝,失败文案见 [promptErrorMessage]。
bool canSteer(bool running) => running;

/// 业务错误码 → 用户可读文案。
///
/// [code] 为 null(非业务异常)或未知码时给出兜底;带 [serverMessage] 时拼在末尾
/// 一并展示(服务端 detail 常是最可读的一行)。所有文案含错误码,便于对照
/// DSH-PROTOCOL 的封闭错误码集合排查。
String promptErrorMessage(String? code, {String? serverMessage}) {
  final base = switch (code) {
    'steer-unavailable' =>
      '无法插话:当前轮次已结束或会话不接受插话(steer-unavailable)',
    'agent-busy' => '会话正忙,请稍后再试(agent-busy)',
    'unknown-command' => '未知命令:仅支持目录内命令(unknown-command)',
    'command-error' => '命令执行失败(command-error)',
    'model-unavailable' => '当前模型不可路由,无法发送(model-unavailable)',
    'session-not-found' => '会话不存在或已删除(session-not-found)',
    'queue-item-not-found' => '队列项不存在,可能已被处理(queue-item-not-found)',
    'cancelled' => '操作已取消(cancelled)',
    'internal' => '内部错误,请稍后重试(internal)',
    null => '发送失败',
    _ => '发送失败($code)',
  };
  if (serverMessage == null || serverMessage.isEmpty) return base;
  return '$base\n$serverMessage';
}
