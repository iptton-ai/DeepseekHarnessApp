# 功能审计:sidebar / layout 相关 client-ui 包(Flutter 复刻输入)

审计对象:8 个 @deepseek-ai/dsh client-ui 包(源码为编译产物 .js/.d.ts,包内无视觉稿)。
审计依据:各包 README.zh.md + lib/ 类型声明与调用点。RPC 面以包内可见的服务方法/字面量 method 为准;穿过 runtime 服务层的 wire 名标注"未查明"。

---

## 1. dsh-client-ui-sidebar(侧边栏外壳)

1. **功能一句话**:左侧栏的"壳"——品牌字标、New Session 按钮、折叠控件、可滚动内容区 seat、底部固定 Settings seat;Workspace/Session 浏览器本体由 ui-workspace 注入,折叠后变 56px 图标轨道。
2. **RPC/事件**:
   - 写入:`ctx.workspaces.startSession(workspaceId?)`(New Session:复用或新建该 workspace 的 blank session;无参时按 当前 session workspace → 最近活跃 → 空白 New Session 页 继承);`ctx.layout.toggleSidebar()`。
   - 读取:PropsRuntime<'sidebar'> 全局 seat 含 `useSessions`/`useWorkspaces` 钩子;layout owner share 只给 `collapsed`/`width`。无自有 store,不消费 job 事件。
3. **UI 结构要点**:字标行 + New Session + 折叠控件(顶部 4 个控件);内容区整体为 `sidebar.workspaces` 单槽(区头/搜索/列表全是占用方画的);底部 `sidebar.settings` 固定 seat + `sidebar.footer.action` 列表槽。折叠动画:展开内容冻结当前宽度 150ms 淡出,4 控件 150ms 淡入 + 49px 左移进入 56px 轨道(每 36px 控件盒到轨道左 10px 内边距);Settings 只淡入不位移;初始即收起时静态渲染轨道。滚动条是指针可供性:指针不在栏内时把 `--dsh-scrollbar-thumb` 重绑为 transparent,离开后滑块保留 2s。
4. **移动端注意**:56px 轨道 + 抽屉是天然的手机形态;建议窄屏(<1024,与 web 的 SIDEBAR_AUTO_COLLAPSE 对齐)直接收成抽屉/底部导航,New Session 升级为 FAB 或底部栏主按钮;`sidebar.settings`/`sidebar.footer.action` 在抽屉展开态内联展示;滚动条隐藏逻辑在手机(overlay scrollbar)可整体省略。

## 2. dsh-client-ui-workspace(Workspace/Session 浏览器与选择器)

1. **功能一句话**:共享的会话/工作区浏览器 + 选择器——分组/扁平两种列表、Workspace 增删改排序、Session 重命名/fork/归档、拖拽排序、折叠搜索(标题 + 对话内容全文检索)、行状态点(等待审批/计划待审/等待回答、运行中、完成未读)、悬浮卡片复制路径/标题。
2. **RPC/事件**(经注入面调用,可见字面量/服务方法):
   - 服务方法:`ctx.workspaces.startSession(workspaceId?)`、`create({path})`、`rename(id,title)`、`delete(id)`、`insertBefore(id,beforeId?)`(注册表排序)、`archiveSession(sessionId)`、`insertSessionBefore(workspaceId,sessionId,beforeSessionId?)`、`pickDirectory()`(native 流)、`listDirectory(path?,signal)`、`createDirectory(path,name)`(browse 流);`ctx.sessions.open(id)`、`fork({sessionId,increaseTitle:true})`、`binding(id).session.rename(title)`(即 wire 方法 session.rename)、`searchSessions(query,AbortSignal)`(内容全文检索,250ms 防抖,中止前请求,上限 20 条 + hasMore 提示收窄;wire 名未查明)。
   - 读取:标准钩子 `useSessions`(session 列表快照,含 running/pendingInteraction/completed/blank/updatedAt)、`useWorkspaces`(workspace 列表,含 sessionIds/path/title)、`useSession`;归档集合经 useWorkspaces 侧同步。底层 wire 订阅(session.list 等)在 runtime,未查明。
   - 本地 store:WorkspaceViewStore(groupBy: workspace|flat;orderBy: manual|updated;groupExpansion;sessionOrderByAccount)持久化,跨重载保留。
