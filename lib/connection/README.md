# connection/ — 连接控制器(M1,接口将冻结)

规划中的职责(见 docs/PLAN.md M1):
- ApiClient:rpcId mint、信封 wrap/unwrap、30s unary 超时、错误折叠
- 双 WS 下行(`/api/events.mux` + `/api/events.host`)只收管理 + 就绪握手
- 整代重建状态机:任一 socket 断 → 重建两流 + 重握手 + 重取 history

M0 期间本目录为空占位。禁区:M0 不得在此写代码(垂直切片纪律)。
