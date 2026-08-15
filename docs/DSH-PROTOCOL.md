# DSH Wire 协议 — 冻结的调查结论

> 调查日期:2026-08-14,基于 dsh `0.1.0-rc.6` 本机安装。
> 本文件的存在意义:让任何会话**无需重新阅读 DSH 源码**即可做协议层开发。
> 每节末尾给出源码验证路径;只有结论可疑时才需要去读源码。

## 1. 消息模型:四象限 RPC

DSH 的 `/api` 契约层(`@deepseek-ai/dsh-host-apiproxy`)定义了与物理通道解耦的四种消息:

| 消息 | 方向 | 载体 | 说明 |
|---|---|---|---|
| `ClientRequest` | 客户端→主机 | `POST /api/<method>` 的 body | `{type:'client-request', rpcId, method, payload}` |
| `ServerResponse` | 主机→客户端 | 该 POST 的响应 body | `{type:'server-response', rpcId, result}`,rpcId 回显请求 |
| `ServerRequest` | 主机→客户端 | 下行 WebSocket 文本帧 | 可应答(approval/question,复用稳定 rpcId)或纯推送 |
| `ClientResponse` | 客户端→主机 | `POST /api/respond` 的 body | 应答可应答帧,rpcId 回显 |

不变式:
- **rpcId 只由发起方 mint**(UUID),响应永远回显、永不新造
- 每个 POST `/api/*` **必须**声明 `Content-Type: application/json`,否则 415(防 CORS 简单请求盲执行副作用方法)
- 业务错误走 `RpcResult` 的 error 分支(`{ok:false, error:{code, message, details}}`),HTTP 状态只表达载波
- 错误码是**封闭集合**(`RpcErrorDetailsMap` 的键,约 40 个),未知方法在信封解析处 fail-loud
- 可应答帧的重放:重连时 mux 流会原样重放 pending 的 approval/question 帧(rpcId 逐字复用)

验证:`node_modules/@deepseek-ai/dsh-host-apiproxy/lib/types/api/rpc.d.ts`、`rpc-map.d.ts`

## 2. 传输通道

- 上行:`HTTP POST /api/<method>`(unary 与 respond 共用)
- 下行:**两条只下不上的 WebSocket**:`/api/events.mux`(全会话聚合流)和 `/api/events.host`(主机级:会话创建/销毁、运行状态翻转)。客户端在这两条 socket 上**不发送任何应用数据**
- 普通 GET 打这两个路径返回 426,无 SSE fallback(浏览器载波专用 SSE codec 只服务于 in-process 载波)
- 就绪握手:两条 socket 都打开 **且** `host.describe` HTTP 调用成功,缺一不可
- 重连语义:任一 socket 断开 → 当前连接代际失效 → **重建两条流** + 重新握手;mux 的 `since` 续传 hook **v1 未实现**,重连=重开流+重取 `session.history`
- unary 默认 30 秒超时;`host.pickDirectory` 等用户节奏方法豁免

验证:`@deepseek-ai/dsh-client-connection/README.md`(载波与下行边界两节)

## 3. 方法清单(50+,按域分组)

- **session**:`list` `search` `create` `history` `models` `selectModel` `rename` `fork` `prompt` `attachment` `updateQueue` `cancel`
- **subagent**:`list` `history` `prompt` `interrupt`
- **host**:`describe` `pickDirectory` `listDirectory` `createDirectory` `openPath`
- **workspace**:`list` `create` `rename` `delete` `insertBefore` `insertSessionBefore` `archiveSession`
- **skill / agentPreset**:`skill.list`;`agentPreset.list select read copy openDocument remove`
- **goal**:`create` `edit` `pause` `resume` `complete` `clear`
- **settings / credentials / llm**(配置面):`settings.describe openDocument update replace mutate`;`credentials.describe set unset`;`llm.providers models discoverModels`
- 非RPC 下载面:`GET /api/session.export?sessionId=…&includeDescendants=true` 流式 ZIP(逐会话原始日志 + `media/` 图片)

