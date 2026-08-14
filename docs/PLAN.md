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

### M2 最小聊天环(可演示)
- [ ] `workspace.list` + `session.create/list` + `session.prompt` + `session.history`(含 projections 尾页)
- [ ] 纯文本/markdown 渲染会话流(session/event 增量)
- **验收**:桌面 app 里完成一次真实对话,断网重连不丢状态

### M3 交互帧
- [ ] `approval/requested` → `POST /api/respond` 审批卡(allow/deny)
- [ ] `question/requested` 结构化问答表单(**注意服务端严格校验**,bad-response 规则见 DSH-PROTOCOL §5,靠 fixture 兜)
- [ ] `session/queue` 队列 Dock + `session.updateQueue` 编辑/删除 + `session.cancel`
- **验收**:fault 注入 + fixture 回放全绿

### M4+ 并行功能面(fan-out,每个特性独立上下文)
按需并行,每特性一个任务包:图片附件上传(含限额本地预拒)、模型选择器(`session.models/selectModel`)、会话 fork/导出(ZIP 下载)、session.search、workspace 管理、goal 面板、skill 菜单(`/name` 即普通 prompt,无需专线上)、手机 LAN 形态(trusted-host 引导页 + 隐藏特权面)。

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
