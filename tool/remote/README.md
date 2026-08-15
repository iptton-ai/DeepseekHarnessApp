# singleman 远程接入(Mac 侧)

移动端(手机/外地)→ https://dsh.example.com → 服务器 dsh-gateway(鉴权+中转)
→ SSH 反向隧道 → 本机 dsh web(127.0.0.1:3080,loopback 绑定零改动)。

## 数据流真相(回答"服务器是不是只管首次连接")

**不是。** 服务器在数据路径上,所有客户端↔dsh 流量(HTTP + 两条下行 WebSocket)
全程经它中转 —— 它是一条纯字节管道:

- 中转的只有聊天 JSON 帧/图片附件(单用户量级:每轮对话 KB~MB,CPU 占用 <1% 单核);
- **不经过服务器**:dsh ↔ LLM 供应商的流量(真正的大头)、文件系统操作、工具执行
  —— 全部留在 Mac 本地;
- 2 核 2G 远超所需。2026-08-15 活体复测:gateway 稳态常驻 ~46MB
  (argon2 首次登录的 memory-hard 校验 + glibc 滞留;VmHWM=稳态,无增长趋势;
  初测 4.9MB 系重启后未登录的新进程读数);全路径 CPU ~13ms/MB
  (sshd 隧道 ~9 + gateway ~2.5 + nginx ~3.5);单流 ~14Mbps、聚合 ~28Mbps
  才是真实上限(服务器带宽/RTT 窗口),大附件比 CPU/内存先碰顶。

P2P 打洞(仅首次连接用服务器)需要 WebRTC 级别的 NAT 穿透栈,复杂度不值得 ——
中继负载本来就约等于零。

## 组件

| 组件 | 位置 | 说明 |
|---|---|---|
| dsh-gateway | `example.com` 仓库 `services/dsh-gateway/`(:8102) | 密码登录(argon2)→ 设备令牌(30 天 JWT,SQLite 登记可吊销);强制 Bearer;WS/HTTP 中转;Host 改写 `127.0.0.1:3080` 过 dsh 信任围栏 |
| nginx | 服务器 `dsh.example.com` | TLS(*.example.com 通配符证书)+ WS upgrade + 流式透传 |
| 隧道 | `~/.dsh/profiles/web/dsh-tunnel.mjs`(dsh 插件行,随 `dsh web` 启动) | `ssh -R 127.0.0.1:13100:<运行时端口>`;端口读自 webServer 服务(`--port 0` 也正确);断线退避重连,dsh 退出即断 |

## 启用(Mac,单命令)

**现行方式(推荐)**:无需单独安装 —— `~/.dsh/profiles/web/cordis.patch.yml` 的
`dsh-tunnel` 插件行随每次 `dsh web` 自动拉起隧道。改配置就编辑该文件
(`target`/`remotePort`);临时覆盖用环境变量 `DSH_TUNNEL_TARGET` /
`DSH_TUNNEL_REMOTE_PORT`。已活体验证:随机端口实例(`--port 0`)隧道自动跟随,
dsh 退出后服务器口即时释放。

**旧方式(launchd,已退役)**:`install.sh` 装的 `com.yltech.dsh-tunnel` 常驻代理
与插件在同一 remotePort 上互斥(双方 ExitOnForwardFailure)。迁移:先跑
`uninstall.sh` 再重启 `dsh web`(插件退避重试 ≤30s 内自动接管;dsh 先起会看到
端口占用告警,卸载 launchd 后下一轮重试即接上)。

## 故障排查

- 手机连不上/网关 502 → 先看 `https://dsh.example.com/healthz` 的 `upstream` 字段
  (false = 隧道断或 Mac 不在线);
- 插件隧道日志:dsh web 进程输出(`dsh-tunnel: ...` 前缀;端口被占会退避重试并告警);
- 隧道进程:`ps aux | grep "[1]3100"`;服务器口占用:`ssh example.com "ss -tln | grep 13100"`;
- 旧 launchd 残留(端口互斥告警时):`launchctl list | grep dsh-tunnel`,有则跑 `uninstall.sh`;
- 吊销手机令牌:登录任意设备 → `POST /auth/revoke {"jti": ...}`(设备清单
  `GET /auth/devices`)。

## 安全模型

- 唯一暴露面:nginx 443(dsh.example.com)。密码爆破有每 IP 限速(5 分钟 8 次);
- 令牌泄漏可即时吊销;密码更换 = 服务器上重新生成 hash 写入 `/etc/dsh-gateway.env`
  后 `systemctl restart dsh-gateway`(已签发令牌不受密码更换影响,需要时逐个吊销);
- dsh 对网关呈现为 loopback 客户端(隧道出口 + Host 改写),特权方法
  (settings/credentials 等)对持有有效令牌的设备开放 —— 鉴权边界就是网关。