验证:`dsh-host-apiproxy/lib/types/api/rpc-map.d.ts`(权威方法表)

## 4. 下行帧(MuxFrame / HostFrame)

MuxFrame 联合类型:
- `session/event` — 原始会话事件透传,可选携带 `view`(主机算好的工具调用/结果渲染意图,不落盘,同事件不同时刻可不同)
- `session/subscribed {sessionId, lastSeq}` — 订阅控制帧(流打开时每个 attached 会话一帧)
- `approval/requested` / `approval/resolved` — 审批请求与结果(可应答)
- `question/requested` / `question/resolved` — 结构化问答(可应答;questions 为 `AskUserQuestionItem[]`:id/question/detail/header/options/multiSelect/intent)
- `session/queue` — 待处理收件箱的**完整快照**(每次入队/变更后整帧推送,收敛语义)
- `session/jobs` — 后台任务完整快照(同上,整帧收敛)
- `session/projection` — 通用投影单元变更帧 `{sessionId, key, value, seq}`,高 seq 覆盖低 seq;title 走此通道

HostFrame:会话创建/销毁(`host/session-added`)、运行状态(`host/session-status`)、workspace 变更、归档集变更等。

验证:`dsh-host-apiproxy/lib/types/api/events.d.ts`

## 5. 关键方法语义(易错点)

- **session.prompt**:payload 含文本块 + 可选 base64 图片附件(主机把字节提升为持久引用);可选 `clientTimeZone`(仅接受 `UTC` 或 IANA Area/Location,非法→`invalid-time-zone`);rpcId 会进入 `user/message` 事件。内容恰好是单个 `/` 开头文本块 = 斜杠命令
- **session.history**:分页(`maxMessages` 只计 append 进入的 user/assistant 消息);尾页(beforeSeq 缺席)额外携带 `projections` 块 = 所有投影单元的水位快照(`asOfSeq`,空日志为 -1)
- **question 应答校验极严**(服务端验后才认):label 必须精确匹配请求里的;multiSelect 可同时给 selected+custom;单选二选一;重复/未知 label、id 不匹配、批次不完整、空 custom 都 → `bad-response`。第一个到达的应答占有请求
- **session.updateQueue**:按 `MessageId` 寻址;编辑/删除走 `Inbox.splice()`;被 claim 的删除 splice 赢得竞态,后来者 `queue-item-not-found`。队列操作不会唤醒冷会话
- **session.cancel**:只中止当前 turn,保留 pending inbox;取消到静止后 AgentLoop 自动 FIFO 认领下一条,客户端**永不重发或提升**排队消息
- **session.models / selectModel**:选择可与目录成员无关;`routable` 表示适配器当前是否服务该 provider;prompt 前发现不可路由 → `model-unavailable`
- **session.fork**:锚点映射到其后第一个 `turn/end`;turn 未闭合 → `fork-unavailable`

## 6. 信任围栏(部署形态的决定因素)

`/api` 的每个请求(含 WS upgrade)在 RPC 分发前过围栏(`src/api-request-trust.ts`):

- **Loopback 直接过** — 桌面客户端连 `127.0.0.1` 零配置,全方法可用
- **LAN**:需 `dsh web --host <本机IP>` + `--trusted-host <authority>`;`--host 0.0.0.0` 被故意拒绝(直接报错退出)。全接口绑定时,web-app 会自动把本机 IPv4 LAN 字面地址加入信任表
- **特权方法钉死 loopback**(LAN 客户端调了→403):`host.pickDirectory` `host.openPath`、整个 `settings.*`(含 describe 读)、整个 `credentials.*`、`agentPreset.read/copy/openDocument/remove`。核心聊天/审批/会话面**不受限**
- 围栏是**可达性策略,不是认证**——没有身份验证层。DSH 带 bash 工具 = 任何可达者可 RCE。公网暴露 🔴 绝对禁止,直到上游加认证
- **M6 补充:公网形态经 dsh-gateway 前置鉴权解锁**(ADR-0006):服务器网关校验设备令牌后经 SSH 反向隧道转发并把 Host 改写为 `127.0.0.1:3080` → dsh 视为桌面同机客户端(loopback 直接过 + 特权方法放行),鉴权边界收敛于网关。客户端 `PrivilegeScope.authenticatedRemote` 与此对齐
- Host 头是 DNS-rebinding 防线:必须为 loopback authority 或匹配 trustedHosts(WHATWG 归一化比较);带 `Origin` 时必须等于 Host authority;显式 `sec-fetch-site: cross-site` 拒绝
- **无协议版本字段**(客户端与主机同发同布,版本协商是上游 reserved 项;我们作为首个独立客户端应在握手层预留)

