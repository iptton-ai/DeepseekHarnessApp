# 设置系统(system settings)功能审计

> 审计对象:9 个 @deepseek-ai/dsh client-ui 包(官方 dsh web GUI 的浏览器侧插件)。
> 用途:Flutter 客户端功能复刻清单。所有包为浏览器插件(React/cordis),经 api-remotes RPC 与 Host 通信;settings/credentials RPC 仅 loopback 可用,远程浏览器降级为进程内 memory 持久化或直接不可用——移动端必须处理此约束。

---

## 1. dsh-client-ui-settings(设置领域底座)

- **一句话**:不渲染任何 UI,仅提供 ctx.settingsScope 服务(每条偏好设置绑定自己的持久化 namespace 分区的宿主传输层)并声明设置区全部 slot 类型(settings.trigger/header/action/close/section/plugins.tab/onboarding)。Flutter 端无需复刻 UI,但必须复刻其读改写语义:快照 store + 单字段写入 + revision 乐观锁 + 失效重读。
- **RPC/事件**:settings.describe(读整个 namespace)、settings.mutate(路径 op:set/unset,带 expectedRevision);订阅转发事件 settings/document-updated(按 namespace 过滤)、connection/reset。写入被拒/失败后自动重读,过期读不覆盖新写。
- **UI 结构**:无。
- **移动端注意**:无 UI。但复刻时须在 Flutter 侧实现等价"namespace scope":每行配置持有 {snapshot, set(field,value), load()} 三件套;写入只允许单字段 op(无事务,双字段变更产生两次 revision)。

## 2. dsh-client-ui-settings-general(设置外壳)

- **一句话**:设置面板的外壳——侧栏触发按钮、模态面板(chrome 标题栏/关闭)、左侧分区导航、首次使用引导流程(onboarding 逐步骤挂载)、「通用」分区容器、"打开配置文件"操作。注册 settings 字典与 sidebar.settings 占位。
- **RPC/事件**:settings.describe(探测提供方 hasDocument 能力)、settings.openDocument(loopback 仅限,无路径参数;Host 解析路径→缺失则创建→交原生编辑器:macOS 用 open -t、Linux/Windows 桌面关联、WSL 经 wslpath 转换)。无事件订阅,仅 connection/reset 重查。读写 ui-onboarding.welcomeNoticeVersion(经既有 settings 边界,供 models 包欢迎步骤用)。
- **UI 结构**:模态面板 = 左侧导航列表(由 settings.section slot 账本投影,label 可随 locale 变)+ 右侧单页内容区 + 标题栏(trigger/header/close/action 四个 slot)。onboarding 每次只挂载一个步骤,步骤自持弹窗框架 + 应用根节点 inert。
- **移动端注意**:桌面是"侧栏导航 + 内容区"两栏模态。手机上应改为全屏页面:面板铺满屏幕,导航改为顶部 tab 条或可滑出的抽屉/分段控制器;onboarding 弹窗在手机上必须全屏化,保留步骤间 ownership 移交(complete()/openSection(id))语义。"打开配置文件"在移动端无原生编辑器可交,建议隐藏或改为"复制路径"。

## 3. dsh-client-ui-settings-models(模型设置与引导)

- **一句话**:「模型」分区页 + 两个首次使用弹窗(版本化内测声明、DeepSeek 官方凭据步骤)。提供方行列表,一次只展开一张编辑卡片:API 密钥(只写)、baseURL、模型目录(DeepSeek 模型 id/name/contextWindow/maxTokens,pi-ai 另加 displayName/api 协议);「获取可用模型」(按当前表单值询问,回选择框);「添加自定义提供方」(仅 pi-ai 路由,门控 Provider ID/端点/协议/至少一个模型);删除提供方(需确认,顺带清派生凭据)。
- **RPC/事件**:llm.providers(可配置提供方目录+路由存活)、settings.describe、credentials.describe(configured/source/writable 徽标,不含值)、settings.mutate(每字段一条路径 op,带 revision)、credentials.set/credentials.unset(只写密钥,派生存 <ROUTE>_API_KEY)、llm.discoverModels(带未保存的端点/密钥)。订阅:settings/document-updated、credentials/updated、llm/adapters-updated、connection/reset。读写 ui-onboarding.welcomeNoticeVersion。
- **UI 结构**:页面=提供方行列表(行头=名称+状态点:绿实心=密钥已配置,红实心=引用缺失,无引用/无法判定=无点;「自定义」标签)+ 一次一张展开编辑卡片;首次运行姿态下整分节无密钥的提供方直接渲染为展开设置卡。新建=带休眠目录提供方选择框的卡片。卡片内:主字段=单个 API 密钥输入框 + 收起的「自定义设置」折叠区。模型行:id+显示名,容量(上下文/输出,支持 256K/1M 后缀)收在行内折叠区,右侧展开/删除两个无文字操作。DeepSeek 模型列表按值整体替换(首次编辑将继承数组具化到用户层)。
- **移动端注意**:桌面卡片表单在窄屏会挤爆。建议:提供方行改为全宽列表卡;编辑卡片全屏推入(Navigator push)而非就地展开;API 密钥输入框移动端无"粘贴环境变量"场景但保留粘贴校验;容量 K/M 后缀输入在手机上易错,建议数字键盘+后缀分段选择;模型列表的行内折叠区改抽屉或二级页;删除确认对话框移动端需可滚动。

