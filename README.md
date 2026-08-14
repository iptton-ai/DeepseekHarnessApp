# singleman — Flutter 客户端连接 DSH

用 Flutter 开发一个连接 DeepSeek Harness (DSH) 的原生客户端(工作名 singleman)。
DSH 是插件化 agent harness,本机以 `dsh` CLI 运行,Web GUI 即其官方浏览器客户端。

## 项目状态(2026-06 起)

| 阶段 | 状态 |
|---|---|
| 可行性评估 | ✅ 完成 — **结论:可行** |
| 开发计划 | ✅ 完成 — 见 `docs/PLAN.md` |
| 协议知识冻结 | ✅ 完成 — 见 `docs/DSH-PROTOCOL.md` |
| M0 契约与测试床 | ✅ 完成(2026-08-14)— codegen 管线 + conformance 3 绿 + fixture 回放 2 绿 |
| M1 连接控制器 | ✅ 完成(2026-08-14)— ApiClient + 整代重建状态机 + 故障注入 11 绿,接口冻结 |
| M2 最小聊天环 | ✅ 完成(2026-08-14)— 活体真实对话 + 拔线重连验收(SMOKE-PASS),24 测试绿 |
| M3 交互帧 | ⬜ 未开始(下一步:审批卡→问答表单→队列 Dock) |

最新进度与下一步:**永远先读 `PROGRESS.md`**。

## 新会话自举(必读)

本项目的核心纪律:**知识活在文件里,不活在对话里**。任何新会话按此顺序读:

1. `README.md`(本文件)— 项目是什么、在哪
2. `PROGRESS.md` — 现在做到哪、下一步做什么、有什么坑
3. `docs/DSH-PROTOCOL.md` — 只在做协议相关任务时读,已包含全部必要结论 + 源码验证路径,**不需要重新调查 DSH 源码**
4. `docs/PLAN.md` — 只在规划/拆任务时读

读完 1+2 即可开工大多数任务。禁止在未读 `docs/DSH-PROTOCOL.md` 的情况下改动 wire 层。

## 一句话架构

```
Flutter 客户端
 ├─ wire/        契约模型(codegen 自 DSH zod schema)+ ApiClient(POST /api/*)
 ├─ connection/  双下行 WebSocket + 整代重建状态机
 ├─ sessions/    会话/历史/队列/审批/问答 的领域状态
 └─ ui/          flutter_markdown 渲染 + 交互卡片
```

## 关键外部事实

- DSH 安装位置:`/Users/you/.local/lib/node_modules/@deepseek-ai/dsh/`(版本 0.1.0-rc.6)
- 本机 GUI:`http://127.0.0.1:3080`(dsh web 默认端口)
- 部署形态分级:桌面同机 🟢 / 手机 LAN 🟡(需 `--trusted-host`)/ 公网 🔴(无认证层,禁止)

## 工作规则

- 改动后更新 `PROGRESS.md`(做了什么、卡在哪、下一步)
- 决策(为什么这么做)写进 `docs/PLAN.md` 的决策记录节或独立 ADR
- PR/提交 ≤ 400 行,描述自带上下文摘要
- dsh 升级是独立提交,只允许动生成代码 + conformance 测试