3. **UI 结构要点**:
   - 列表:Workspace 分组头行(文件夹+标题,悬停显示 chevron/新建/菜单,含 Ungrouped 桶)→ 组内 Session 行(34px:状态点+标题+相对时间+省略号菜单);默认每组显示 5 条,"展开其余"临时展开;扁平模式为单列表(无父级层级,省略空状态槽)。"最近更新"模式每次 prompt/steer 把对应会话置顶一次;手动排序模式禁置顶;拖拽即编辑顺序(真实 workspace 拖拽同步 Host 记账,单列表/扁平仅浏览器本地)。
   - 搜索:区头折叠按钮 → 展开为输入框;非空查询以扁平结果列表替换浏览模式,结果行含 snippet 摘要;打开会话不清查询、不跳事件。
   - 弹层:Session 重命名对话框(预填标题、host 可能以 title-invalid 拒绝、确认不改名=钉住自动标题)、Workspace 重命名/删除确认框(说明保留边界、防重复提交)、归档无确认直接提交、添加工作区菜单(仅当 directory-flow 槽被占用才显示"添加工作区…")+ 可重试错误对话框(重新选择)。fork 在最后已完成轮次处复制并递增标题((1) 或括号编号递增),子会话与源会话同组同级。
   - 悬浮卡片:Workspace 卡复制完整路径、Session 卡复制完整标题;pendingInteraction 状态点(琥珀)优先于运行指示(蓝),再优先于完成提醒(绿);subagent 后代运行状态聚合为运行计数。
4. **移动端注意**:
   - 34px 行 → ≥44px 触控目标;悬停动作(chevron/菜单/卡片)改为行内常驻菜单按钮或长按;悬浮卡片复制 → 行菜单"复制路径/标题"。
   - 拖拽排序 → 长按拖拽或右侧拖拽手柄(建议后者,移动端拖拽误触率高)。
   - 每组 5 条默认折叠在手机上可放宽或默认全展开;折叠/展开需要明确的 chevron 大热区。
   - 搜索框展开 + 结果列表(20 条)适合全屏覆盖页或 bottom sheet;相对时间标签保留。
   - 对话框宽度需适配窄屏(居中 modal → 底部弹出式)。

## 3. dsh-client-ui-directory-picker-browse(应用内目录浏览对话框)

1. **功能一句话**:应用内"选择工作区目录"对话框(Miller 分栏浏览),支持面包屑/可编辑路径跳转、新建文件夹、隐藏条目开关、末栏前缀过滤;不依赖本地 OS 选择框,远程部署也可用。
2. **RPC/事件**:经 `ctx.workspaces` 驱动 wire 原语 `host.listDirectory(path?,signal)`(AbortSignal 中止被取代的扫描,缺省=Host 家目录,返回 DirectoryListing)与 `host.createDirectory(path,name)`;浏览失败(不可读/创建冲突)留在对话框内提示区,不驱动 owner 的 onError 分支;确认=选中路径,关闭=取消。
3. **UI 结构要点**:Modal 680×500(矮/窄视口限尺寸);头部=标题+选中路径面包屑+可点击编辑路径区;未选中时单栏层级,选中后行内均分为"层级 | 选中文件夹子项"两栏;导航是选择锚定(扫描中渲染旧视图、两段导航同帧落地,回退不闪中间帧);页脚=新建文件夹(嵌套创建对话框,目标为选中文件夹并自动选中新建项)+ 打开(无选中时回落当前层级);隐藏条目默认过滤,页脚开关揭开(纯客户端过滤);无搜索/多选/重命名/删除。
4. **移动端注意**:双栏 Miller 在手机上不可用——降级为单列逐级下钻(点文件夹进入,面包屑返回),或全屏 bottom sheet + 单栏;路径编辑/前缀过滤保留但改为显式输入条;新建文件夹对话框全屏化;隐藏条目开关放工具栏而非页脚。680×500 上限在手机上恒被触发,直接按全屏设计。

