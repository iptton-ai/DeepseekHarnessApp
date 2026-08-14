// ConnectionController — 整代重建状态机(M1 核心)。
//
// 语义(DSH-PROTOCOL §2):
// - 就绪握手 = 两条 WS 都打开 **且** host.describe HTTP 成功,缺一不可
// - 任一 socket 断 → 当前代际失效 → 重建两条流 + 重新握手(无 since 续传)
// - 重取 history 是上层(M2)的职责;控制器只广播代际翻转
// - mux 会原样重放 pending 的 approval/question 帧(rpcId 逐字复用),
//   控制器无需特殊处理,帧照常流入 muxFrames
//
// 接口冻结自本文件(详见 connection/README.md)。
import 'dart:async';
import 'dart:math';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/connection/downlinks.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

enum ConnectionPhase { connecting, ready, down }

class ConnectionSnapshot {
  const ConnectionSnapshot({
    required this.generation,
    required this.phase,
    this.describe,
    this.failureReason,
  });
  final int generation;
  final ConnectionPhase phase;
  final HostDescribeValue? describe;
  final String? failureReason;
  @override
  String toString() =>
      'ConnectionSnapshot(gen=$generation, $phase${failureReason == null ? '' : ', ' + failureReason!})';
}

class ConnectionController {
  ConnectionController({
    required Uri baseUri,
    Duration initialBackoff = const Duration(milliseconds: 300),
    Duration maxBackoff = const Duration(seconds: 8),
    Duration probeTimeout = const Duration(seconds: 10),
    ApiClient? apiClient,
  })  : _baseUri = baseUri,
        _initialBackoff = initialBackoff,
        _maxBackoff = maxBackoff,
        _probeTimeout = probeTimeout,
        apiClient = apiClient ?? ApiClient(baseUri: baseUri);

  final Uri _baseUri;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final Duration _probeTimeout;
  final ApiClient apiClient;

  final _snapshots = StreamController<ConnectionSnapshot>.broadcast();
  final _muxFrames = StreamController<MuxFrame>.broadcast();
  final _hostFrames = StreamController<HostFrame>.broadcast();
  final _protocolErrors = StreamController<Object>.broadcast();
  final _addressedMux = StreamController<AddressedMuxFrame>.broadcast();

  int _generation = 0;
  int _attempt = 0;
  bool _disposed = false;
  bool _started = false;
  _LiveGeneration? _live;

  /// 代际快照流(connecting → ready → down → connecting ...)。
  Stream<ConnectionSnapshot> get snapshots => _snapshots.stream;

  /// 当前代际的 mux 帧(广播;重连后自动切换到新一代的帧)。
  Stream<MuxFrame> get muxFrames => _muxFrames.stream;

  /// 当前代际的 host 帧。
  Stream<HostFrame> get hostFrames => _hostFrames.stream;

  /// 协议级畸形帧上报(不杀连接)。
  Stream<Object> get protocolErrors => _protocolErrors.stream;

  /// 可应答帧(rpcId 来自信封,payload 为 MuxFrame):审批/问答 UI 的数据源。
  /// 非可应答 mux 帧也会出现(推送帧 rpcId 仍回显,应答它们只会 not-pending)。
  Stream<AddressedMuxFrame> get addressedMuxFrames => _addressedMux.stream;

  ConnectionSnapshot? get current => _current;
  ConnectionSnapshot? _current;

  Uri get _muxUri => _wsUri('/api/events.mux');
  Uri get _hostUri => _wsUri('/api/events.host');
  Uri _wsUri(String path) => _baseUri.replace(scheme: _baseUri.scheme == 'https' ? 'wss' : 'ws', path: path);

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _spawnGeneration();
  }

  Future<void> dispose() async {
    _disposed = true;
    await _live?.teardown('disposed');
    await _snapshots.close();
    await _muxFrames.close();
    await _hostFrames.close();
    await _protocolErrors.close();
    await _addressedMux.close();
    apiClient.dispose();
  }

  void _emit(ConnectionSnapshot snap) {
    _current = snap;
    if (!_snapshots.isClosed) _snapshots.add(snap);
  }

  void _spawnGeneration() async {
    if (_disposed) return;
    _generation += 1;
    final gen = _generation;
    _emit(ConnectionSnapshot(generation: gen, phase: ConnectionPhase.connecting));
    final live = _LiveGeneration(gen, _muxFrames, _hostFrames, _protocolErrors, _addressedMux);
    _live = live;

    final describeFuture = apiClient.call(
      RpcMethods.hostDescribe,
      <String, dynamic>{},
      parse: HostDescribeValue.fromJson,
      timeout: _probeTimeout,
    );

    final muxFuture = Downlink.connect('mux', _muxUri);
    final hostFuture = Downlink.connect('host', _hostUri);

    try {
      final results = await Future.wait(<Future<Object>>[
        describeFuture,
        muxFuture,
        hostFuture,
      ], eagerError: true);
      final describe = results[0] as HostDescribeValue;
      final mux = results[1] as Downlink;
      final host = results[2] as Downlink;
      if (_disposed || _generation != gen) {
        await live.adoptAndTeardown(describe, mux, host, 'superseded');
        return;
      }
      live.adopt(describe, mux, host);
      _attempt = 0;
      _emit(ConnectionSnapshot(
        generation: gen,
        phase: ConnectionPhase.ready,
        describe: describe,
      ));
      live.watchInvalidations((reason) => _invalidate(gen, reason));
    } catch (e) {
      // 握手失败:两条 socket 都可能开了一半,全部拆掉,退避重试。
      await live.teardown('handshake-failed: ' + e.toString());
      _invalidate(gen, 'handshake failed: ' + e.toString());
    }
  }

  void _invalidate(int gen, String reason) {
    if (_disposed || _generation != gen) return;
    _emit(ConnectionSnapshot(
      generation: gen,
      phase: ConnectionPhase.down,
      failureReason: reason,
    ));
    final backoff = _nextBackoff();
    Timer(backoff, _spawnGeneration);
  }

  /// 测试钩子:模拟网络拔线 —— 主动关闭两条下行 socket(不通知服务端),
  /// 触发与真实断网相同的整代重建路径。生产代码不得调用。
  Future<void> debugDropDownlinks() async {
    await _live?._dropSockets();
  }

  Duration _nextBackoff() {
    if (_attempt > 20) _attempt = 20;
    final ms = _initialBackoff.inMilliseconds * pow(2, _attempt).toInt();
    _attempt += 1;
    final capped = min(ms, _maxBackoff.inMilliseconds);
    return Duration(milliseconds: capped);
  }
}