验证:`@deepseek-ai/dsh-client-connection/README.md`、`dsh-web-app/lib/index.js`(`resolveLanTrust`)、`dsh-web-app/lib/startup.js`(0.0.0.0 拒绝)

## 7. Flutter 侧实现要点(M0 已验证标记 ✅)

- ✅ **codegen 路径已验证(2026-08-14)**:`@deepseek-ai/dsh-host-apiproxy/lib/types/api/*.schema.js` 是**运行时 zod schema**(非仅类型),可用绝对路径直接 ESM import;`z.toJSONSchema`(zod 4.4.3,`io:'output'` + `unrepresentable:'any'` + `reused:'inline'`)产出干净 draft-2020-12。注意 reused:inline 意味着**产物零 $ref**,全部复用被展开 —— 生成器靠结构去重还原命名类。工具:`tool/codegen/export-schemas.mjs`

- 依赖只需 `http`(或 dio)+ `web_socket_channel`;帧为 UTF-8 JSON 文本
- `host.describe` 是就绪探针 + 能力面(canOpenPath 等原生能力布尔)
- 图片附件上行:base64 进 prompt payload;限额(`imageLimits`)以 per-boot 常量投影下发,客户端应在 intake 前本地拒绝超限
- 会话标题等投影:先信任 `session.rename` 响应回带的规范化值 + seq 落本地格,再等推送帧覆盖(可能乱序到达)
- 错误处理按 `RpcErrorDetailsMap` 建全量 code→Dart sealed class;`internal` 是兜底
- 请求体上限默认 160 MiB(为 100 MiB 聚合图片限额的 base64 膨胀留余量)

## 9. 远程端点(typert gateway,2026-08-15 活体探针验证)

除核心 52 方法(点号命名)外,/api 上还挂着 typert gateway 认领的**远程端点(斜杠命名)**,
信封同 ClientRequest,但 payload 必须为 {args: {...}}(恰好一个 args 字段;字段须匹配严格描述符,
错误消息会点名缺失字段,如 missing "agentId")。本部署(rc.6)实测可达:

- pluginInventory/list(空 args 即可 → 插件清单 entries:entryId/moduleName/enabled/fiberPhase)
- commands/list(需 agentId)、commands/execute
- messageFeedback/list(需 request 对象)、messageFeedback/put(及推测 /delete)
- goals/create|edit|pause|resume|clear(CAS ref 版;与核心 goal.* 点号方法并存,均可走)