## 4. dsh-client-ui-directory-picker-native(原生目录选择,无渲染)

1. **功能一句话**:无 UI 的占位者——每次收到 open 请求就调起 Host 的操作系统目录选择框,经 owner 会话回报恰好一个结果(选中路径/取消/失败);仅限本地 Host 载体(远程浏览器不可用,需换 browse 组合)。
2. **RPC/事件**:`ctx.workspaces.pickDirectory()`(wire: host.pickDirectory,返回 Promise<string|null>);无渲染、无订阅。
3. **UI 结构要点**:零 UI(系统对话框画在 Host 显示器上);每 open 上升沿只武装一次(重渲染/busy 不再开第二个框),owner 撤回 open 重新武装;结果经 ref 回报到最新处理器;卸载(HMR)丢弃结果,wire 无按请求中止通道,已打开的选择框无法关闭。
4. **移动端注意**:对 Flutter 手机端反而是好消息——原生选择框语义天然映射到平台目录选择(file_picker: Android SAF / iOS UIDocumentPicker),可作为"本地宿主在手机上"的默认路径;但 dsh host 在远端时此包无意义,必须提供 browse 兜底(能力探测 + 回退,与 web 的 -browse 组合同构);"无法取消已打开选择框"在手机上是系统行为,可接受;错误经 owner 可重试对话框呈现。

## 5. dsh-client-ui-layout(三栏 AppFrame 布局外壳)

1. **功能一句话**:三栏外壳(侧边栏 | 会话 | 详情)带拖拽手柄与让步链、面板几何 store、`ctx.layout` 面板动作服务、以及主题 DOM 呈现器(把 ctx.theme 快照投影到 document)。
2. **RPC/事件**:零 RPC、零 job 事件;消费 `ctx.theme` 快照与 `theme/change` 事件(主题呈现器);对外暴露 `ctx.layout.toggleSidebar()/openDetails()/closeDetails()`(供 sidebar/ui-conversation 调用)。布局 store 纯瞬时,不读写 localStorage。
3. **UI 结构要点**:
   - 常量:SIDEBAR_DEFAULT 280 / MIN 264 / MAX 420 / COLLAPSED 56(rail)/ AUTO_COLLAPSE 1024;DETAILS_DEFAULT 360 / MIN 300 / MAX 520;CENTER_MIN 640。
   - 让步链:优先保 center ≥640 → 先压缩详情栏 → 详情栏自动关闭(推导零宽,不改宽度偏好,窗口变宽自动恢复);侧边栏从不让步(仅 <1024 自动收成 rail,手动切换可覆盖展开压中心);center 兜底吸收亏空。
   - 插槽:`root` 内声明 `sidebar`(单,owner: collapsed/width)、`conversation`(单,session-maybe,无 owner props)、`details`(单,session 域,无 owner props)、`shell.overlay`(列表,全屏浮动层,点击穿透);SessionProvider 保持当前会话;空白/hero 态详情栏渲染零宽但不动偏好;跨会话保留最后一个非空白会话 id,切会话先关详情栏。
   - 拖拽:侧边栏边界为不可见命中条带,详情栏边界保留浮动胶囊;关闭的侧边栏保留 56px 控制栏,详情栏关到零宽(不卸载)。
4. **移动端注意**:三栏结构在手机上整体不可用——Flutter 侧建议:窄屏(<1024)侧边栏=抽屉(rail 语义保留为抽屉收起态图标),详情栏=bottom sheet 或 push 二级页,CENTER_MIN/让步链全部失效(中心列即全屏);`shell.overlay` 映射为全局 Overlay/Stack;拖拽手柄在手机上取消,改由抽屉滑出手势 + 详情 sheet 拖拽条;侧边栏 auto-collapse 断点 1024 与 web 保持一致;瞬时 store(不持久化宽度)在移动端同样适用,或按设备记忆。

## 6. dsh-client-ui-slots(Slot 注册表纯核心)

