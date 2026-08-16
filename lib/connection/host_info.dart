// 宿主状态(M6.4):设置页「连接」分区「已连接 <机器名>」的数据源。
//
// 机器名链路(两跳,取新者优先):
// 1. 种子 —— 配对确认响应的 host_label 快照(随凭证持久化,离线也能显示);
// 2. 当前值 —— 连接就绪(新代际)后 GET {base}/pair/api/host(dsh-mobile
//    plugin,经网关隧道中转,Host 已被改写为 loopback 故可达)。
//    plugin 侧改名即时生效;老 plugin(404)/密码登录形态静默保持种子。
//
// 相位(up)= 事件 WS 就绪(与聊天界面同源 ConnectionController);authed 由
// 令牌供给回调决定 —— 远程且持令牌时设置页用「已连接」行替换「发起配对」。
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/connection_controller.dart';

/// 一次宿主状态快照(不可变;经 ValueListenable 广播)。
class HostStatus {
  const HostStatus({required this.authed, required this.up, this.machine = ''});

  /// 已持设备令牌(已配对/密码已登录);loopback 直连恒 false。
  final bool authed;

  /// 事件 WS 当前就绪。
  final bool up;

  /// 宿主机器名(空 = 未知,UI 回落网关主机名)。
  final String machine;
}

/// 连接相位 + 机器名探测的组合器。
/// [snapshots]/[current] 由集成方取自 ConnectionController(拆开注入是为
/// 了测试可用 StreamController 假件,不必拉起真实 WS 状态机)。
class HostStatusController {
  HostStatusController({
    required Stream<ConnectionSnapshot> snapshots,
    required ConnectionSnapshot? Function() current,
    required ApiClient api,
    required bool Function() authed,
    String seedMachine = '',
  })  : _snapshots = snapshots,
        _current = current,
        _api = api,
        _authed = authed {
    _status = ValueNotifier<HostStatus>(
      HostStatus(authed: authed(), up: false, machine: seedMachine),
    );
  }

  final Stream<ConnectionSnapshot> _snapshots;
  final ConnectionSnapshot? Function() _current;
  final ApiClient _api;
  final bool Function() _authed;
  late final ValueNotifier<HostStatus> _status;
  StreamSubscription<ConnectionSnapshot>? _sub;
  int _probedGeneration = -1;
  bool _disposed = false;

  ValueListenable<HostStatus> get status => _status;

  void start() {
    if (_disposed) return;
    _sub = _snapshots.listen(_onSnapshot);
    // 广播流无重放:监听时可能已 ready,用当前快照补判一次。
    final now = _current();
    if (now != null) _onSnapshot(now);
  }

  void _onSnapshot(ConnectionSnapshot snap) {
    if (_disposed) return;
    final up = snap.phase == ConnectionPhase.ready;
    final prev = _status.value;
    if (prev.up != up || prev.authed != _authed()) {
      _status.value = HostStatus(
        authed: _authed(),
        up: up,
        machine: prev.machine,
      );
    }
    // 每代际只探一次(重连换代会重探 —— 宿主可能改过名)。
    if (up && snap.generation != _probedGeneration) {
      _probedGeneration = snap.generation;
      _probe();
    }
  }

  /// 配对/登录成功时注入机器名种子(确认响应回显;空值忽略)。
  void seedMachine(String label) {
    if (label.isEmpty || _disposed) return;
    final prev = _status.value;
    if (prev.machine == label) return;
    _status.value = HostStatus(
      authed: _authed(),
      up: prev.up,
      machine: label,
    );
  }

  /// 令牌到位后刷新鉴权位(首登后设置页立即切换到「已连接」形态)。
  void refreshAuthed() {
    if (_disposed) return;
    final prev = _status.value;
    final authed = _authed();
    if (prev.authed == authed) return;
    _status.value = HostStatus(
      authed: authed,
      up: prev.up,
      machine: prev.machine,
    );
  }

  Future<void> _probe() async {
    final Map<String, dynamic> json;
    try {
      json = await _api.getJson('/pair/api/host',
          timeout: const Duration(seconds: 10));
    } on Object {
      // 老 plugin(404)/密码形态上游无插件/瞬断:保持现有种子,静默。
      return;
    }
    if (_disposed) return;
    final label = json['label'];
    final host = json['hostname'];
    var machine = label is String ? label.trim() : '';
    if (machine.isEmpty && host is String) {
      machine = host.split('.').first.trim();
    }
    if (machine.isEmpty) return;
    final prev = _status.value;
    if (prev.machine == machine) return;
    _status.value = HostStatus(
      authed: _authed(),
      up: prev.up,
      machine: machine,
    );
  }

  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _status.dispose();
  }
}
