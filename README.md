# singleman — Flutter 客户端连接 DSH

用 Flutter 开发一个连接 DeepSeek Harness (DSH) 的原生客户端(工作名 singleman)。
DSH 是插件化 agent harness,本机以 `dsh` CLI 运行,Web GUI 即其官方浏览器客户端。

## 项目状态(2026-06 起)

| 阶段 | 状态 |
|---|---|
| 可行性评估 | ✅ 完成 — **结论:可行** |
| **活体全链路验收** | ✅ **FEATURES-SMOKE-PASS**(2026-08-14)— 真实对话/fork/模型切换/导出 |
| 开发计划 | ✅ 完成 — 见 `docs/PLAN.md` |
| 协议知识冻结 | ✅ 完成 — 见 `docs/DSH-PROTOCOL.md` |
| M0 契约与测试床 | ✅ 完成(2026-08-14)— codegen 管线 + conformance 3 绿 + fixture 回放 2 绿 |
| M1 连接控制器 | ✅ 完成(2026-08-14)— ApiClient + 整代重建状态机 + 故障注入 11 绿,接口冻结 |
| M2 最小聊天环 | ✅ 完成(2026-08-14)— 活体真实对话 + 拔线重连验收(SMOKE-PASS),24 测试绿 |
| M3 交互帧 | ✅ 完成(2026-08-14)— 审批卡/问答表单/队列 Dock + respond 信封,32 测试绿 |
| M4+ 功能面 | ✅ 完成(2026-08-14)— 模型选择/搜索/fork/导出/markdown/goal/skill/图片附件(四限预拒)/LAN 特权围栏,47 测试绿 |

最新进度与下一步:里程碑状态见上表,决策记录见 `docs/PLAN.md`。维护者开发日志(`AGENTS.md`/`PROGRESS.md`)为本地文件,不入库。

## 新会话自举(必读)

本项目的核心纪律:**知识活在文件里,不活在对话里**。任何新会话按此顺序读:

1. `README.md`(本文件)— 项目是什么、在哪
2. `docs/DSH-PROTOCOL.md` — 只在做协议相关任务时读,已包含全部必要结论 + 源码验证路径,**不需要重新调查 DSH 源码**
3. `docs/PLAN.md` — 只在规划/拆任务时读

读完本文件即可开工大多数任务。禁止在未读 `docs/DSH-PROTOCOL.md` 的情况下改动 wire 层。

## 一句话架构

```
Flutter 客户端
 ├─ wire/        契约模型(codegen 自 DSH zod schema)+ ApiClient(POST /api/*)
 ├─ connection/  双下行 WebSocket + 整代重建状态机
 ├─ sessions/    会话/历史/队列/审批/问答 的领域状态
 └─ ui/          flutter_markdown 渲染 + 交互卡片
```

## 关键外部事实

- DSH 安装位置:`~/.local/lib/node_modules/@deepseek-ai/dsh/`(版本 0.1.0-rc.6)
- 本机 GUI:`http://127.0.0.1:3080`(dsh web 默认端口)
- 部署形态分级:桌面同机 🟢 / 手机 LAN 🟢(M6.2 起网关可跑 Mac 本机,免服务器)/ 公网 🟢(M6 起:经自部署鉴权网关,见 docs/PLAN.md ADR-0006)
- 服务端网关:[dsh-mobile-gateway](https://github.com/iptton-ai/dsh-mobile-gateway),以 **git submodule 挂在 `gateway/`**(Mac 侧配对/隧道用 [dsh-mobile](https://github.com/iptton-ai/dsh-mobile) 插件);客户端默认地址是占位符,自用设备在配对页地址栏手输一次真实网关(或扫 dsh web 配对二维码自动带入;存凭证后不再问)

## 平台支持

| 平台 | 状态 | 说明 |
|---|---|---|
| Android / iOS | ✅ | 扫码配对走 mobile_scanner |
| macOS | ✅ | 桌面 loopback 直连形态 |
| OHOS(HarmonyOS) | ✅(2026-08-16 起) | `ohos/` 工程(OHOS fork SDK 生成)+ 依赖覆盖见下;扫码入口自动降级剪贴板 |
| Linux / Windows | 模板生成,未实测 | |

### OHOS 构建要点

- SDK:OHOS fork(`3.35.8-ohos-1.0.1`,即本机默认 flutter);工具链 DevEco(ohpm/hvigor/hdc)。
- 依赖:pub.dev 的 `path_provider` 无 ohos 实现 —— `pubspec.yaml` 以 `dependency_overrides` 指到 gitcode 镜像 [CPF-Flutter/flutter_packages](https://gitcode.com/CPF-Flutter/flutter_packages) 分支 `br_path_provider-v2.1.5_ohos`(同版本号只增 ohos 声明,传递解析 `path_provider_ohos`,来源 openharmony-sig 同名分支)。其余依赖(WS/dart:io/HttpClient)ohos 原生可用。
- 首次构建:DevEco 打开 `ohos/` 配一次调试签名(File → Project Structure → Signing Configs 勾 *Automatically generate signature*),之后 `flutter build hap --debug` 即可(签名材料是账号维度,CLI 无法代办)。
- mobile_scanner 无 ohos 实现:配对页扫码入口仅 Android/iOS 可见,ohos 走剪贴板粘贴(落地页「复制」流程),无编译阻塞。

## 开源使用者要装几件?(部署拓扑)

| 拓扑 | 使用者要装的东西 | 适用 | 实测状态 |
|---|---|---|---|
| 桌面同机 | 浏览器打开 `127.0.0.1:3080` | Mac 前用 | dsh 自带 |
| **LAN(同一 WiFi)** | ① App ② Mac 跑网关二进制(`DSH_GATEWAY_UPSTREAM=127.0.0.1:3080` + 端口白名单放宽 + claim 声明 3080;HTTP 明文) | 手机在家连 Mac | 2026-08-15 实测:配对/中转/WS 全通,零服务器零隧道 |
| **公网自托管** | ① App ② Mac 隧道(dsh 插件行,随 `dsh web` 起)③ 自己服务器 `docker compose up`(网关 + TLS) | 出门连 Mac | 生产运行中 |
| 公网托管(多用户网关) | ① App ② Mac 一行指向运营者网关 | 家人/小团队 | 需改造:Mac 侧独立身份(现为「有服务器 ssh 权限 = 能配对」);中转方可见全部流量,只适合互信小圈 |

三件是结构性下限(Mac 在 NAT 后必须有出站桥;dsh 绑 loopback;无 P2P),但每件都被压缩到一条命令。

## 工作规则

- 维护者开发日志(`AGENTS.md` 结论 / `PROGRESS.md` 过程)为本地文件,不入库
- 决策(为什么这么做)写进 `docs/PLAN.md` 的决策记录节或独立 ADR
- PR/提交 ≤ 400 行,描述自带上下文摘要
- dsh 升级是独立提交,只允许动生成代码 + conformance 测试