## 4. dsh-client-ui-settings-plugins(插件配置区)

- **一句话**:「插件」设置分区(标题+紧凑标签栏,settings.plugins.tab 贡献多页)+ 本包自带的「插件配置」标签页:为每个配置归用户所有的 Host 插件渲染可展开卡片,就地展开手写控件,每字段标注是否被用户覆盖,可重置回部署组装值。首批三卡:bash(shell 执行器)、agent-loop(工具调用并行度)、web-search-deepseek(搜索提供方)。
- **RPC/事件**:写入经客户端 settings scope(即 settings.describe/settings.mutate,revision 栅栏);secret 字段走 credentials.describe/credentials.set(初始为空,只报是否已配置)。订阅 credentials/updated(关注的引用变更时重读)。卡片暂存草稿,只有保存才写;「放弃修改」丢草稿;保存后回读分节验证落盘。
- **UI 结构**:标签栏(有序)+ 卡片列表。卡片头=插件名(上)+管辖说明(下)纵向堆叠;展开=字段表单(文本输入/开关/下拉),字段行标注"用户已覆盖";secret 控件为空只显示"已配置"徽标;有未保存修改的卡片收起时标题带标记;空态计数已注册卡片数。
- **移动端注意**:标签栏在窄屏可横滑(或底部 tab);卡片就地展开在手机上仍可行(单列),但字段表单建议改为整卡全屏编辑页 + 底部"保存/放弃"动作条;多字段长表单需滚动;"已覆盖"标记移动端可弱化为字段标签旁的小图标。

## 5. dsh-client-ui-settings-plugin-inventory(插件清单)

- **一句话**:设置里只读的「插件列表」标签页:展示 Host 当前 Loader 插件清单(可搜索、双列紧凑折叠卡片)。首次选中该标签页才懒加载,不订阅任何变化(切换标签保留快照,重开设置取新快照)。
- **RPC/事件**:懒调用 ctx.remote.pluginInventory.list()(api-remotes 生成的 Remote 面,返回 PluginInventorySnapshot)。无事件订阅;读取失败可重试,不暴露传输细节。
- **UI 结构**:搜索框 + 可搜索双列网格的折叠卡片。收起卡:标题=模块短名 + 启停状态小标签 + (启用条目)根 fiber 状态彩色圆点;展开卡:Loader 树条目 id(直接展示,无重复字段标题)+ 有效配置状态 +(启用) Cordis 状态,停用条目省略"未挂载"。条目 id 同时是 key/展开标识/详情值/搜索目标。状态:加载/空/无匹配/失败。
- **移动端注意**:双列网格在手机上必须降级为单列列表,否则卡片过窄;搜索框置顶常驻;展开内容单列展示即可;状态圆点+小标签在窄屏可合并为单个状态徽章。

## 6. dsh-client-ui-permission-presets(权限预设)

- **一句话**:两个权限界面——「通用」设置里的默认权限行(影响之后创建的会话)与 composer 的 /permission popupSelect 装饰(切换当前会话)。Full access 必须显式确认风险才写入。
- **RPC/事件**:settings.describe + settings.mutate(path=defaultPreset,带 revision);选项枚举从 host 的 defaultPreset schema 动态读。订阅 settings/document-updated、connection/reset。命令 /permission <preset>(经 commandUi,host 命令本体保留斜杠菜单行/带参路径/生命周期记账,装饰仅替换裸调用)。当前会话选项与 active 标记读会话 permissions 投影(与 composer chip 同一读源写路径)。模型侧旋钮事件:permission/preset、sandbox/mode、approval/policy。
- **UI 结构**:设置行=下拉选择器(选项来自 schema enum,danger-full-access 选中时弹确认);/permission 装饰=扁平预设列表弹层(当前值标 active,kebab-case → Title Case:workspace-write→Workspace Write)。无权限组合时两者都不显示。
- **移动端注意**:设置行下拉在移动端建议用底部 action sheet(原生 picker);Full access 确认对话框必须保留且不可跳过(安全关键);/permission 弹层在手机上全屏化或底部弹层,Title Case 标签保持不变。

## 7. dsh-client-ui-model-selection(模型选择)

