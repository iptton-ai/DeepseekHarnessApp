# singleman 远程接入(Mac 侧)

移动端(手机/外地)→ https://dsh.example.com → 服务器 dsh-gateway(鉴权+中转)
→ SSH 反向隧道 → 本机 dsh web(127.0.0.1:3080,loopback 绑定零改动)。

## 数据流真相(回答"服务器是不是只管首次连接")

**不是。** 服务器在数据路径上,所有客户端↔dsh 流量(HTTP + 两条下行 WebSocket)
全程经它中转 —— 它是一条纯字节管道:

- 中转的只有聊天 JSON 帧/图片附件(单用户量级:每轮对话 KB~MB,CPU 占用 <1% 单核);
- **不经过服务器**:dsh ↔ LLM 供应商的流量(真正的大头)、文件系统操作、工具执行
  —— 全部留在 Mac 本地;
- 2 核 2G 远超所需(gateway 常驻 ~15MB 内存)。

P2P 打洞(仅首次连接用服务器)需要 WebRTC 级别的 NAT 穿透栈,复杂度不值得 ——
中继负载本来就约等于零。

## 组件

| 组件 | 位置 | 说明 |
|---|---|---|
| dsh-gateway | `example.com` 仓库 `services/dsh-gateway/`(:8102) | 密码登录(argon2)→ 设备令牌(30 天 JWT,SQLite 登记可吊销);强制 Bearer;WS/HTTP 中转;Host 改写 `127.0.0.1:3080` 过 dsh 信任围栏 |
| nginx | 服务器 `dsh.example.com` | TLS(*.example.com 通配符证书)+ WS upgrade + 流式透传 |
| 隧道 | 本仓库 `tool/remote/`(launchd) | `ssh -R 127.0.0.1:13100:127.0.0.1:3080 example.com`,断线自动重连 |

## 首次安装(Mac)

```bash
./tool/remote/install.sh
```

前置:`ssh example.com` 免密可登;服务器上 dsh-gateway 已部署(见 example.com 仓库)。

## 故障排查

- 手机连不上/网关 502 → 先看 `https://dsh.example.com/healthz` 的 `upstream` 字段
  (false = 隧道断或 Mac 不在线);
- 隧道日志:`/tmp/dsh-tunnel.log`;状态:`launchctl list | grep dsh-tunnel`;
- 重启隧道:`launchctl kickstart -k gui/$(id -u)/com.yltech.dsh-tunnel`;
- 吊销手机令牌:登录任意设备 → `POST /auth/revoke {"jti": ...}`(设备清单
  `GET /auth/devices`)。

## 安全模型

- 唯一暴露面:nginx 443(dsh.example.com)。密码爆破有每 IP 限速(5 分钟 8 次);
- 令牌泄漏可即时吊销;密码更换 = 服务器上重新生成 hash 写入 `/etc/dsh-gateway.env`
  后 `systemctl restart dsh-gateway`(已签发令牌不受密码更换影响,需要时逐个吊销);
- dsh 对网关呈现为 loopback 客户端(隧道出口 + Host 改写),特权方法
  (settings/credentials 等)对持有有效令牌的设备开放 —— 鉴权边界就是网关。
