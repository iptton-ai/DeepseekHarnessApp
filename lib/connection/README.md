# connection/ — 连接控制器(M1,接口已冻结)

## 不变式
- 就绪握手 = 两条 WS 都打开 **且** host.describe 成功(DSH-PROTOCOL §2),缺一不可
- 任一 socket 断 → 当前代际失效 → 重建两条流 + 重新握手(**无 since 续传**,重取 history 是上层职责)
- mux 重连时原样重放 pending approval/question 帧(rpcId 逐字复用),控制器无特殊处理
- rpcId 只由发起方 mint(UUIDv4);响应不回显 = 载波错误
- 每个 POST 必须 Content-Type: application/json(否则 415)
- 两级解析:RpcMessage 信封 → 业务 value(调用方 parse);畸形帧只上报不杀 socket

## 冻结接口(v1)

### ApiClient(上行)
```dart
ApiClient({required Uri baseUri, Duration defaultTimeout = 30s})
Future<T> call<T>(String method, Map<String,dynamic> payload,
  {required T Function(Map<String,dynamic>) parse, Duration? timeout})
```
异常折叠(全部 unchecked,永不泄漏原始 SocketException/FormatException):
- `RpcBusinessError` — ok:false 分支,内含生成的 RpcError sealed(41 错误码)
- `CarrierError` — HTTP 非 200 / 信封畸形 / rpcId 不回显 / 连接拒绝
- `ApiTimeout` — unary 超时(默认 30s;host.pickDirectory 等用户节奏方法调用方放宽)

### ConnectionController(状态机)
```dart
ConnectionController({required Uri baseUri,
  Duration initialBackoff = 300ms, Duration maxBackoff = 8s,
  Duration probeTimeout = 10s})
void start() / Future<void> dispose()
Stream<ConnectionSnapshot> snapshots   // 代际快照(connecting→ready→down→…)
Stream<MuxFrame> muxFrames             // 当前代际帧(广播,重连自动切换)
Stream<HostFrame> hostFrames
Stream<Object> protocolErrors          // 协议级畸形(不杀连接)
ConnectionSnapshot? get current
```
`ConnectionSnapshot{generation, phase, describe?, failureReason?}` — M2 在
ready(尤其代际翻转)时重取 session.list + history。

## 故障注入测试(test/connection/)—— M1 验收
- 拔线:unplug mux → 同代 down → 新代 ready(gen 递增)✅
- 杀主机:server 停 → down;同端口复活 → 退避重试后 ready ✅
- 超时:describe 挂起 → probeTimeout 判定握手失败 → 重试恢复 ✅
- ApiClient:业务错误/rpcId 不回显/挂起/主机不可达 四路折叠 ✅

## 已知妥协
- macOS 上 Dart HttpClient 对连接拒绝有内部重试:refused 可能以 ApiTimeout 形态浮出(测试按「折叠纪律」断言两种之一)
- 帧解析失败不杀 socket(协议纪律 fail-loud 体现在 conformance 测试;控制器保守存活)
- 单 HttpClient 实例跨代际复用(连接池共享);dispose 由 controller 拥有

## 上下文清单
- 改本包前读:DSH-PROTOCOL §1/§2/§5、wire/generated(信封/帧 union)
- 测试假主机:test/helpers/fake_dsh_host.dart(可编程故障)