- **一句话**:模型选择插件——两个入口共用一份会话级目录:/model popupSelect 命令与 composer 的模型座(conversation.input.model slot)。紧凑触发打开两级 Model/Effort 菜单:模型按提供方分组,所选模型提供其适配器公布的推理强度(名称/说明/默认值);/model 应用默认档位,composer 可选任一档位。
- **RPC/事件**:session.models(加载建议目录:current/routable/groups/failures)、session.selectModel(提交完整 ModelSelection{provider,model,reasoning})。订阅 llm/adapters-updated、settings/document-updated、connection/reset(重置丢弃常驻目录并重拉)。routable=false 时经 conversation.blocks 注册 composer 阻塞块(输入框停用),null 不阻断。已寻址 subagent 会话不公开任一入口。
- **UI 结构**:目录=两级菜单(Group→Model→Effort);Host 报告的 selection 是唯一事实,目录行缺席时触发器显示 "Select model" 提示、不合成陈旧行;提供方元数据获取失败内联列出(不可选失败行);选择失败保留先前选择。代次计数器防旧响应覆盖。
- **移动端注意**:两级/三级级联菜单在手机上改全屏选择页(提供方分组列表 → 模型列表 → 推理强度列表,或单页分段),避免 hover 级联;Effort 仅在选中已公布模型后显示,保持该顺序;composer 座在手机键盘弹出时注意菜单不遮挡输入区。

## 8. dsh-client-ui-jobs(后台任务列表)

- **一句话**:会话头部的一个后台任务触发器+弹层列表:列出当前会话可见的 ctx.jobs 记录(只读)。无任务时完全不渲染;角标=running+stopping 计数,为零省略。
- **RPC/事件**:不发任何 RPC,数据完全来自 runtime 从 session/jobs 帧折叠出的 jobsBySession 镜像。无状态(除弹层开合)。Escape/外部点击关闭。
- **UI 结构**:触发器(会话 header 内)+ popover 弹层。扁平列表:活跃行在前(startedAt 升序),终态行在后(finishedAt 降序),毫秒并列按启动顺序;行=生产者 kind + label + 状态标记 + detail(有则取代状态词)+ 已耗时(活跃每秒走表,finishedAt 冻结,>1h 停小时);终态行弱化保留(失败 detail 是唯一可读处)。
- **移动端注意**:popover 在手机上改底部抽屉/半屏列表,触发器可放会话页 AppBar 动作区;行内横向信息(kind/label/状态/耗时)在窄屏建议两行布局(上=label+状态徽章,下=kind+耗时);无任务时不渲染触发器的规则保持不变,避免手机屏幕被无意义控件占用。

## 9. dsh-client-ui-deliverables(产出文件)

- **一句话**:每轮完成的产出文件行 + 正文内联文件引用转链接。ProducedFiles 行渲染在收尾消息与 IconActions 之间:低调标签 + 单行文件 lane(至多 6 个 chip,剩余计 "+N 个文件");隐藏文件时第二行「在文件夹中显示」(仅 loopback 且 canOpenPath)。
- **RPC/事件**:无 RPC。浏览器侧经属主 openFile(chat 视图按会话 cwd 解析相对路径)打开文件;chatFileMentions 服务供 chat 视图查询正文提及(精确路径或唯一 basename 才可点击,两路径同 basename 保持不可点)。Node 侧注册静态系统提示词 ui:deliverable-file-references(要求模型用 Markdown 行内代码点名主要文件,顺序 190,可复用 KV 前缀)。数据源=修改工具调用附带的 locations(按渲染意图识别:diff 卡片或 kind=edit 的通用卡片),非收尾正文;同路径一轮首见一次。
- **UI 结构**:单行 lane 按测量宽度取最大前缀(fitProducedFiles:可用宽/gap/chip 宽/精确余数宽),剩余计数恒可见、不换行不横向滚动;chip=文件名文本、完整路径作 title;提及链接保持代码标签、链接蓝+悬停下划线。
- **移动端注意**:单行 lane 宽度测量算法在手机可直接复用(本身就是响应式),但 chip 在窄屏过密,建议保证触控目标最小尺寸;+N 个文件 余数文案保持;「在文件夹中显示」在移动端无桌面文件夹语义——隐藏或改为"分享/打开所在目录";openFile 在手机上应落到系统文件打开器或应用内文件浏览器。

---

## 汇总:跨包公共要点(Flutter 复刻必读)

1. settings/credentials 仅 loopback:远程/移动连接下 settings RPC 不可用,官方按 persistence: host|memory 降级(进程内),或干脆 unavailable。Flutter 需决定:直连 Host(loopback 语义)时全功能;远程时隐藏对应行或只读。
2. revision 栅栏:所有 settings 写入带 expectedRevision,冲突以 settings-conflict 拒绝;Flutter 必须实现"写后重读+最新写入优先"恢复语义。
3. 事件订阅面:settings/document-updated、credentials/updated、llm/adapters-updated、connection/reset 是设置系四个失效源,Flutter 端用等价的推送事件(或轮询兜底)驱动刷新。
4. slot 账本模型:web 端设置区是 slot 组合(trigger/header/action/section/plugins.tab/onboarding/general.item),Flutter 无需照搬,但导航/分区/onboarding 的注册-投影结构值得映射为可插拔页面注册表。
5. 命令入口:/permission、/model 是 host 命令,Flutter 应有等价命令面板(斜杠菜单)入口,保持带参路径直接切换的语义。