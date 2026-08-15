# 开发计划与组织纪律

> 前提约束:执行者(人与 LLM agent)都是**有限上下文**的。组织方式的第一性输入不是"人的协作成本",而是"每个工作单元的上下文预算"。任何任务应当只靠一小块自足上下文就能开工、能验证。

## 决策记录(ADR 摘要)

### ADR-0001 契约防火墙:codegen 冻结协议知识
**决策**:M0 第一件事是从 DSH 的 zod schema 建 codegen 管线(JSON Schema → Dart 模型),不手写 wire 层。
**原因**:契约层官方设计为零依赖可导入;50+ 方法、封闭错误码集、帧联合类型手写必漂移。生成物 + conformance 测试之后,任何任务不再需要读 DSH TS 源码。dsh 升级的爆炸半径被锁死在生成代码 + 测试。
**代价**:前期投入;codegen 管线本身要维护(上游是 rc,schema 可能变)。

### ADR-0002 垂直切片,禁止水平分层
**决策**:里程碑按端到端可验证的垂直切片推进(见下),不做"先全部 model 再全部 transport 再全部 UI"。
**原因**:水平分层的中间态无法验证,且每个任务要求全局理解。垂直切片让每个任务自带验证闭环,天然限制上下文半径。

### ADR-0003 知识外置三件套:README / fixture / ADR
**决策**:包级 README(不变式+上下文清单,≤2k token)、真实线上的 fixture 回放测试、决策记录。三者是上下文外置的主要载体,知识只进文件不进对话。
**原因**:会话会重启,对话即失忆。DSSH 仓库本身就是这个纪律的活教材(每包高密度 README + `.agents/notes/` 决策归档)。

### ADR-0004 部署形态路线:桌面先行
**决策**:先做 macOS/Windows 桌面版(loopback 零配置、全功能含配置面),跑通后再做手机 LAN 版(隐藏 loopback 特权面)。公网形态冻结,直到上游出认证层。
**原因**:信任围栏的分级(见 DSH-PROTOCOL.md §6)让桌面版的工程量与风险都最小;手机版只是连接配置 + UI 适配差异。

## 里程碑

### M0 契约与测试床(串行,最高优先)✅ 2026-08-14 完成
- [x] Flutter 工程脚手架(`flutter create`,组织为 wire/connection/sessions/ui 四层目录)
- [x] codegen 管线:从 DSH zod schema 导出 JSON Schema → 生成 Dart 模型(RpcMessage 四象限、RpcMethodMap 全方法、RpcErrorDetailsMap 全错误码、MuxFrame/HostFrame)
  - 管线:`node tool/codegen/export-schemas.mjs && dart run tool/codegen/generate_dart.dart`
  - 产物:`lib/wire/generated/wire_generated.dart` + 16 part(单一 part 库,结构去重还原命名类)
- [x] conformance 测试床:对 `http://127.0.0.1:3080` 真实主机跑 `host.describe` 回环 + 信封解析(3 用例绿;无活体时自动 skip)
- [x] fixture 语料:mux 帧已采样(`fixtures/ws/*.jsonl` + `capture_ws.dart` 工具),回放测试 2 用例绿;审批/问答帧待 M3 前补(需要真实交互触发)
- **验收**:生成的模型能解析活体主机的 describe 响应 ✅;版本钉死 ✅(manifest + 生成器双端断言,不匹配 exit 2)
- **为什么先做**:风险最高、上下文收益最大;之后一切任务的地基

### M1 连接控制器(串行,单负责人)✅ 2026-08-14 完成
- [x] ApiClient:rpcId mint、信封 wrap/unwrap、30s unary 超时、错误折叠(RpcBusinessError/CarrierError/ApiTimeout 三级)
- [x] 双 WS 下行管理:两条只收 socket、就绪握手(describe 成功+双 socket 打开;probeTimeout 独立节奏)
- [x] 整代重建状态机:任一 socket 断 → 同代 down → 新代重建+重握手(指数退避 300ms→8s);重取 history 接口已备(muxFrames/snapshots 广播),M2 消费
- [x] 接口冻结,写包 README(lib/connection/README.md)
- **验收**:拔线/杀主机/超时三类故障注入下状态机收敛 ✅(test/connection 11 绿,假主机 test/helpers/fake_dsh_host.dart)