实测**不可达**(not found):theme/*、workspaces/*、permissions/*、command.list(注意:
audit 里的 command.list 是猜错的名字,正确为 commands/list)。

转发事件(Host 帧 host/remote-event 的 event 字符串,词汇来自 API_REMOTE_FORWARDED_EVENTS,
归属包 dsh-agent-presets/dsh-commands/dsh-credentials/dsh-llm/dsh-settings):至少含
settings/document-updated、credentials/updated、llm/adapters-updated、commands/change、
agent-preset/selected;重连不重放,消费端自行重拉。

验证:curl 探针 + @deepseek-ai/dsh-api-remotes/README.zh.md(挂载面)、dsh-api-gateway(args 约定)。

补充实测(rc.6 活体):
- **远程端点响应的信封层数按端点而异**(2026-08-15 复核修正,此前「一律双层」的结论过泛):commands/list 的 result.value 是**裸数组**;pluginInventory/list 的 result.value 是**普通 Map**(entries 键);仅返回 TS RemoteResult 的端点(messageFeedback、goals)才多一层内层 {ok, value/error} 信封。解析策略:先看 value 形状,Map 且含 ok 键才剥内层
- commands/list {agentId}(agentId=根会话 id;subagent 会话 → agent-busy "use subagent delivery")返回**裸数组**: [{name, description, input?:{hint}}…];本部署 6 条:compact/export/feedback/goal/permission/plan
- commands/execute {agentId, line} 成功返回 void(外层 ok:true 无 value);未知命令实测被静默吞(ok:true)——W2 复刻命令菜单时客户端必须自己在目录内校验,不得指望服务端拒绝
- messageFeedback/list {request:{sessionId}} → 内层 {items:[]}(空目录形态)
- host.describe 键:version/cwd/provider/model/attachedSessions/canOpenPath(与生成模型一致)

messageFeedback 契约(源自 dsh-message-feedback/lib/types/types.d.ts + typert.remote-client.d.ts,探针验证信封):
- rating 枚举:**'positive' | 'negative'**(非 like/dislike)
- put {request:{sessionId, messageId, rating, note?, ifVersion}}(ifVersion=null 表示要求当前不存在;CAS token 来自上次 list)
- delete {request:{sessionId, messageId, ifVersion}}(幂等,返回 {absent:true};条目已缺席时 ifVersion 被忽略)
- list {request:{sessionId}} → items[{messageId, rating, note?, version(不透明 CAS token), createdAt, updatedAt}]
- item 的 version 每次 material create/update 都会轮换;错误含 session-not-found
- 注意:此前探针 rating:'like' 失败的根因即枚举不匹配

其余远程端点精确签名(各包 typert.remote-client.d.ts;args 字段名即签名参数名):
- goals/create {agentId, request};goals/edit {agentId, ref, request};goals/pause|resume|complete|clear {agentId, ref}
- commands/execute {agentId, line};commands/list {agentId} → CommandDescriptor[](name/description/input.hint)
- 全部远程端点共同约束:subagent 会话作 agentId → agent-busy(ownership fence)
- session.prompt mode 枚举(zod 实证):**'queue' | 'steer'**(steer=插话进运行中轮次;生成代码里 mode 是 Object,调用方须传字符串字面量)
- 主题持久化:web 的 Appearance 行写 settings 命名空间 **"ui-theme"**(preference 键,light/dark/system)——theme/* 远程端点不可达,但 settings.mutate 可达,客户端主题同步走此通道(W3 用)
- 轨迹视图(web trajectory)零新 RPC:消费 runtime 的会话快照 + loadOlder(= session.history 分页,SessionStore 已有)。W3 实现为 SessionLog 上的纯客户端视图(轮次分组/ledger 行/检查器)
- 图片消息回显:**本部署模型目录无视觉模型**(全 catalog 无 image/vision 能力标记;prompt 带 image → attachment-error "does not support image input")。user/message 事件的图片引用形状无法在活体采样 → W3 的 refs 提取按防御式实现(data.content[] 中 type=='image' 携带 attachmentId 等 ImageAttachmentRef 字段),以 fixture 测试验收;真机有视觉模型后再活体验证(M4 结论同源:回执按需补)

## 8. 本机环境事实

- dsh CLI:`/Users/you/.local/lib/node_modules/@deepseek-ai/dsh/`(全局安装,`dsh` 在 PATH)
- 正在运行的 GUI:`http://127.0.0.1:3080`(可作为 conformance 测试的活体靶机;`host.describe` 无副作用可打)
- DSH_HOME:`~/.dsh`(profiles:web 等)
- 上游仓库:github.com/deepseek-ai/deepseek-harness(monorepo,契约在 `packages/host/apiproxy`)
