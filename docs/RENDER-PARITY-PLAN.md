# Flutter ↔ Web 会话渲染一致性规划(RENDER-PARITY-PLAN)

> 2026-08-17 全面检查产物。对照对象:本仓 Flutter 客户端(lib/)vs DSH 官方 web GUI(源码 monorepo packages/client/*,master;本机活体 http://127.0.0.1:3080 为 rc.6,两者有轻微版本差)。
>
> **判定基准(用户约束)**:Flutter 有消息气泡、不是组合渲染 —— 可接受;但**用户可见的内容集合**必须与 web 一致。即:web 上用户看得到的信息,Flutter 也要看得到(形式可不同);web 上用户看不到的,Flutter 不应多显示。

---

## 0. 结论摘要

> **实施进度(2026-08-17 第一轮落地)**:P0 全部 + P1 的 #3/#4/#5/#6/#7/#8/#9 已完成;
> #10(feedback 接线)按 Q1 活体复验结论**有意不接** —— 本机 rc.6 web bundle 实测不含
> ui-message-feedback(index/vendor 全部 chunk 探针零命中;master 默认装配才有),按「web 用户
> 看不到的 Flutter 不多显示」基准保持移除,升级 rc.7+ 后重验再挂。Q2 十类事件全部实锤不可见。
> 详见 §7 实施记录。

1. Flutter 的节点提取器(event_nodes.dart)对**聊天空泡主干**(user/assistant/think/tool/todo/compaction/retry/turn-error)覆盖良好,中断结算、历史回放无 view 渲染等硬语义都对齐了 web。
2. 最大的不一致不在气泡形态,而在三类:
   - **噪声(B 组)**:Flutter 把 15+ 类 web 根本不在时间线显示的事件(权限旋钮、inbox splice、goal/plan 投影等)渲染成 notice 短行,且对未知事件显示「未知事件」卡,而 web 只对「surface 三类型但不认识」这一理论情形显示兜底行;
   - **缺失(A 组)**:时间戳/耗时/TTFT/吞吐/统计行完全缺失;context 注入行、steering 插话气泡、产出文件行、消息反馈、workflow 运行卡、goal 常驻面在 web 默认装配里都有而 Flutter 不可见(其中 ProducedFilesRow / FeedbackActions / GoalPanel 三个 widget **已实现未接线**);
   - **降级(C-1)**:子代理 transcript 用「角色标签+纯文本」自绘,web 是完整会话视图(同一 ChatView 渲染能力)。
3. web 默认装配(packages/bundle/web-app/package.json:55-83)**包含** ui-message-feedback / ui-deliverables / ui-goal / ui-plan / ui-workflow-run —— lib/ui/node_widgets.dart:280-283 注释「本机 web 未装反馈插件」与 master 事实不符(本机是 rc.6 旧活体),实现时应以源码 + 活体复验为准。

---

## 1. 两端渲染架构对照(一段话版)

- **web**:事件流先经 runtime 折叠成 ConversationNode(kind 词表:user/steering/context/command/compaction/turn-error/turn-max-tokens/assistant/tool-result/model-retry/…,conversation.ts),再由各 UI 插件注册 ConversationNodeDefinition 把事件分组成 **Chat 节点**(assistant-step / tool-call(root+subCalls 树)/ model-retry 链 / manual-compaction / turn-tail / workflow-run / command / compaction / unknown-fallback,ui-conversation/src/client/conversation-nodes/),最后 ChatView 逐 key 渲染;时间线可见性 = **只有注册了节点的 surface 事件才可见**,其余 log-only 事件(step/*、turn/*、llm/retry 之外的杂项)默认不可见。兜底 unknown 只针对「surface 三类型(user/message、assistant/message、tool/result)但 UI 不认识」(core/session/src/surface.ts:15-19、51-55;fallback.ts:19)。
- **Flutter**:extractNodes 纯函数把事件拍成**扁平 ChatNode 流**(10 类,零跨事件合并,除 tool call↔result 配对外),ListView 逐节点渲染;白名单(_isInternalEvent)外的未知类型一律显示「未知事件」卡(event_nodes.dart:839-842);另有 15+ 类杂项事件渲染为中文 notice 短行(_noticeFor 944-1080)。

---

## 2. 差距清单

### A 组:web 可见、Flutter 不可见(内容缺失)

| # | 内容 | web 事实 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| A1 | 产出文件行(轮末 chip lane,+N 计数) | ui-deliverables 挂 turnTail slot,ProducedFiles.tsx;数据源=修改类工具的 locations | `ProducedFilesRow`(lib/ui/deliverables_row.dart:68)已实现 fit 算法,**全库无调用方** | **P0**(接线) |
| A2 | 时间戳/轮次耗时/TTFT/吞吐 | MessageIconActions:clock + Ran for + TTFT + tok/s(MessageIconActions.tsx:81-108);turn-tail 提供 runMs/ttftMs/tokensPerSecond(turn-tail.ts:139-148) | 聊天流所有节点均无时间显示;time 字段不提取 | P1 |
| A3 | 会话统计条 | StatsLine:轮数/步数/LLM 耗时/工具耗时/TTFT 均值/tok-s/缓存命中/token(StatsLine.tsx:163-233),优先 sessionStats 投影 | 无;usage 数据完全不提取 | P1 |
| A4 | 工具卡耗时 | ToolRow 展开/行内显示 call→result 墙钟时长 | 无;node 已有 callSeq/resultSeq 但无 time 差 | P1(实现小) |
| A5 | context 注入行 | ContextMessageNode + ContextInjectionRow(带 provenance/form,MessageItem.tsx:261-272) | `source.kind != 'user'` 的 user/message 一律过滤(event_nodes.dart:742-756),注入上下文零痕迹 | P1 |
| A6 | steering 插话气泡 | 已接纳插话 = user 样式气泡(MessageItem.tsx:237-258);待接纳 = PendingSteeringBubble(ChatView 顶部) | QueueDock 只显示 placement=='queued',steering 项被滤(interactor_widgets.dart:490-493);被接纳后的插话消息若无 user/message user-source 事件则不可见 | P1 |
| A7 | workflow 运行卡 | ui-workflow-run:run-start/agent-start/end 聚合成一卡(阶段分组、成员状态、点开子会话,workflow-definition.ts:90-127) | tool-workflow/* 四类各渲染一条 notice 短行(event_nodes.dart:1045-1076) | P1 |
| A8 | goal 常驻面 | ui-goal:GoalBar(composer dock)+ goal 投影 + 变更动词 | 仅 goal/change notice 行;`GoalPanel`(goal_skill_widgets.dart:7)已实现未接线 | P1(接线) |
| A9 | 消息反馈(👍/👎+备注) | ui-message-feedback 挂 assistant-actions slot;默认装配包含(web-app/package.json:62) | `FeedbackActions`(feedback_row.dart:38)已实现未接线;node_widgets.dart:280-283 注释按「web 未装」移除 —— 前提已失效,需复核 rc.6 活体后接线 | P1 |
| A10 | 子代理 transcript 完整渲染 | openSubagent 打开普通会话视图(同一套 ChatView/工具卡/think) | 目录页 _eventTile 自绘「角色标签+extractText 纯文本」(subagent_catalog.dart:610-631),think/工具卡/图片全丢 | P1 |
| A11 | plan 模式活动 chip | ui-plan:composer plan 座,活动态显示 + 一键 /plan off | 仅 plan/mode notice 行 | P2(composer 域) |
| A12 | retry 链聚合一行 | 同 retryId 聚合为单 disclosure 行,展开看 delay/failure(retry.ts:41-55) | 每条 llm/retry 独立 notice;llm/retry-started 丢弃 | P2 |
| A13 | 用户气泡 /cmd @subagent ref chip | projectUserText 装饰(MessageItem.tsx:157-176) | 纯文本 | P2(装饰性) |
| A14 | 工具渲染意图专用卡(diff/read/search/web/terminal) | ToolRow 按 callView 换 DiffBlock/ReadBlock/SearchBlock/WebBlock/TerminalBlock(ToolRow.tsx:59-88) | view 只取 summary/title/output 文本,无专用卡 | P2(信息在,形态降级) |
| A15 | 日期感知时钟 | use-calendar-day,跨天显示日期 | 无时间显示(同 A2) | P2(随 A2) |

### B 组:Flutter 可见、web 不可见(多出噪声)

| # | 内容 | web 事实 | Flutter 现状 | 优先级 |
|---|---|---|---|---|
| B1 | 杂项事件 notice 行 | 以下事件 web **均不在时间线渲染**:permission/preset、sandbox/mode、approval/policy(composer chip 读源)、approval/asked/decided(ApprovalPanel 交互卡,时间线无痕)、agent/inbox/spliced(inbox 节点 publication:'none',inbox.ts:52)、goal/change(GoalBar 投影)、plan/mode(plan chip 投影)、tool-workflow/*(workflow 卡)、command/run/done(专用 CommandNode 卡 GenericCommandCard/CompactionCommandCard,非 notice) | 上述全部渲染为中文 notice 短行(_noticeFor 944-1080);审批既有交互卡又发 notice(双份) | **P0**(重分类:删行/换形式) |
| B2 | 未知事件兜底范围 | 只对 surface 三类型不认识时显示(fallback.ts:19-28);判定输入 = type∈{user/message,assistant/message,tool/result} 且 surfaceOp=='append'(surface.ts:15-55) | 白名单外**一切**未知类型显示「未知事件」卡;surfaceOp 字段被丢弃(sessions.dart 生成物有,代码未读) | P1(镜像 surface 语义) |
| B3 | 聊天流 todo 快照卡 | web 时间线无 todo 快照卡;todo = TodoPanel(面板)+ todo 工具行摘要(todo-row.tsx) | _TodoCard 进度卡 + TodoPanel 双呈现;且 _TodoCard 只画进度条,逐项明细提取了不渲染 | P2(保卡则补明细,或对齐为工具行) |

### C 组:形态差异(用户已接受 / 移动适配,不动)

| # | 差异 | 说明 |
|---|---|---|
| C-0 | 扁平节点流 vs turn 分组组合渲染 | 用户明确接受;web 的 assistant-step/turn-tail 分组、ToolCallTree 嵌套、StatsLine 独占行等**不要求**复刻,只要求信息等价 |
| C-1 | 审批/问答位置 | web=composer takeover(ApprovalPanel.tsx 头注释);Flutter=消息流下方 _InteractorPane。按钮集合一致(拒绝/允许一次,ApprovalPanel.tsx:76-81 vs interactor_widgets.dart),非当前会话审批 Flutter 还有注意力弹窗 —— 移动增强,保留 |
| C-2 | 工具卡样式 | web 单行 disclosure + 展开;Flutter 卡片+徽章。内容字段对齐即可(差 A4 耗时、A14 专用卡) |
| C-3 | think 块 | 两端语义一致(默认收起、流式尾行滚动);Flutter 6000 字截断+全屏,移动增强 |
| C-4 | code-dispatch 子调用 | web 嵌套进父卡(tool.ts:144-169);Flutter 过滤为内部事件(event_nodes.dart:301-302)。属「组合渲染」范畴,按用户约束可不复刻;若要信息等价可进 P2(见开放问题 Q3) |
| C-5 | 轨迹页 | Flutter 有整页 trajectory(移动增强),web 是 side panel;非差距 |
| C-6 | unknown 的 JSON 展示 | 两端都有 JSON 兜底展示,形态不同,可接受 |

---

## 3. 分阶段计划

> 纪律:沿用 PLAN.md 的垂直切片方式;每项 = 域层改动 + fixture 回放测试 + 活体冒烟;提交 ≤400 行。event_nodes.dart 是纯函数库,绝大多数改动可先写 fixture 用例再动实现。

### P0 —— 噪声对齐 + 免费接线(1-2 个提交,先行)

1. **notice 词表重分类**(B1):按 web 语义把 _noticeFor 词表分三档——
   - 删除(时间线不可见):permission/preset、sandbox/mode、approval/policy、approval/asked、approval/decided、agent/inbox/spliced、goal/change、plan/mode、schedule/change、agent-preset/selected(后两类活体复验 web 无时间线行后定档);
   - 换形式(后续阶段):command/run|done → P1 命令卡;tool-workflow/* → P1 workflow 卡;
   - 保留:无(现词表全部有更对齐的去处)。
   验收:fixture 回放同一日志,Flutter 时间线行集合 ≡ web 可见节点集合(人工对照截图)。
2. **ProducedFilesRow 接线**(A1):在轮末(最后一个 assistant 节点后)渲染;数据源从 ChatNodeTool(kind=edit/有 locations 的 result)提取 —— 提取器落在 event_nodes 或 chat_view_model,单测覆盖 fit 算法已有(test/ui/feedback_deliverables_test.dart)。

### P1 —— 内容补齐(核心阶段,按独立可验收排序)

3. **时间基线**(A2+A4+A15):SessionEvent.time 进 ChatNode;user/assistant 气泡下沿加轻量时钟(移动简化:点按显示,不做 hover);工具卡标题行加耗时(call.time→result.time);turn 耗时挂在轮末(复用 turn/end time-start)。纯展示,不动节流。
4. **统计条**(A3):composer 上方一行 StatsLine 等价物;数据优先 session/projection 的 sessionStats/tokenUsage 投影(若 rc.6 未提供则本地折叠,镜像 deriveStats 语义);格式对齐 formatTokens/formatDuration(517/12.2K、45.2s/2m42s)。
5. **context 注入行 + steering 气泡**(A5+A6):user/message 不再按 source.kind 一刀切——kind=='user' 右气泡;steering(被接纳插话)右气泡带「插话」标记;agent.inject 等注入 → 左侧低调行(source/form 摘要);QueueDock 补 steering 项(或采纳后即出气泡,dock 保持 queued-only)。
6. **unknown 收窄**(B2):提取器读 surfaceOp;未知类型默认不可见,仅 surface 三类型且不认识时显示兜底卡;_isInternalEvent 白名单保留但仅作已知协议事件的快速路径。
7. **workflow 运行卡**(A7):tool-workflow 四事件聚合成单卡(阶段分组+成员状态),成员行点击 → SubagentStore 打开对应子会话 transcript(依赖 #9)。
8. **goal 接线**(A8):GoalPanel 挂进会话页(建议 composer dock 区折叠条,对齐 web GoalBar 位置语义);数据走既有 goal_store 六方法。
9. **子代理 transcript 升级**(A10):目录页子会话改用 extractNodes+ChatNodeList(与主聊天同能力);_eventTile 仅作降级兜底(事件类型超期时)。
10. **feedback 接线**(A9):先活体确认 rc.6 web 是否装配反馈(本机 GUI 实测);FeedbackActions 挂 assistant 气泡操作行(复制/分叉旁);feedback/record 事件维持不可见(web 同样无时间线行)。

### P2 —— 形态增强(可选,按需排期)

11. plan chip(A11,composer 域,随 composer_pro 演进);12. retry 聚合(A12);13. ref chip 装饰(A13);14. diff/read/search/web 专用卡(A14,依赖 view 的 card 意图,历史回放无 view 时保持通用卡);15. todo 卡明细或移除(B3);16. code-dispatch 嵌套(C-4,若活体确认 web 用户常规可见)。

---

## 4. 验收口径

- **fixture 回放**:fixtures/ws/*.jsonl 扩充一段含 context 注入、插话、workflow、审批、retry 的真实日志;断言 extractNodes 输出的「可见内容矩阵」与本文档 A/B 组定义一致。
- **活体对照**:对 http://127.0.0.1:3080 发同一 prompt 序列,web 与 Flutter 并排截图逐项核对 A 组字段(时间、耗时、统计、文件行、workflow 卡)。
- **既有基线不回退**:flutter test 全绿(pairing_page 3 例已知破损除外)、flutter analyze 0 error;流式 250ms 节流不动。

## 5. 开放问题

- **Q1** rc.6 活体的插件装配与 master bundle 是否一致(feedback/deliverables)?→ P1 #10 前实测本机 GUI。
- **Q2** schedule/change、agent-preset/selected 在 web 的时间线可见性未逐一实锤(推断为投影不可见)→ P0 #1 实施时活体触发一次确认。
- **Q3** code-dispatch 子调用:web 嵌套展示属「组合渲染」,按用户约束不强制;但信息等价角度 run_code 的子调用结果在 Flutter 完全不可见(父卡 output 汇总是否总是完整?需活体确认)。
- **Q4** turn-tail 的 branchUnavailable/fork 语义两端已有(分叉),不在此轮范围。

## 6. 附录:事件类型 → 呈现对照总表

| 会话事件 | web 呈现 | Flutter 呈现 | 档位 |
|---|---|---|---|
| user/message(user source) | 右气泡+图廊+ref chip | 右气泡+图片 | 对齐 |
| user/message(steering/注入) | steering 气泡 / context 注入行 | 全部过滤 | A5/A6 |
| assistant/message + chunk | assistant-step 节点(text/reasoning/image 块序渲染) | think+assistant 两节点(拆) | 形态可接受 |
| tool/call + result | tool-call 节点(root+嵌套 subCalls),单行+展开卡 | _ToolCard 配对卡(扁平) | 对齐(差 A4/A14/C-4) |
| tool/code-dispatch* | 父卡嵌套子行 | 过滤 | C-4 |
| compaction/* | compaction 标记行(manual-compaction 聚合命令+摘要) | _CompactionRow | 对齐(手工聚合差异小) |
| llm/retry(-started) | model-retry 聚合行(倒计时+失败详情) | 独立 notice | A12 |
| turn/error、turn/end(error/max-tokens/…) | turn-error / turn-max-tokens 常驻行 | ChatNodeError/Notice | 对齐 |
| command/run、done | CommandNode 卡(通用/压缩专用) | notice 行 | P1 #7 前后 |
| tool-workflow/* | workflow-run 卡 | notice×4 | A7 |
| approval/requested(resolved) | ApprovalPanel(composer 接管) | 交互卡+notice 双份 | C-1+B1 |
| question/requested(resolved) | composer 接管表单 | QuestionForm | C-1 |
| session/queue | composer 区队列投影 | QueueDock(queued-only) | A6 补 steering |
| todo/write | TodoPanel + todo 工具行 | _TodoCard+TodoPanel | B3 |
| goal/change | GoalBar 投影 | notice 行 | A8 |
| plan/mode | plan chip 投影 | notice 行 | A11 |
| permission/preset、sandbox/mode、approval/policy | composer chip(非时间线) | notice 行 | B1 |
| agent/inbox/spliced | 不可见(publication none) | notice 行 | B1 |
| agent-preset/selected、schedule/change | 投影/不可见(待实锤) | notice 行 | B1/Q2 |
| feedback/record | 不可见(反馈走 RPC+slot 按钮) | 不可见 | 对齐(接线 A9 是按钮非行) |
| hook/*、request/*、session/title*、subagent/descriptor、step/*、turn/start、web/*-llm-request | 不可见(log-only) | _isInternalEvent 吞掉 | 对齐 |
| 其它未知 | 仅 surface 三类型不认识时兜底行 | 一律「未知事件」卡 | B2 |

> 引用文件均为本仓相对路径;web 侧为 monorepo 绝对路径下 packages/client/*(见文首对照对象)。

---

## 7. 实施记录(2026-08-17 第一轮)

**落地项**(lib/sessions/event_nodes.dart 为核心,纯函数层先行):

- **B1 噪声重分类(P0)**:_noticeFor 整体删除;permission/preset、sandbox/mode、approval/policy、
  approval/asked|decided、agent-preset/selected、goal/change、plan/mode、schedule/change 全部归
  _isInternalEvent(web 无时间线节点,Q2 实锤);agent/inbox/spliced 提前消费做 steering 判定后不可见
  (web publication:'none');command/run|done → ChatNodeCommand 单卡配对(run 锚卡,done 回填终态);
  tool-workflow/* → _WorkflowState 按 runId 聚合。
- **B2 unknown 收窄(P1 #6)**:兜底卡仅 surface 三类型(user/message|assistant/message|tool/result)+
  surfaceOp=='append' 且防御形状;其余未知类型不可见(镜像 fallback.ts;isAppendSurfaceEvent)。
- **A5+A6(P1 #5)**:user/message 按 source.kind 三分类 —— user → 右气泡(claimed → steering 插话
  徽标);非 user → ChatNodeContextRow 左侧折叠行(provenance 词表完整移植 context-provenance.ts:
  agent-instructions→changes[].path、plugin→id、skill-invocation→name、session-reference→recall)。
  _NextStepInboxState 移植 inbox.ts applySplice(removed→claimed)驱动插话判定。
- **A1(P0 #2)**:ChatNodeTool.producedPaths(call view:card=diff 或 generic+kind=edit 的 locations);
  成功结算计入轮累计,turn/end 结转 ChatNodeDeliverables → ProducedFilesRow 接线(fit 算法已有测试)。
  无 view 的历史回放无产出行(web 同源:locations 只在实时帧携带)。
- **A2+A4+A15(P1 #3)**:SessionEvent.time 进 ChatNode(全节点);用户气泡时间(formatNodeTime 同日
  HH:mm/跨日带日期 = use-calendar-day 语义);助手操作行轮末指标(runMs/ttftMs/tok-s,
  _TurnMetrics 移植 turn-tail/assistantStepReading);工具卡 callTime→resultTime 耗时
  (formatDurationMs = web formatDuration)。
- **A3(P1 #4)**:lib/sessions/session_stats.dart(sessionStats/tokenUsage 投影优先,deriveSessionStats
  窗口折叠兜底,字段名镜像 projection);SessionStatsBar 挂 composer 上方(web composer.dock 同位),
  分组构造镜像 StatsLine.tsx(组内缺席整组缺席)。
- **A7(P1 #7)**:_WorkflowRunCard 阶段分组 + 成员状态 + 子会话点击回调(ChatNodeList.onOpenSubagent)。
- **A8(P1 #8)**:GoalPanel 升级投影驱动(阶段徽标/轮次/正文/操作,phase 决定按钮集);
  ChatViewModel.selectedGoalProjection(goal 投影优先,goal/change 回退);_GoalDock 挂 composer 上方
  (web GoalBar 位置语义);GoalStore 动作接线(main → SinglemanApp → ChatScreen → _MessagePane)。
- **A10(P1 #9)**:SubagentTranscriptPage 改 extractNodes+ChatNodeList(与主聊天同能力:think/工具卡/
  markdown);_eventTile 降级为「查看原始事件」弹层兜底。
- **A9(P1 #10)**:不接线(Q1 结论,见摘要);feedback_row.dart 组件保留待升级后复用。

**验收**:flutter test 533+ 过 / 仅剩 pairing_page 3 例已知 WIP 破损(非本轮改动);
flutter analyze 0 error;新增 test/ui/parity_render_test.dart 13 例(widget 渲染矩阵)+
event_nodes_test 重写 6 例旧噪声断言、新增 5 例(command/deliverables/provenance/time)。

**Q1 复验方法**:curl 本机 3080 的 index/vendor bundle,对 messageFeedback/GoalBar/sessionStats/
ProducedFiles/workflow-run/Ran for 等标记全文探针 —— index 仅命中 CSS 类名 feedback(Tooltip 复制
反馈,非消息反馈)与图标名,无任何插件特性标记;结论:rc.6 活体与 master bundle 装配不同,
feedback/deliverables/stats 等均为 master 特性。Flutter 端 stats/deliverables 属信息补齐方向
(A 组,web master 可见),保留;feedback 属交互插槽(rc.6 不可见),不接。