### M2 最小聊天环(可演示)✅ 2026-08-14 完成
- [x] `workspace.list` + `session.create/list` + `session.prompt` + `session.history`(含 projections 尾页)
- [x] 纯文本渲染会话流(session/event 增量;markdown 归 M4)
- [x] 最小 UI:会话侧栏 + 消息气泡 + 输入框 + 连接状态徽章
- **验收** ✅:`bin/live_chat_smoke.dart` 对活体 3080 真实对话(ASSISTANT: SMOKE OK FROM DSH)+ 拔线重连(gen 1→2,101 事件不丢)+ macOS debug 构建通过;`flutter test` 24/24 绿

### M3 交互帧 ✅ 2026-08-14 完成
- [x] `approval/requested` → `POST /api/respond` 审批卡(允许一次/拒绝;client-response 信封 rpcId 回显信封层)
- [x] `question/requested` 结构化问答表单(本地预校验:漏答/未知 label/单选互斥/重复 id;服务端权威)
- [x] `session/queue` 队列 Dock + `session.updateQueue` 删除(splice+queue-item-not-found 折叠)+ `session.cancel`
- **验收** ✅:假主机 fault 注入 7 用例 + 活体 queue fixture 回放 1 用例全绿;32/32

### M4+ 并行功能面 ✅ 2026-08-14 完成
- [x] 图片附件上传(含限额本地预拒:四限+媒体类型枚举+纯头部尺寸探测)
- [x] 模型选择器(`session.models/selectModel`,reasoningEffort+routable 警示)
- [x] 会话 fork/导出(ZIP 流式下载)
- [x] session.search(域方法+侧栏过滤)
- [x] goal 面板(六方法域层 + GoalPanel UI)
- [x] skill 菜单(`/name` 即普通 prompt,SkillCatalog+底部弹层)
- [x] 手机 LAN 形态(连接配置页 + PrivilegeScope 按 loopback 隐藏特权面;真机验证待做)
- workspace 管理:暂缓(桌面会话列表已覆盖主场景,按需再开)

## M5 web profile 全功能复刻(2026-08-15 起)

> 输入:四份并行审计(docs/audit/{conversation,settings-system,orchestration,sidebar-layout}.md),
> 对照 M0–M4 已有面得出差距。验收口径:单测/widget 测试 + 活体冒烟 + 移动可用性(<1024 抽屉/底部 sheet/44dp 触控)。

### 差距分析(按域)