/// 带 rpcId 的 mux 帧(rpcId 在信封层,payload 变体里没有)。
class AddressedMuxFrame {
  const AddressedMuxFrame({required this.rpcId, required this.frame});
  final String rpcId;
  final MuxFrame frame;
}

/// 一次代际的活体资源:两条 socket + 帧订阅。
class _LiveGeneration {
  _LiveGeneration(this.generation, this._muxSink, this._hostSink, this._errors, this._addressedSink);

  final int generation;
  final StreamController<MuxFrame> _muxSink;
  final StreamController<HostFrame> _hostSink;
  final StreamController<Object> _errors;
  final StreamController<AddressedMuxFrame> _addressedSink;
  static const _parser = DownlinkParser();

  Downlink? _mux;
  Downlink? _host;
  final _watchers = <StreamSubscription<void>>[];
  bool _tearingDown = false;

  void adopt(HostDescribeValue describe, Downlink mux, Downlink host) {
    _mux = mux;
    _host = host;
    _watchers.add(mux.rawFrames.listen(_onMuxRaw, onError: _errors.add));
    _watchers.add(mux.done.then((_) => _notify('mux down')).asStream().listen((_) {}));
    _watchers.add(host.rawFrames.listen(_onHostRaw, onError: _errors.add));
    _watchers.add(host.done.then((_) => _notify('host down')).asStream().listen((_) {}));
  }

  void watchInvalidations(void Function(String reason) onInvalid) {
    _onInvalidated = onInvalid;
  }

  void Function(String reason)? _onInvalidated;

  void _notify(String reason) {
    if (_tearingDown) return;
    _onInvalidated?.call(reason);
  }

  void _onMuxRaw(Map<String, dynamic> raw) {
    final rpcId = raw['rpcId'] is String ? raw['rpcId'] as String : '';
    final payload = _parser.parseEnvelope(raw, _errors.add);
    if (payload == null) return;
    try {
      final frame = MuxFrame.fromJson(payload);
      if (!_muxSink.isClosed) _muxSink.add(frame);
      if (!_addressedSink.isClosed) _addressedSink.add(AddressedMuxFrame(rpcId: rpcId, frame: frame));
    } on FormatException catch (e) {
      _errors.add(CarrierError('mux frame parse: ' + e.message));
    } on TypeError catch (e) {
      _errors.add(CarrierError('mux frame shape: ' + e.toString()));
    }
  }

  void _onHostRaw(Map<String, dynamic> raw) {
    final payload = _parser.parseEnvelope(raw, _errors.add);
    if (payload == null) return;
    try {
      if (!_hostSink.isClosed) _hostSink.add(HostFrame.fromJson(payload));
    } on FormatException catch (e) {
      _errors.add(CarrierError('host frame parse: ' + e.message));
    } on TypeError catch (e) {
      _errors.add(CarrierError('host frame shape: ' + e.toString()));
    }
  }

  /// 只关 socket、不动订阅:watchInvalidations 会照常触发代际翻转。
  Future<void> _dropSockets() async {
    final mux = _mux;
    final host = _host;
    _mux = null;
    _host = null;
    await mux?.close();
    await host?.close();
  }

  Future<void> adoptAndTeardown(
    HostDescribeValue describe,
    Downlink mux,
    Downlink host,
    String reason,
  ) async {
    adopt(describe, mux, host);
    await teardown(reason);
  }

  Future<void> teardown(String reason) async {
    if (_tearingDown) return;
    _tearingDown = true;
    for (final w in _watchers) {
      await w.cancel();
    }
    _watchers.clear();
    await _mux?.close();
    await _host?.close();
  }
}
