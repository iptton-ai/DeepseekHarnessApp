# 功能审计:conversation 相关 client-ui 包(Flutter 复刻目标)

> 审计日期:2026-08-13 | 范围:6 个 @deepseek-ai client-ui 包 | 目标:复刻 dsh web GUI 到 Flutter 原生客户端,保证手机可用性
> 说明:所有包均"无模型体验、无 KV Cache 影响"(纯浏览器渲染层);RPC/事件均基于编译产物 lib/*.js 与 .d.ts 中的调用点与字符串字面量核对。

---

## 1. dsh-client-ui-conversation(会话主包,最大)

### 1.1 功能一句话总结
整个会话界面骨架与聊天流:会话页头+视图标签环、聊天流(用户/助手/思考/工具/命令/压缩/重试/错误/上下文注入等节点)、输入区(composer:多行 textarea、模型 seat、上下文仪表、权限选择、发送/停止/插话)、编辑器 dock(队列 dock+Todo 计划条)、统计行、审批面板接管、空状态 Workspace 选择器、详情壳层。

### 1.2 消费的 RPC / 事件
- RPC:session.prompt(content, mode)(mode: 'queue'|'steer',steer=插话进运行中轮次);session.cancel(取消激活;已寻址 subagent 无逐 Activation 取消,仅 Send);session.updateQueue(队列编辑/删除/严格 steering);session.command / command.run(/permission <preset> 等);session.getSnapshot;session.readAttachment(附件 URL)。
- 投影(useProjection):tokenUsage(计费 token/缓存命中率)、sessionStats(轮次/步骤/LLM 与工具耗时/延迟吞吐)、contextPressure+contextBreakdown(ContextMeter 圆环+明细)、todos(当前计划)、permissions、imageLimits、pendingInteraction(未决审批/问题)。
- 事件:assistant/chunk、assistant/message、user/message、turn/start、todo/write、compaction/start|end|summary、approval/resolved、command/run|done、llm/retry、llm/retry-started、agent/inbox、session/queue 快照(带 placement,含待处理 steering)。
- Slot:conversation.chat.node(节点注册表)、conversation.view(视图标签环,ui-trajectory 也注册)、conversation.composer(+.bar)、conversation.chat.assistant-actions、conversation.chat.turnTail、conversation.input.overlay|dock|plan|model、conversation.session.header.actions|utilities、conversation.details.tool、conversation.blocks(composer 禁用提示)。

### 1.3 UI 结构要点
- 会话壳三层:页头(标题+两列操作区)→ 滚动容器(无条件预留滚动条槽,保持输入卡片横向位置)→ sticky 编辑器栈(统计 dock + 输入区 dock + 输入栏)。
- 聊天流节点:user 气泡(复制/时钟,无分支无编辑);assistant 收尾消息带 IconActions 行(复制/时钟/分支,分支仅完整轮次末条可用);Think 行默认折叠(流式时单行滚动摘要,展开进页面流);压缩检查点折叠行(可展开,显示被替换数/token 数);重试行(倒计时/渐变/∞上限);turn-error 持久内联行;上下文注入/跨会话召回为默认折叠 DisclosureRow(内容区最大 141px 滚动);steering 气泡=用户样式气泡。
- 输入区:加号按钮=命令 launcher(只开 '/' trigger 的 command source,非附件);模型 seat;14px ContextMeter 圆环+点击弹出面板;PermissionSelect chip(下拉,danger-full-access 走 Modal 风险确认);发送/停止;繁忙 Enter 手势偏好(busyEnter: Queue/Steer);整队列插话手势(Cmd+Enter,placeholder 提示)。
- Dock:TodoDock(order 0,计划条,默认折叠,表头状态计数);QueueDock(order 20,单行预览,2+ 条折叠为 "<n> 条排队消息",展开限高 180px;行可编辑/删除/严格 steer;subagent 只读)。
- ApprovalPanel:未决审批时以琥珀色条接管整个 composer(理由+命令行+允许一次/拒绝)。
- 空状态:整张虚线卡片=Workspace picker 入口,textarea 只读;选中 Workspace 自动连/建空白会话。
- DetailsPanel:详情壳层(当前实现但无调用入口,应用内不可达)。

### 1.4 移动端注意点
- 三层叠放+sticky 编辑器栈:手机上软键盘会顶起输入栏,建议输入栏固定底部+系统键盘避让(viewInsets),统计 dock/Todo 折叠为可收起条。
- 大量 hover 交互(重试行展开、统计行 hover tooltip、IconActions、ContextMeter 明细)→ 触屏改为点击/长按展开,操作目标 ≥44px。
- Enter/Cmd+Enter/Shift+Enter 快捷键无意义:提供显式"发送"与"插话"按钮,回车键仅换行(或软键盘 action=send)。
- ContextMeter 弹出面板、权限 Modal、ApprovalPanel 在窄屏改底部 sheet/全屏;权限确认勾选流程保持。
- 队列行编辑/steer 小屏改全屏编辑页;Todo 列表展开保持。
- 需预研:session.readAttachment 的鉴权 URL 在移动端网络层如何携带凭证;imageLimits 预检(数量/单图字节/总字节)在手机相册多选时先于上传执行。

---

## 2. dsh-client-ui-tool(工具调用展示)

### 2.1 功能一句话总结
把消息流中的 tool-call 节点渲染为可读卡片:终端、read、diff、search、web、todo、question、Code Dispatch、skill 及 generic 兜底;支持递归 root/child 子调用树与详情面板;不配对事件、不重建 transcript。

### 2.2 消费的 RPC / 事件
- RPC:无。输入是运行时冻结的 call/result block 快照(含递归 subCalls);openFile/inspect 为宿主回调(openFile 相对会话 cwd 解析路径,展示代码不读会话服务)。
- 事件:todo/write(todo 行平行活跃数);conversation.chat.node 同名 key 分发;conversation.details.tool 详情席位;keyed slot tool.call.toolview(业务包按 wire 工具名注册原子视图)。
- 工具名归类:shell/pwsh、read、write/edit、grep/glob、web、todo、question、code dispatch、skill、generic;未知 intent/格式错误回退为压平结果文本。

### 2.3 UI 结构要点
- ToolCallTree:递归遍历 root 与任意深度 child,同一分发路径;包装层保留 data-chat-anchor-key="call:<id>"。
- ToolRow / GenericToolCard:状态色区分 运行/成功/失败/中断(仅来自冻结 slice)。
- 卡片上限(各自 Agent Note 定):终端卡(命令+退出码+截断输出)、diff 卡、read 卡(文件内容+截断)、search 卡(匹配列表)、web 卡(结果列表)、todo 卡(状态计数)、question 卡。
- ToolDetails:与行共用同一套纯 card model;Input/Output/Metadata 切换、Prev/Next 步进(桌面端详情面板当前也无入口,与 DetailsPanel 同样不可达)。

### 2.4 移动端注意点
- diff/read 等宽内容卡:必须横向滚动或收缩为"单行摘要+点击全屏查看";终端输出行加等宽字体+横向滚动,勿换行破坏对齐。
- 递归树缩进在窄屏限制深度(如 3 层后折叠为"N 个子调用"),或改用面包屑/上下级导航。
- 状态色要配图标/文字(色盲+触屏无 hover);todo 卡点击勾选目标放大。

---

## 3. dsh-client-ui-trajectory(轨迹视图)

### 3.1 功能一句话总结
按轮次组织的事件记录表(ledger):选择用户/助手/工具/嵌套子工具记录,在局部检查器中查看 token 用量、耗时、输入、输出、计时;顶部 Overview 时间条支持拖选区间过滤、滚轮缩放、右键平移;虚拟滚动+向前分页加载历史;以视图标签注册进会话视图环。

### 3.2 消费的 RPC / 事件
- RPC:session.getSnapshot、session.loadOlder(加载更早一页历史)。
- 事件(经 conversationEvents.register 各 Definition):turn/end、user/message、session-end、session/end-seed、compaction/start|end|summary;in-flight 部分由 partial/runningCalls 投影驱动;request 汇总读 RequestView/RequestInspectionSnapshot。
- 不读不写 Chat 会话快照;不提供 service;注册 conversation.view 标签页 + target 专属 Event Definition。

### 3.3 UI 结构要点
- 布局:Overview 时间条(sticky 于表上方)+ TrajectoryToolbar(actualDuration/actualTime 开关、全部折叠/展开、实时搜索)+ 三列 ledger 表(索引/事件/内容,粗线分隔轮次,行内紧凑 step 标记)+ 局部检查器(选中行右侧/下方)。
- 时间条:真实开始时间与耗时;助手条区分 TTFT 与解码时间,悬停 500ms 看精确时刻;拖选区间→过滤;滚轮缩放时间域;右键拖动平移;省略号控件加载更早前缀。
- 虚拟滚动:只挂载可见行+少量缓冲;仅含请求的分隔行并入下一虚拟项;向前补页保持行键/ARIA 索引;尾部跟随,上滚暂停跟随;加载行遮住真实记录直至定位完成。
- 压缩请求独立显示在 "Between turns" 区段;编号压缩留在所属轮次。
- composer 作为浮层置于全高表上方,纵向容器预留其实时高度。

### 3.4 移动端注意点
- 三列表格必变形:建议内容列占满,索引+事件徽标合并进行首,或卡片化(每记录=卡片,轮次=分组头)。
- 桌面指针手势全失效:拖选区间→"区间选择模式"按钮或双指滑选;滚轮缩放→双指捏合/缩放按钮;右键平移/清除→长按菜单;hover 时间详情→点击展开。
- Overview 时间条在窄屏压缩为纯时间轴(去掉行内标签),点击记录联动定位。
- 虚拟滚动+分页在移动端 OK,但"加载更早"按钮与"回到尾部"按钮要显式提供(FAB 风格)。

---

## 4. dsh-client-ui-message-feedback(消息反馈)

### 4.1 功能一句话总结
单条助手消息的 Like/Dislike + 可选备注,渲染在已定稿助手消息的 IconActions 条带内(复制与分支之间,order 10);每个 Session 一个 controller 支撑全部消息。

### 4.2 消费的 RPC / 事件
- RPC(ctx.remote.messageFeedback 命名空间):list({sessionId})、put({sessionId, messageId, rating, note?, ifVersion})、delete({sessionId, messageId, ifVersion});每次变更带最后一次观察的 version,Host 做 compare-and-set。
- 错误码:version-conflict(响应带权威条目直接对账)、note-too-large(maxNoteBytes=8192,Host 策略)、session-not-found。
- 事件:无实时帧(另一标签页的评分要等重连 resync 才可见);监听 connection/reset 触发 resync。

### 4.3 UI 结构要点
- 每 Turn 渲染一次操作栏(位于持有该 Turn IconActions 行的收尾助手消息上;中间步骤是工具行,无评分控件)。
- 控件:Like/Dislike 按钮对 + 备注输入;已评分再点=撤回;切换另一侧保留已有备注;单次 list 读取填充整段对话,读取延迟到首次 hover/focus。

### 4.4 移动端注意点
- hover 才出现的操作→触屏常显(不占空间的紧凑行内图标即可)。
- 备注输入在手机弹键盘,建议点击"备注"展开底部 sheet;保存失败(超长)给出产品文案+原因码。
- 控件极小:Like/Dislike 目标 ≥44px;防误触(两次点击间隔或动画反馈)。
- 无推送:手机上应提示"离线/重连后同步",或客户端自行轮询/合并。

---

## 5. dsh-client-ui-input-trigger(输入触发)

### 5.1 功能一句话总结
输入框 '/' 与 '@' 触发流水线:词边界+guard tier 检测、分组候选菜单、pick 路由到已注册 source(命令/引用);加号按钮作为 launcher 只开单个 source。

### 5.2 消费的 RPC / 事件
- RPC:无(纯浏览器呈现;pick 产出 CommandClaim/ReferenceInsert 数据,模型侧后果由宿主执行/随提示词发送)。
- 事件:无 wire 事件;slot conversation.input.overlay(列表类,会话 scope)承载 MenuView;ctx.inputTriggers 持有 source roster,sessionOf(actx) 解析逐会话 controller。
- 内核 API:detectTrigger、menuReduce/seedGroups/MENU_CLOSED、exactMatch;controller 暴露 track/arbitrate/onSpace/adjudicate/toggleSource;source 可选 subscribeLexicon 动态词表;空格/回车裁决按注册序轮询 matchSpace/matchEnter。
- 拾取路径三条:键入式 trigger(seed 全部 source)、程序化 launcher(seed 单个,带 launcher 快照)、候选逐 hit 拉取(generation 把关+AbortSignal 取代旧请求)。

### 5.3 UI 结构要点
- MenuView:浮层列表,锚定 composer;按 InputTriggerSource.order 分组排序(默认 0),组标题本地化;combobox 模式(焦点留 textarea,行 mousedown 完成 pick,aria-activedescendant 高亮)。
- 高度受限 composer 上方可用空间;指针落在菜单与 composer 卡片外即关闭;菜单关闭期间渲染 null。

### 5.4 移动端注意点
- 软键盘弹出时浮层菜单会顶起:建议改为输入框上沿紧贴的列表,或整屏底部 sheet(分组标题+滚动);高度动态避让键盘。
- mousedown 完成 pick→改 tap 事件;高亮用触摸态。
- 手机上 '/' '@' 键位切换成本高:提供可点按的触发按钮(如加号=命令、@ 按钮=引用)作为 launcher 路径,与桌面键入等价。
- 逐 hit 异步拉取在弱网下:保留加载态与失败静默降级(console 记录),菜单不要闪跳。

---

## 6. dsh-client-ui-attachment(附件原子组件)

### 6.1 功能一句话总结
纯 React 附件原子组件(零 cordis):草稿图片栏(AttachmentRail)、聊天历史图片画廊(MessageImage/ImageGallery)、原图灯箱(ImageLightbox)、整页拖放遮罩(DropOverlay);仅图片,文案由持有方注入 label props。

### 6.2 消费的 RPC / 事件
- RPC:无直接调用;ImageLoader 由持有方(ui-conversation)提供,加载会话授权 URL(底层对应 session.readAttachment 类能力)。
- 事件:无 wire 事件;仅 DOM 事件(dragenter/leave 由持有方 document 级监听计数、滚轮事件消费做横向步进)。
- 持有方预检:数量/单图字节/总字节(host imageLimits 投影),超限整批拒收+点名上限横幅;宿主侧拒绝映射为 attachment-error 原因文案(image-labels.ts)。

### 6.3 UI 结构要点
- AttachmentRail:64px(16px 圆角)缩略图横排,隐藏滚动条,两端圆形箭头翻页(一次一个视口,下限 200px,平滑滚动);仅横向滚动(纵向滚轮转横向步进≤60px);删除按钮右上角(hover/聚焦显示,触屏常显);新增滚到栏尾。
- MessageImage:single 长边 240px,宽高比钳 [0.25,4] object-fit cover(高图锚顶/宽图锚左),不放大超原尺寸;tile=64px 方块;ImageGallery 弹性换行分组(用户消息 end 对齐/助手 start);加载失败显式重试按钮。
- ImageLightbox:文档级模态,遮罩+模糊(独立图层),Esc/遮罩/关闭按钮关闭,卸载归还焦点;无缩放无下载。
- DropOverlay:全视口邀请层(插画+标题+上限说明),不接收指针事件,body portal 渲染。

### 6.4 移动端注意点
- 拖放遮罩在手机上无意义(无文件拖拽):降级为系统相册/文件选择器入口;"上限说明"改为选择器内提示。
- 灯箱:加双指缩放、捏合、下滑关闭、滑动切换;补"保存到相册/分享"入口(桌面版也没有,是加分项)。
- 箭头翻页在触屏改滑动滚动+页码指示点;删除按钮触屏常显(已设计)。
- 会话授权 URL 鉴权(header/cookie)在移动端 HTTP 层需显式处理;图片内存缓存与缩略图分级(64px tile/240px single)对手机流量与内存重要。
- 非图片附件(文件卡/上传进度)桌面版未做,移动端若需可从文件选择器先行补齐。

---

## 附:跨包移动端通用结论
1. 六个包全部是"零模型、零 KV"的纯渲染层,Flutter 复刻时核心是 UI+事件流+轻量 RPC,风险集中在交互形态而非数据链路。
2. hover/拖拽/滚轮/右键/快捷键五类桌面交互需要逐项映射:点击、长按、双指手势、底部 sheet、显式按钮。
3. 宽内容(轨迹三列表、diff/终端卡)统一走"横向滚动或全屏查看"两级降级;列表虚拟化(轨迹)在 Flutter 用 sliver/ListView.builder 等价实现。
4. 编辑器堆叠层(统计 dock/Todo/Queue/审批接管)在手机上折叠为 tab 或下拉,保证软键盘打开时输入区仍可达。
