// StreamRebuildThrottle — 节点流重建节流器(主聊天 ChatViewModel 与子代理
// transcript 页共用的同一渲染节拍;「子代理消息渲染与主列表一致」的落点)。
// 纯 Dart(仅 dart:async),无 Flutter 依赖,widget/纯 Dart 测试均可直测。
//
// 策略(与主 agent 消息列表历来实测复核过的决策完全一致,勿移除/放宽):
// ① microtask 合并 —— 同一事件循环排空内多次日志变更只重算一次
//   (extractNodes 是 O(n);逐帧重算会卡流式渲染)。
// ② 时间窗节流 —— 流式 delta 是逐帧到达的**独立事件循环轮次**,
//   microtask 合并不了跨轮变更:每个 delta 仍会各自触发一次 O(n) 重算 +
//   整屏 rebuild,think/文本高频流(几十~上百 delta/s)会饱和 UI 线程、
//   饿死输入事件(microtask 本身不产生让出点)。
// ③ 分档 —— 事件**类型**决定时效要求:
//   - 纯 assistant/chunk 追加(只是尾部长文本变长):慢档
//     [interval](250ms 一次;打字/尾随滚动的跳进感可接受,
//     换来滚动稳定流畅 —— 全量重算 + 流式文本重布局不再是每秒 15 次);
//   - 其他任何新事件(新节点/工具卡/轮次定界/历史页):立即落地,
//     结构变化一帧不等待。
// 慢档内:空闲后首个 delta 立即(leading,体感即时),窗口内后续变更
// 推迟到尾沿 Timer 统一落地(trailing,流结束的最终帧必达)。
import 'dart:async';

/// 节流落地回调:[token] = schedule 时透传的上下文(如所属日志),
/// 由调用方自行校验新鲜度(会话已切换/页面已销毁 → 丢弃本次落地)。
typedef StreamRebuildFlush = void Function(Object? token);

/// 慢档时间窗(流式渲染节流 250ms 是复核过的决策:勿移除、勿放宽)。
const Duration kStreamRebuildInterval = Duration(milliseconds: 250);

class StreamRebuildThrottle {
  StreamRebuildThrottle({required this.onFlush, this.interval = kStreamRebuildInterval});

  final StreamRebuildFlush onFlush;
  final Duration interval;

  bool _queued = false;
  bool _slow = false;
  Timer? _timer;
  DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);
  Object? _token;
  bool _disposed = false;

  /// 排一次重建。[token] 随首个入队批次透传给 [onFlush](合并批次内
  /// 后到者只允许把慢档升级为快档,不换 token —— 与主列表既有语义一致)。
  void schedule(Object? token, {required bool slow}) {
    if (_disposed) return;
    if (_queued) {
      // 已排队的合并批次若含快档请求,保持快档(不能被后到的慢档降级)。
      if (!slow) _slow = false;
      return;
    }
    _queued = true;
    _slow = slow;
    _token = token;
    scheduleMicrotask(() {
      _queued = false;
      if (_disposed) return;
      final sinceLast = DateTime.now().difference(_lastFlush);
      if (!_slow || sinceLast >= interval) {
        _flush();
      } else {
        // 慢档窗口内:推迟到尾沿;delta 持续涌入时每窗口至多一次重算。
        _timer ??= Timer(interval - sinceLast, () {
          _timer = null;
          if (_disposed) return;
          _flush();
        });
      }
    });
  }

  void _flush() {
    _lastFlush = DateTime.now();
    onFlush(_token);
  }

  /// 丢弃挂起状态(排队批次 + 尾沿定时器);不推进 _lastFlush。
  /// 切换数据源(会话/子代理)时先 reset 再喂新流。
  void reset() {
    _timer?.cancel();
    _timer = null;
    _queued = false;
    _slow = false;
  }

  void dispose() {
    reset();
    _disposed = true;
  }
}