1. **功能一句话**:对用户不可见——slot 系统类型/机制核心:SlotMap 声明合并、`register()` 组合 API、四 share props(运行时/子槽渲染/store/业务注入)、store seat、chain 槽选择器、renderer 安装约定;零运行时依赖(仅 React 类型,不依赖 Cordis)。
2. **RPC/事件**:无(纯 UI 接线;无任何方法名/事件名/模型请求)。
3. **UI 结构要点**:无 UI。机制要点:kind=single|list|keyed|chain,scope=root|session-maybe|session;声明=渲染授权=运行时规范;chain 槽按 priority 升序跑 select,首个非 null 选中并注入 matched,全 null 用 owner fallback(overlay 选项保挂载);store 为 defineStore 规范(init/actions)+ 引擎实例(getSnapshot/subscribe,React 钩子只在渲染侧);注册校验(未声明槽/重复子项/双 scope 共享 handle/chain 缺 select 均在 register 时抛错);disposer 递归清理子槽;declaration epoch 供 slots.inject 用。
4. **移动端注意**:N/A(架构层)。Flutter 复刻建议:用等价注册表(如 InheritedWidget + 声明式 slot 注册)保留插件可组合性,但不必 1:1 复刻类型体操;session-maybe/session scope 对应 Flutter 的 session 级 InheritedScope;chain 槽对应"多提供方选一"的装饰器模式。

## 7. dsh-client-ui-primitives(纯原子组件库)