| 域 | web profile 有 | 本项目现状 | 差距 |
|---|---|---|---|
| 会话流保真 | think 折叠行/工具卡(ToolEventView)/todo 计划 dock/压缩检查点/重试行/分支/统计行 | 纯文本气泡(event_text) | **大** |
| composer | steer 插话/权限 chip/ContextMeter/模型座/加号命令入口/busyEnter | 队列模式发送+取消 | **大** |
| workspace | 分组侧栏/增删改排序/归档/目录选择(native+browse)/搜索防抖 | session.list 扁平列表+简单过滤 | **大** |
| subagent | 目录树/token 用量/只读 transcript/续聊/中断 | 无 | **大** |
| jobs | session/jobs 弹层+角标+耗时表 | 无 | 中 |
| settings/credentials/llm | 提供方管理/密钥/发现模型/插件配置/revision CAS | 无(PROGRESS 下一步 #1) | **大**(loopback 门控) |
| 命令体系 | / 菜单(fuzzy)/风险确认/三派发 | skill 底部弹层(等价最小面) | 中 |
| 轨迹视图 | 三列 ledger+时间条+检查器 | 无 | 中(可后置) |
| 消息反馈 | like/dislike+备注(CAS) | 无 | 小(需核 RPC 可达性) |
| 产出文件 | 轮尾文件行+行内提及链接 | 无 | 小(可后置) |
| 主题 | light/dark/system + ui-theme.preference | 跟随系统 | 小 |

### 波次结果(2026-08-15 收官)

- **W1 ✅**(五切片):workspace 分组/jobs/subagent/settings·credentials·llm/会话流节点渲染;集成 = 四 store 接线 + ChatNodeList + <600dp 抽屉;122/122
- **W2 ✅**(四切片):composer 升级(queue|steer/停止/按钮化)/目录 browse 单列下钻/图片渲染(LRU+灯箱)/命令菜单(commands|list 双层信封+预校验);集成 = UpgradeComposer 换装 + steerSender 链 + 页头命令按钮 + 添加工作区;203/203
- **W3 ✅**(三切片):轨迹视图/产出文件+消息反馈(CAS)/主题(ui-theme)+onboarding;集成 = 轨迹入口/反馈行/_ThemeWrapper/首启引导;277/277 + 双活体冒烟
- 测试累计 47→277;子代理累计 16 个(4 审计 + 5 W1 + 4 W2 + 3 W3);每片自建假主机+独立测试,集成轮主会话统一验收;**macOS release 43.9MB 构建通过**
- 遗留(非阻塞,按需再开):image_picker 平台选图(pubspec 未加;附件发送 UI 暂缺入口,域层 promptWithImages 已备)、命令菜单输入框内联过滤(commandMenu slot 未注入,现为页头按钮)、真机 LAN 验证(需 --trusted-host 环境)

### 波次(每波并行切片,互不读对方代码;集成由主会话单独提交)

- **W1(进行中)**:A workspace 分组域 | B jobs 域 | C subagent 域 | D settings/credentials/llm 域 | E 会话流节点渲染域(纯新增 event_nodes+node_widgets,不改既有文件)
- **W2**:composer 升级(steer/权限 chip/ContextMeter/模型座重排) + 目录 browse 对话框 + 图片消息渲染(画廊/灯箱) + / 命令菜单统一(skill+命令+plan chip) + 集成波
- **W3**:轨迹视图 + 产出文件行 + 消息反馈(先核 messageFeedback RPC 对 /api 是否可达) + 主题设置 + onboarding + 活体冒烟扩展 + release 构建
- 移动可用性横切要求:所有新列表行 ≥44dp;弹层默认底部 sheet(宽屏才用居中 modal);hover 交互→常显按钮或长按;宽内容(diff/终端/轨迹)横向滚动+全屏查看两级降级;搜索/目录选择全屏化;settings/credentials/host.* 特权面按 PrivilegeScope(loopback)门控。

### W1 集成规格(2026-08-15 冻结,待切片全绿后执行)

接线点(全部在既有文件,改动集中在 main.dart + chat_screen.dart):
1. **main.dart**:构造 WorkspaceStore/JobStore/SubagentStore/SettingsStore(共用 api+connection),传给 ChatScreen 新参数;SettingsEntryButton 注入侧栏底部(PrivilegeScope 门控已在组件内)。
2. **chat_screen.dart**:
   - _Sidebar 顶部加 WorkspaceBrowser(注入 store+回调:选中会话/新建(带 workspaceId)/重命名/fork/归档);原扁平 session 列表保留为「全部会话」段(过渡期并存)。
   - _MessagePane 页头(AppBar 位)加 SubagentEntryButton + JobsTrigger(均无内容不渲染,自带此语义)。
   - _MessagePane 消息流切换:ChatNodeList(event_nodes+node_widgets)替换 event_text 气泡;ChatViewModel 增加 nodes 计算(或由 main 层用 store.logFor(id).eventStream 直接驱动,见 3)。
   - view 映射:main 层订阅 connection.muxFrames 收集 Map<sessionId, Map<seq, ToolEventView>>,连同 events 一起喂 ChatNode 提取器。
3. **ChatViewModel**:加 selectedLog 流已存在(logFor);新增 nodesView 流 = eventStream × viewMap → List<ChatNode>(combineLatest 语义)。为控改动量,也可在 _MessagePane 内 StatefulWidget 自订阅(集成时择一,优先 VM 层,便于测试)。
4. **移动布局**:<600dp 时 Scaffold 改 ScaffoldMessenger+Drawer:侧栏整体进 Drawer(WorkspaceBrowser+会话列表);桌面 ≥600dp 保持 Row。判定用 LayoutBuilder。Jobs/subagent 弹层组件已是底部 sheet,无需改。
5. **验收**:flutter test 全绿(旧 47 + 新 ~45);widget 测试补 1 个「窄屏打开抽屉可见 workspace 分组」;活体:dart run bin/live_features_smoke.dart 仍绿(回归);bin/ 扩展见 W3。

### 新增任务模板附加项(移动验收)

6. **移动可用性验收**:切片 UI 必须附窄屏(360dp)widget 测试或说明为何域层无 UI。

## M6 移动端公网鉴权接入(2026-08-15)

### ADR-0006 公网形态:前置鉴权网关 + SSH 反向隧道(非 dsh 插件)

**决策**:不在 dsh 进程内做鉴权(dsh-host-webserver 明示「无 TLS/auth,交给前置反向代理」;
/api 路由由 client-connection 插件独占,进程内无插队点),改为在自持服务器部署
**dsh-gateway**(Rust/Axum,rusqlite,~5MB 常驻;服务端资料在本地 `server/`,不入库):

```
手机 singleman ─https→ nginx(网关域名, TLS) → dsh-gateway:8102(鉴权+中转)
                                              │ SSH 反向隧道(launchd 常驻)
                                              ▼
                                    Mac dsh web(127.0.0.1:3080,零改动)
```

- **鉴权**:密码登录(argon2,每 IP 5 分钟 8 次限速)→ 30 天设备令牌(HS256 JWT,
  SQLite 登记 jti,可吊销);所有中转请求(HTTP + WS upgrade)强制 `Authorization: Bearer`
- **过围栏**:隧道出口 TCP 即 loopback;网关转发时改写 Host 为 `127.0.0.1:3080`
  → dsh 信任围栏按「桌面同机」放行,特权方法(settings/credentials)对持令牌设备开放,
  鉴权边界收敛于网关一处
- **服务器负载**(用户关切"是否只首次连接"):**不是** —— 全部客户端↔dsh 流量持续经
  服务器中转,但它是纯字节管道(聊天 JSON/图片,KB~MB 级;LLM 供应商流量
  dsh↔provider 不经服务器)。2026-08-15 活体复测修正初测数字(4.9MB/9ms 系
  刚重启未登录的新进程瞬时读数):稳态常驻 ~46MB RSS(argon2 首登 memory-hard
  校验 + glibc 滞留,VmHWM=稳态无增长)、全路径 CPU ~13ms/MB(sshd 隧道 ~9 +
  gateway ~2.5 + nginx ~3.5,每毫秒换 ~77KB 中转)、单流 ~14Mbps/聚合 ~28Mbps
  (带宽是真实上限而非 CPU/内存)→ 2C2G 仍绰绰有余,结论不变、数字修正。
  P2P 打洞(仅首连用服务器)需 WebRTC 级穿透栈(in-app 只剩 DataChannel 或仍在
  IETF draft 的 QUIC 打洞;蜂窝 CGNAT 下仍需 TURN 兜底 = 服务器回到数据路径),
  复杂度不成立
- **客户端**:凭证存 `~/.singleman/credentials.json`(app 沙箱内;密码永不落盘);
  启动按凭证决策(loopback 直连 / 远程静默连 / 远程首登);401 → 停退避重试、拉起
  重登页,令牌原地刷新后 resume;PrivilegeScope 增 `authenticatedRemote`(远程鉴权
  形态特权面可见)
- **部署 6 处**(服务端仓库):workspace/build 脚本/.cnb.yml/nginx(子域+WS
  upgrade+流式透传)/systemd/CLAUDE.md;密钥在服务器 env 文件(不入 git)

**验收**:gateway 6 集成测试全绿(登录/401/吊销/Host 改写/WS echo/限速);客户端
+23 测(401 停链/头注入/登录页/凭证/计划决策)全量 303 绿;活体 AUTH-SMOKE-PASS
(真实登录 + 经网关真实 LLM 轮);服务器实测:healthz/login/describe/WS upgrade/401
拒止全链路通过。DNS A 记录(网关域名 → 服务器 IP)由部署者自行添加(真实值见本地 `server/LOCAL.md`,不入库)。

### ADR-0007 配对鉴权取代手输密码(双向亮码防抢注,2026-08-15)

**动机**:手输网关密码是唯一鉴权渠道时,①每个新设备都要人肉传密码(泄漏面大、不可单点吊销);
②朴素单向配对存在「抢注」窗口 —— 攻击者抄下手机亮码抢注 pending,Mac 端按码 approve 就可能把
令牌发给攻击者(或把手机配到假 dsh)。用户点名要求**双向亮码 + 手机端人工比对**。

**协议**(网关 dsh-gateway M6.1,与密码登录并存、密码可禁用):

```
手机(公开面 /pair/*)                    网关                        Mac(管理面,仅服务器本机/ssh 可达)
 ①本地生成 显示码D(10位≈50bit)+秘密S(43位,永不显示)
   POST /pair/start {D,S,device} ─────▶ pending(D 存活唯一;已用码 30min 内亦不可复用)
   大字显示 D
 轮询 /pair/poll {pairing_id,S} ◀────── offers 列表 ◀────────────── ②pair.sh <D>:本地生成主机码H(6位),
                                                                      **终端大字显示 H**,claim {D,H,端口}
 ③列出全部 offers(多条=多台 Mac 或异常):
   人工比对 Mac 终端上的 H,点选匹配项
   POST /pair/confirm {id,S,claim,H} ─▶ H 校验 + claim 单次消费
                                        → 30 天令牌(绑定该 claim 的隧道端口)
 ◀── {token} ── 进主界面(与密码登录令牌同构)                          ④pair.sh 轮询到完成,回显设备名;
                                                                        不是自己的手机 → 一键 revoke(命令已打印)
```

**防抢注三层**:①D 唯一性 —— 后到同码 409(抄码者抢注会被真手机 409 顶掉;客户端 409 自动换码),
抄码失去意义;②claim 不自动成交 —— 手机端必须人工比对 **Mac 终端显示的** 主机码(假 dsh 的码
对不上,直接暴露);主机码由 Mac 本地生成并显示,不是服务器生成。③完成后 Mac 侧回显设备名,
异常即撤销。claim 走仅绑 127.0.0.1 的管理口(公网不可达),「能 claim」=「有服务器 ssh 权限」,
信任根与隧道一致。

**多机路由一并解决**:令牌记录绑定的隧道端口(13100–13199 白名单,claim 声明),中转按令牌
路由上游 —— 多用户 = 每人一条隧道 + 一次配对,不需要 users 表/用户名。密码登录令牌回落配置
默认上游(向后兼容);`DSH_GATEWAY_PASSWORD_HASH` 留空即禁用密码登录(仅配对)。

**客户端**:PairingPage 为主鉴权入口(输网关地址 → 亮码等待 → offers 卡片人工比对点选 → 完成);
轮询失败静默重试、过期/已用自动回到首页;密码登录降级为页内兜底入口。测试:网关 13 例(全流程/
抢注 409/错码拒/单次消费/端口白名单/密码禁用/多上游路由)+ 客户端 9 例(客户端全流程/换码/
假件 UI 四态);活体 PAIR-SMOKE-PASS(本地网关全链路含真 dsh 中转)。

### 遗留(按需)
- 移动端令牌存储升级 flutter_secure_storage(现为沙箱内明文 JSON,可吊销兜底;
  OHOS fork 插件可用性未验证,故未引)
- Android HOME 环境变量缺失时依赖 path_provider(已引,插件缺失时兜底当前目录)
- 登录页暂无「设备管理/退出登录」入口(服务端 /auth/devices /auth/revoke 已可用)

## 任务模板(五件套)

任何任务(给人或 agent)必须包含:
1. **目标**:一句话
2. **接口契约**:只允许依赖冻结的接口(M1 后 connection 接口、M0 后生成模型)
3. **fixture**:验收所用的数据(无 fixture 的任务先补 fixture)
4. **验收测试**:可执行
5. **禁区**:不许碰的目录(默认禁区:connection/ 生成代码)

## 纪律

- PR ≤ 400 行;描述自带上下文摘要,reviewer 不需要翻全仓库
- M0/M1 严格串行(地基);M4 全并行(互不读对方代码)
- 调查类工作(如"question 校验语义")是独立任务,产出进文档,不混入编码任务
- dsh 升级 = 独立提交,只动生成代码 + conformance 测试
- 每次会话结束前更新 `PROGRESS.md`
