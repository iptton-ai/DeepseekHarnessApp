// 双下行 WebSocket(DSH-PROTOCOL §2):两条只收不发的 socket。
// - /api/events.mux  全会话聚合流(MuxFrame)
// - /api/events.host 主机级流(HostFrame)
// 客户端在这两条 socket 上不发送任何应用数据;重连=整代重建(见 controller)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:singleman/connection/api_client.dart';
import 'package:singleman/wire/generated/wire_generated.dart';

/// 单条下行连接:打开后只收帧;done 在对端关闭/出错时完成。
class Downlink {
  Downlink._(this.name, this._ws) {
    // 单订阅 controller(非 broadcast):open 与首次 listen 之间到达的帧
    // 进入缓冲而非丢弃。真 host 在 mux open 的瞬间同步推基线重放帧
    // (still-pending 审批/问答 + 队列/任务快照,api-proxy events.mux 处理器
    // 一次推完),而本客户端要等 describe+双 WS 三路握手全成才 adopt 挂
    // 监听 —— broadcast 无监听者会静默丢帧,重连后交互卡丢失即此竞态。
    _frames = StreamController<Map<String, dynamic>>();
    _doneCompleter = Completer<void>();
    _subscription = _ws.listen(
      (data) {
        final dynamic decoded;
        try {
          decoded = jsonDecode(data as String);
        } on FormatException catch (e) {
          _frames.addError(
            CarrierError('non-json frame on ' + name + ': ' + e.message),
          );
          return;
        }
        if (decoded is Map<String, dynamic>) {
          _frames.add(decoded);
        } else {
          _frames.addError(CarrierError('frame on ' + name + ' not an object'));
        }
      },
      onError: (Object e) {
        _failure = e;
        _completeDone();
      },
      onDone: _completeDone,
      cancelOnError: false,
    );
  }

  final String name;
  final WebSocket _ws;
  late final StreamController<Map<String, dynamic>> _frames;
  late final Completer<void> _doneCompleter;
  late final StreamSubscription<dynamic> _subscription;
  Object? _failure;

  /// [customClient] 必须传入直连配置的 HttpClient(createDirectHttpClient):
  /// WebSocket.connect 默认自建 client,同样会被系统代理接管。
  /// [headers] 远程网关形态携带 Authorization(dart:io WS 原生支持自定义头)。
  static Future<Downlink> connect(
    String name,
    Uri uri, {
    HttpClient? customClient,
    Map<String, String> headers = const {},
  }) async {
    final ws = await WebSocket.connect(
      uri.toString(),
      headers: headers,
      customClient: customClient,
    );
    // 协议级保活(2026-08-17):代理对空闲 WS 普遍有超时 —— 自建 nginx 默认
    // proxy_read_timeout 60s;客户端每 20s 发协议 ping 帧,会穿透帧透传型
    // 代理(nginx 等,对端 ws 库自动回 pong,双向字节都刷新读计时),
    // 间隔 20s 给默认 60s 留足余量。直连/loopback 形态无害(ping 不改变
    // 下行语义)。
    // ⚠️ 已知不救 CF 形态(2026-08-17 活体实证):CF 边缘在本地应答客户端
    // ping(auto-pong),ping 帧不穿透 cloudflared 隧道腿,空闲 host 流仍
    // 在 ~126s 被掐(code 1006)—— CF 链的保活只能靠 dsh host 侧发心跳
    // (rc.6 未发)或锚定 rust 网关(见 AGENTS.md 远程链路)。
    ws.pingInterval = const Duration(seconds: 20);
    return Downlink._(name, ws);
  }

  /// 原始帧(server-request 信封 JSON)。
  Stream<Map<String, dynamic>> get rawFrames => _frames.stream;

  /// 对端关闭或出错时完成;先看 [failure]。
  Future<void> get done => _doneCompleter.future;

  /// 非 null 表示因错误断开(而非对端正常关闭)。
  Object? get failure => _failure;

  void _completeDone() {
    _failure ??= _ws.closeCode != null
        ? CarrierError('socket closed with code ' + _ws.closeCode.toString())
        : null;
    if (!_doneCompleter.isCompleted) _doneCompleter.complete();
  }

  /// 主动关闭(整代重建时由 controller 调;幂等)。
  Future<void> close() async {
    await _subscription.cancel();
    try {
      await _ws.close();
    } catch (_) {
      // 对端已断开时 close 可能抛错;忽略。
    }
    _completeDone();
    if (!_frames.isClosed) {
      // 未被 adopt 的 Downlink(握手失败路径):丢弃缓冲帧并释放。
      await _frames.close();
    }
  }
}

/// 把下行原始帧解析成 MuxFrame / HostFrame(两级:信封 → 帧 union)。
/// 信封级畸形(非 server-request、未知 method)按 fail-loud 纪律转发到
/// [onProtocolError],不杀 socket;帧 union 解析失败同样只报不杀。
class DownlinkParser {
  const DownlinkParser();

  /// 解析单帧;返回 null 表示协议级畸形(已通过 [onError] 上报)。
  Map<String, dynamic>? parseEnvelope(
    Map<String, dynamic> raw,
    void Function(Object error) onError,
  ) {
    try {
      final envelope = RpcMessage.fromJson(raw);
      if (envelope is! RpcMessageServerRequest) {
        onError(
          CarrierError(
            'downlink envelope is ' + envelope.runtimeType.toString(),
          ),
        );
        return null;
      }
      final payload = envelope.payload;
      if (payload is! Map<String, dynamic>) {
        onError(CarrierError('downlink payload not an object'));
        return null;
      }
      return payload;
    } on FormatException catch (e) {
      onError(CarrierError('downlink envelope parse: ' + e.message));
      return null;
    } on TypeError catch (e) {
      onError(CarrierError('downlink envelope shape: ' + e.toString()));
      return null;
    }
  }
}