1. **功能一句话**:零 Cordis 的 React 原子组件,覆盖 dsh web 全部"卡片/浮层/排版"基础件:状态点、手风琴行、按钮/Pill/输入/菜单/Modal、Toast 横幅、首次使用引导、风险确认、连接横幅、Logo/字标、Tooltip、悬浮卡片(可点击复制)、只读 JsonTree、以及 Markdown/终端/Read/Diff/搜索/Web 检索 六类工具结果卡片 + 图标集 + 剪贴板工具。
2. **RPC/事件**:无(纯展示;文案经 label props 由持有方本地化,默认值为中文)。
3. **UI 结构要点**(按组件):
   - 状态行:StateDot(done/warning/ongoing/error,无 Active 变体);DisclosureRow(可展开行)。
   - 浮层:Modal;HoverCard(body portal 预览 + 指针离开宽限期 + 可选点击复制,复制成功临时换 copiedLabel);Tooltip;Toast(顶部横幅,3s 停留+1s 淡出,role=alert,pointer-events:none,距顶 120px,可跟随 anchor 居中,重复消息需重挂载);OnboardingSurface(portal 遮罩 + #root inert);RiskConfirmation;ConnectionBanner。
   - Markdown 家族:MarkdownText(GFM + KaTeX 数学 $..$/$$..$$,CJK 友好粗体闭合,安全外链/图片,增量解析——除末两块外冻结缓存,fileMentions 可点击文件提及);MessageText(用户内容字面文本);JsonBlock;CodeBlock(shiki 高亮 + 语言横幅 + 复制)。
   - 工具卡片(几何同构:maxLines 默认 16,头尾切片 + 展开按钮,white-space: pre 横滚不软换行):TerminalBlock(命令多行提示 + 缩短 cwd 标签仅首行 + 输出 + 退出码/信号状态胶囊 + 单枚运行状态点 + ANSI 列缓冲解析 + 支持 8 列制表/CJK 双宽);ReadBlock(带文件行号 + 语法高亮 + showing N of M);DiffBlock(每文件路径头 + 删除行在上新增行在下 + gap + 暗色页脚 └ +A -R · N file(s) + 带前缀复制);SearchBlock(kind 判别 grep 文件组/glob 路径列表,可折叠,截断 banner 显示 X/共 N,复制写入完整结果);WebBlock(kind 判别 search:有序引用列表 + 可选回答 + 定高 320px 内滚 + fetch 摘要;空态提示)。
   - 其他:JsonTree(只读检查器);useAnchoredMaxHeight(底部锚定浮层高度收敛);writeClipboard;icon 集(ic_ds_*:new chat/search/globe/settings/panel/plus/branch/chevron/copy/refresh/like/dislike/share/edit/think/trash/warning/send/stop/paperclip/loading/download/play/pause/fullscreen/code/folder/light/dark/follow-system/archive 等)。
4. **移动端注意**:
   - HoverCard/Tooltip → 长按或点击触发,禁用 hover;Menu → 窄屏改 bottom sheet;Modal → 底部弹出式 + 安全区。
   - 触控目标:所有可点元素 ≥44×44;行内操作(复制/展开/折叠)避免过小。
   - 代码/终端/Read/Diff 卡片:保留单行省略 + 横滚是正确策略(手机上横滚手势自然);展开/收起按钮加大;ANSI/高亮渲染在 Flutter 用等价方案(如 flutter_highlight + 自写 ANSI 解析,注意 CJK 双宽列对齐)。
   - Markdown:表格需横滚或卡片化;KaTeX → flutter_math_fork;图片安全加载;增量解析对移动端低算力更必要(节流渲染)。
   - Toast 顶部 120px + anchor 跟随在手机上简化为顶部安全区下方;WebBlock 320px 定高滚动可保留。

## 8. dsh-client-ui-theme(主题系统)

1. **功能一句话**:主题运行时——light/dark/system 三态偏好(持久化到 Host settings)、不可变 ThemeSnapshot、`theme/change` 事件、第三方主题注册与 alias token 覆盖层、Appearance 设置行,以及 --dsw-* token 基础样式表(静态尺度 + 别名语义层)+ 滚动条主题化;服务本身不碰 DOM(由 ui-layout 呈现器投影)。
2. **RPC/事件**:
   - 设置:Host settings 命名空间 ui-theme、字段 preference(light/dark/system,默认 system);settings.get 读取,写入经 Host settings API(本地默认存 $DSH_HOME/settings.yaml);namespace revision 串行写入,最新写被拒则重载持久化值;远程浏览器无法访问特权 settings API,选择仅进程内。
   - 事件:theme/change(emit,载荷 ThemeSnapshot;偏好切换/注册表更新/OS 配色变化时触发);消费 prefers-color-scheme 媒体查询(system 解析)。
   - 引导:含 HTTP 服务器的组合在 <body> 后注入同步引导代码,index 响应内嵌 ui-theme.preference,避免首帧闪烁。
3. **UI 结构要点**:Appearance 行注册进 settings General 的 settings.general.item 槽(单行三态选择 light/dark/system);无其他 UI。样式表五张:base/design-platform/scrollbar/gradient-shadow-text/shiki;scrollbar.css 是 --dsw-alias-scrollbar-* 唯一消费方;两条互斥渲染路径(标准 scrollbar-color/width vs WebKit 伪元素);--dsh-scrollbar-width 镜像滚动条布局宽度供对齐。
4. **移动端注意**:三态切换在手机上照搬即可(推荐默认 system,监听 MediaQuery.platformBrightness);Appearance 行进设置页;桌面滚动条主题化在手机(overlay scrollbar)基本无感,可省略;theme-color 元数据 → Flutter 用 SystemChrome.setSystemUIOverlayStyle / AnnotatedRegion;token 体系复刻为 Flutter ThemeData + 自定义 Token 类(light/dark 双模式 + 覆盖层按注册顺序折叠);OS 深色切换需实时响应(复用 prefers-color-scheme 的监听语义)。

---

## 跨包移动端设计汇总建议(供 Flutter 侧落地)

- **导航**:窄屏(<1024)整体采用 抽屉(侧边栏) + 全屏会话 + 详情 bottom sheet;宽度偏好/让步链/拖拽手柄全部取消,由布局断点替代(与 web 的 SIDEBAR_AUTO_COLLAPSE=1024 对齐)。
- **交互降级**:hover → tap/长按;悬浮卡片 → 行菜单复制;拖拽排序 → 手柄;Menu → bottom sheet;Modal → 底部弹出。
- **能力探测**:目录选择原生(browse/native)二选一,手机端优先平台选择器(file_picker),远端 host 自动回退 browse。
- **性能**:Markdown 增量解析、列表虚拟化(会话行多时)、搜索 250ms 防抖 + 中止,移动端直接沿用。
- **可访问性**:状态点必须配视觉隐藏文本(等待审批/运行中/完成),颜色不唯一表意;触控目标 ≥44px;prefers-reduced-motion 等价物(disableAnimations)。
