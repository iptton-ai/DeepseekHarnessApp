# dsh client-ui 功能审计：orchestration 类包（Flutter 复刻参考）

> 审计范围：7 个 @deepseek-ai/dsh-client-ui-* 包（编译产物 lib/*.js + types/*.d.ts + README.zh.md）。
> 结论口径：RPC 方法名以源码字符串为准；带"未查明"的为源码中无字面量、需以 host/协议侧为准。
> 移动端建议针对 360–430dp 竖屏，遵循 44dp 触控目标、底部 sheet、全宽卡片三项默认。

---

## 1. dsh-client-ui-commands — 斜杠命令体系

**1. 功能一句话**：`/` 命令的完整前端：会话级命令目录缓存、联想菜单（fuzzy 子序列匹配）、三种派发（execute 直接执行 / popupSelect 弹层选择 / leadingInput 带参输入），业务包可注册"客户端自有命令"（popupSelect 型）或为 host 命令挂"裸调用装饰"（装饰项仅在目录有 host 行时触发）。

**2. RPC / 事件**：
- RPC：`command.list({sessionId})`（目录拉取，绑定根连接，按会话 single-flight 缓存）；`command.execute(sessionId, line)`（派发；leadingInput 以"claim token + 提交事务"形式走 execute）。
- 事件（订阅）：`commands/change`（软失效，重拉在途旧快照继续服务）、`agent-preset/selected`（按会话单独软失效）、`connection/reset`（硬失效清缓存，epoch 把关防旧拉覆盖）。
- 事件（本地发布）：`command/executed(sessionId, name, result)`——仅提交方浏览器收到（用于浏览器专属副作用，Session 回放不触发）。
- 信号：`SubmitAttempt`（matchEnter 强等目录 ensureReady，预热失败即拒绝，`/` 开头绝不静默降级为普通提示词）；host 侧生命周期事件 `command/run` / `command/done` 只读参考。

**3. UI 结构要点**：PopupSelectView 覆盖层（z-index:100，注册进 `conversation.input.overlay`）：顶部搜索输入框 + 选项卡片列表（aria-selected 高亮、选中项 scrollIntoView）+ 风险确认卡（SelectConfirmation：标题/描述/checkbox 承认/确认/取消，确认前 onSelect 不执行）。失败态显示 error（role=alert）+ retry 按钮（search 保留）。fuzzy 规则：子序列不区分大小写模糊匹配，前缀最高，其余按分隔符边界>相邻>间隔短排序。键盘：↑↓ 移动高亮（循环）、Enter 选中、Escape 关闭并还焦 composer。派生规则：host descriptor 带 input → leadingInput；注册了 CommandUiSpec → popupSelect；其余 → execute。菜单只显示 pending/ready。

**4. 移动端注意点**：桌面悬浮卡片在手机上应降级为底部 sheet 或全屏选择器（输入框置顶、列表可滚、底部确认区固定）；选项行高 ≥44dp；风险确认卡的 checkbox 改为大号确认按钮（防误触）；fuzzy 搜索保留但键盘导航（↑↓/Enter/Escape）降级为点选 + 关闭按钮；"裸调用装饰"入口在无 hover 的手机上即"点命令项直接弹选择器"。

---

## 2. dsh-client-ui-goal — Goal 状态条带 + /goal 命令气泡

**1. 功能一句话**：composer 上方 dock 的 Goal 条带：显示当前目标（字形 + 阶段标签 + 截断目标文本），提供 编辑（条带内联输入）/ 暂停 / 恢复 / 清除 四个动词；并把持久化的 `/goal` command/run 渲染成右对齐用户气泡（"命令输入"），创建目标本身走 `/goal` host 命令。

**2. RPC / 事件**：
- RPC：`goals/edit(sessionId, ref, {objective})`、`goals/pause(sessionId, ref)`、`goals/resume(sessionId, ref)`、`goals/clear(sessionId, ref)`（ref 为调用时从会话投影读取的 CAS；拒绝错误内联呈现）。
- 订阅：`useProjection('goal')`——host 计算全量值，由历史尾页播种 + `session/projection` 帧更新（本包无领域 store、无刷新链、无事件监听）；持久会话流中 `command/run`（name==="goal"）重建 command-input 节点。
- 相关机制：变更提交后 `agent/inbox/spliced` 插入项被投影立即折叠并排队 `goal/change` 上下文消息（模型侧）；清除成功立即抑制该 goal id 显示直到权威 null 投影。

**3. UI 结构要点**：dock 条带（宽 = 100% − 两侧 composer clearance）：目标字形 + 阶段标签（进行中/已暂停/受阻）+ 截断目标 + 图标动作行（active→暂停、paused→恢复、编辑、清除）；编辑态整条变为内联 input + 保存/取消（保存成功退出编辑）；错误 role=alert 内联；加载中/无 goal/已完成/已清除 一律不渲染；变更 single-flight 防同帧重复点击。command-input 气泡：右对齐、等宽 14px/22px 用户样式、无时间戳/复制/分支操作、分组名"命令输入/Command input"。

**4. 移动端注意点**：条带本身全宽，天然适配手机；4 个图标动作触控区 ≥44dp，窄屏可收进"⋯"溢出菜单（暂停/恢复二选一显示，实为 3 个常驻动作）；内联编辑 input 全宽；目标文本截断单行（完整目标放 tooltip 或长按展开）；"仅反映持久 phase、不区分 active-but-disarmed"的局限在手机上同样成立，无需特判。

---

## 3. dsh-client-ui-skill — skill 菜单源 + skill 工具行

**1. 功能一句话**：`/` 菜单里的 skill 候选源（用户可键入 `/name` 调起 skill，注入渲染后的 `<skill_content>`），以及聊天流中 `skill` 工具调用的可展开卡片行（加载/失败/中断状态 + Instructions 说明 + Inspect）。

**2. RPC / 事件**：
- RPC：`skill.list`（按会话寻址，host 从会话 header 解析 cwd；结果按 `startsWith(query)` 过滤；插件注册时捕获根连接，绝不读调用参数）。
- 事件（订阅）：`agent-preset/selected`（丢弃该会话缓存项——目录属 preset）、`connection/reset`（清空全部缓存）。
- 渲染数据只来自 ui-tool 冻结的工具调用/结果切片，绝不读当前 skill 目录（回放稳定）。
- 说明：`modelInvocable:false` 的条目（disable-model-invocation）菜单描述加"仅用户/仅用户可调用"前缀；`skill.list` 失败时该菜单组静默丢弃（只显示 pending/ready）。

**3. UI 结构要点**：工具行 24px 高（chevron + 文档/闪光组合图标 + "Skill" 标题 + 分隔符 + skill 名称）；运行中带扫光动画（dsh-skill-row-sweep）；失败用错误首行替换名称（errorSummary）；中断用警告状态；整行可展开 → 尺寸受限的 Instructions 卡片（pre 原样呈现输出）+ "Inspect" 按钮（标准执行轨迹入口）。菜单侧：候选行 + 状态点。

**4. 移动端注意点**：24px 工具行在手机聊天流中偏矮，建议触控区扩到 ≥40dp（整行仍可展开）；展开的 Instructions 卡片限高内滚，手机上可改为全屏预览页（pre 长文本更易读）；菜单候选列表与 commands 共用底部 sheet 交互模式。

---

## 4. dsh-client-ui-plan — Plan mode 徽章

**1. 功能一句话**：plan mode 状态徽章 chip：当 host 计算的 `plan` 投影有效目标为 plan mode 时，在 composer 上方（access 模式控件右侧单实例 seat）显示 warn 色 "Plan ×" 按钮，点击派发 `/plan off` 退出；plan 模式期间 composer placeholder 切换为"描述你的任务以生成计划"。

**2. RPC / 事件**：
- RPC：`command.execute(sessionId, "/plan off")`（经 remote.commands）。
- 订阅：`useProjection('plan')`——host 计算折叠值（`pending ? !active : active`，非客户端乐观态，帧到达自动纠正）。
- 无独立事件订阅；准入失败（matched:false/业务错误/传输故障）内联呈现，chip 保持显示直到投影确认退出。
- 模型经稳定工具 `exit_plan_mode` 退出（属 dsh-plan-mode，本包只渲染投影）。

**3. UI 结构要点**：chip = warn 色按钮（"Plan" + ×），带无障碍描述 "Plan mode on, press to turn off"；未激活态不渲染任何控件（入口走共享 Command source 的 + 菜单/`/plan`）；placeholder 由 ui-conversation 的 conversation locale 命名空间提供（placeholder.plan/hint.plan）。

**4. 移动端注意点**：chip 尺寸小，手机需 ≥44dp 点击目标；建议作为输入栏内嵌按钮（输入框左侧）或与 + 菜单并排，避免悬空小 chip；无 hover，状态提示靠 chip 自身文字 + 可选 Snackbar；其余零降级成本。

---

## 5. dsh-client-ui-subagent — subagent 目录树 + 只读 composer + @ 引用

**1. 功能一句话**：会话页头"子代理目录"入口（懒加载展开的 subagent 树：mode、运行状态、token 用量合计、运行耗时，点选打开 child 会话）；one-shot child 与 parent 不可用的可继续 child 用只读 composer 替代（说明原因，运行中则禁用输入+Send、保留 Stop）；旧 `@` 引用 source（零 RPC 列出运行中 child，pick 插入字面 `@label `）。

**2. RPC / 事件**：
- RPC：`sessions.openSubagent({parentSessionId, childSessionId, mode})`（打开任意深度条目）；`@` source 读 `sessions.list` 快照（零 RPC）；child 会话消息经 host `subagent.prompt` 路由（FIFO inbox）、运行中可继续 child 的停止经 `subagent.interrupt`（README 声明，本包代码内不直接出现字面量）。
- 订阅：`useSessions`（`subagentsByParent` 目录 + `byId` 摘要）、`sessions.list.subscribe`；每层目录懒加载；可见分支上报运行时做去抖刷新；只读 composer selector 匹配 `parent-unavailable`（owner.session 不存在或非 running）。

**3. UI 结构要点**：页头 action 触发器 → 弹出树（role=tree/treeitem）：行 = disclosure（已知叶子无箭头；整层无分支则不预留展开列）+ StateDot（running→ongoing / 其余 done）+ label（one-shot 无 label 回退会话 id）+ 尾随两行指标（上行 provider token 用量四桶合计，下行运行耗时：<1 天精确到秒，≥1 天两单位缩写，hover 保留精确值）；展开分支先插禁用的"加载中"占位行再懒加载替换；诊断行（corrupt/unsupported/unavailable）可读但禁用；错误态有 retry 按钮。键盘：→/← 展开折叠、↑↓/Home/End/Escape 导航、关闭后焦点还触发器。只读 composer：解释文案（"one-shot"→已完成的执行记录；"parent-unavailable"→说明恢复路径），运行中可继续 child 期间让位给普通编辑器（输入+Send 禁用、独立 Stop 可用，停止后恢复只读）。`@` source：菜单候选为运行中 child（label 显示），pick 插入 `@label `（无继续执行语义）。

**4. 移动端注意点**：树形目录是典型桌面控件——手机上应改为全屏抽屉/独立导航页（面包屑或返回键逐层进入，避免嵌套弹出层）；行高 ≥44dp、指标双行可折叠为"详情页"；键盘导航全部降级为触摸展开；`@` 菜单与 commands/skill 共用底部 sheet；只读 composer 的 Stop 按钮必须醒目（运行中 child 是手机上最常见的到达场景）。

---

## 6. dsh-client-ui-workflow-run — workflow 运行节点

**1. 功能一句话**：把持久化的顶层 workflow 运行重建为聊天中一个可折叠 Chat 节点：运行行 + 阶段 disclosure 组 + 成员行（实时状态：运行中/完成/失败/取消/中断），运行中的 subagent 成员可点击打开其子会话。

**2. RPC / 事件**：
- 事件（订阅）：`tool-workflow/run-start`（以 runId 创建唯一 Context）、`tool-workflow/agent-start`、`tool-workflow/agent-end`、`tool-workflow/run-end`（按日志顺序折叠进 Context；只有 update 的历史尾页保持 pending 直到补入唯一 start；终点事件缺失 → 显示为已中断，不改写工具结果）。
- RPC：`sessions.open(id)`（注入的普通会话打开；仅当"成员仍在运行 ∧ 子 id 在普通会话列表 ∧ origin==='subagent' ∧ parentId===当前会话 ∧ 列表行仍 running"五条件全成立才可导航）。
- 订阅：`useSessions` 快照（shallowEqual 派生 navigableMembers）。

**3. UI 结构要点**：运行行 32px（--dsw-alias-bg-module-platform 背景、常驻 chevron、内联状态点+状态文字、无胶囊）；阶段行 32px disclosure（可伸缩主区=标题+成员数，固定尾部=聚合状态文字，如"2 完成 · 1 运行中"）；成员行（16px 状态点槽 + 可省略名称区 + 固定 64px 状态列；可导航成员名称带下划线 + 焦点环）。disclosure 状态由生命周期事实派生：运行/受影响阶段在存在进行中或失败/取消/中断成员时强制展开，全部完成后折叠一次；强制展开行是静态行（无 aria-expanded）；干净层级恢复普通控件且 rerender 保持本地选择。

**4. 移动端注意点**：三层嵌套（运行→阶段→成员）disclosure 在手机上应支持"全部展开/收起"一键切换；64px 固定状态列 + 名称在窄屏可改为"名称 + 右侧状态胶囊"单行布局；可导航成员（下划线）在手机上必须给出 ≥44dp 整行触控区并加右箭头视觉提示（下划线在无 hover 的触屏上不直观）；终态成员不可导航的规则保留。

---

## 7. dsh-client-ui-user-questions — 模型提问交互 + plan 审批

**1. 功能一句话**：composer 被待回答问题接管：分页展示单选/多选/自定义答案（推荐徽标、进度导航、跳过、一次提交整批结构化答案）；plan-review 意图降级为审批卡片（Plan review 条带 + 可滚动 markdown 计划 + Chat about it / Refuse / Approve 三动作）。

**2. RPC / 事件**：
- 交付：经运行时 carrier `PendingWait.respond()` → `api.respond(ClientResponse)` 信封（回执被拒则抛错；rpcId 为本地草稿 key）；取消 = `code:"cancelled"`（ASK_CANCELLED，整个等待拒绝）。wire 方法名未查明（在 dsh-client-runtime 信封层）。
- 事件（订阅）：host 帧 `question/resolved`（携带 questionRpcId，移除编辑器；HTTP 交付成功不本地移除——host 有最终决定权）；模型可见工具 schema/结果归 `dsh-tool-ask-user`。
- 备注：主机侧刻意为空（工具挂到需要它的 preset，避免全局层污染所有 agent）。

**3. UI 结构要点**：限高卡片（frame 内滚，标题/分页导航/底部提交动作固定）：标题 + 详情（MarkdownText，GFM + 不受信任内容策略）+ 选项列表（单选 radio、多选 checkbox、推荐徽标由标签后缀派生、自定义答案 textarea；多选编辑自定义时保留已选标签，单选自定义保持互斥）+ 进度 pager + 底部动作（跳过/提交）。单选选中立即前进；全部回答或跳过后 Enter 提交（IME 合成中 Enter 只确认候选）。plan-review 卡片：条带 + 可滚动 plan 主体 + 三按钮（Approve/Refuse 用提问方自己的选项标签作答，提问方描述留 tooltip；Chat about it 以 ASK_CANCELLED 拒绝让编辑器归位）；只在"单问题 + 声明 intent + detail 有 plan + 批准标签命中 + 二元单选"时接管，意图只改布局不改可达答案。

**4. 移动端注意点**：限高卡片天然适合手机（顶部标题+进度固定、中部滚动、底部动作固定）；选项行 ≥44dp，checkbox/radio 触摸目标加大；自定义 textarea 全宽、键盘弹出时卡片自动滚动到输入位；plan-review 的 markdown 内滚在手机上建议提供全屏展开模式（或底部 sheet 化）；"跳过"与"提交"固定底栏防误触。"草稿不持久（刷新重置）"、"每次仅一个请求拥有编辑器"两条局限照搬。

---

## 横向移动端要点（7 包通用）

1. 三处弹层（commands popupSelect、subagent 目录、skill/`@` 菜单）统一为底部 sheet 模式：搜索/列表/确认三区固定，减少桌面悬浮卡差异。
2. 所有 hover 交互（fuzzy 高亮跟随、下划线导航提示、tooltip 精确耗时/文案）在手机降级为：点选高亮、整行触控、长按或详情页展示。
3. 键盘专属行为（↑↓/Enter/Escape、IME 合成、还焦 composer）在手机由系统输入法 + 返回键自然承担，无需复刻。
4. 触控目标统一 ≥44dp；窄屏文字截断一律单行 + 展开入口（goal 目标、workflow 成员名、skill 名）。
5. 全部状态变更遵循"投影驱动 + single-flight + 内联错误"模式（goal 动词、plan chip、command 派发），Flutter 端可映射为 ValueNotifier/Bloc + 请求锁，无需每包自建 store。
