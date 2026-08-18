# 远程网页访问 dsh web 的安全方案(基于 dsh-mobile 网关)

状态:设计稿(2026-08-17)
目标:在异地用任意浏览器,经鉴权后访问 Mac 上 `dsh web`(loopback :3080)的完整 GUI
(含流式输出与事件 WebSocket),不改动 dsh 本体,复用 dsh-mobile 已有隧道与网关。

## 结论(选型)

**在 rust 网关(dsh-mobile-gateway)新增「web 面」:独立子域 + 独立监听口
(默认 :8104)+ 密码登录页 + HttpOnly 会话 Cookie + 既有 relay 管道转发。**
不采用 CF Access / dsh 直接暴露,理由见文末。

> 实施修正(2026-08-17):原设计「网关内按 Host 分流」不可行 —— axum 的
> `Router::layer` 包的是各条路由而非路由决策本身,中间件改写 URI 发生在
> 路由之后,嵌套路由永远收不到改写路径(实测 + 最小复现确认)。改为
> **nginx 按 server_name 分流到网关独立监听口**,Host 路由归 TLS 反代,
> 网关更简单、两面物理隔离。

```
浏览器 ──https──→ nginx(server_name web.example.com)
                      │ proxy_read_timeout 3600s + WS upgrade + HSTS
                      ▼
              网关 Web 面 :8104(独立监听,与 App 公开面 :8102 分离)
                      │  无 cookie → 302 登录页;有且有效 → relay
                      ▼
              既有 SSH 反向隧道(127.0.0.1:131xx / UDS 优先)
                      ▼
              Mac dsh web :3080(仍绑 loopback,零改动)
```

## 组件与改动点

### 1. nginx(服务器侧)

- 新增 `web.example.com` server 块 → `proxy_pass http://127.0.0.1:8104`
  (完整样例:gateway `deploy/nginx-web.conf.example`),
  带 `proxy_http_version 1.1` + `Upgrade`/`Connection` 头 + `proxy_read_timeout 3600s`
  (WS 空闲长连,与现有 dsh 转发同一套参数);
- 用**独立子域**而不是路径前缀:dsh web 的静态资源与 `/api` 都假设根路径,挂前缀会破坏
  相对路径;子域则 relay 无需改写 path,同源关系也天然成立(cookie/CSRF 模型简单)。

### 2. 网关「web 面」(src/web.rs,已实施)

- **独立监听**:`DSH_GATEWAY_WEB_BIND/PORT`(默认 127.0.0.1:8104);App 公开面
  (:8102)与管理面(:8103)完全不动 —— Flutter 客户端方案零影响。
- **登录**:`GET /_gateway/login` 返回内联 HTML 单页(无外部资产,登录页自身不可被
  代理逃逸);`POST` 走 argon2 校验。**新配置 `DSH_GATEWAY_WEB_PASSWORD_HASH`**(与 App
  兜底密码分开,可独立轮换/禁用;空 = web 面整体关闭并 404,默认安全)。哈希仍用
  `--hash-password` 生成。登录复用并单独分桶 `LoginRateLimiter`(每 IP 限速)。
- **会话**:成功后签发 Cookie `dshweb=<HMAC 签名的 payload>`,payload = `{jti, iat, exp}`;
  - `HttpOnly` + `Secure` + `SameSite=Strict` + `Path=/`;有效期 12h(滑动续期:剩余
    <1/2 时刷新);
  - 签名密钥复用 `DSH_GATEWAY_JWT_SECRET` 派生子密钥(HKDF label `web-session`),与
    设备令牌互不通用;
  - v1 无服务端会话表(无状态校验);吊销 = 改密码(换 hash 即全量失效),后续可选加
    SQLite 存活表;
  - `/_gateway/logout` 清 cookie。
- **转发**:其余一切路径(含 `/`、静态资源、`/api/*`、WS upgrade)校验 cookie 后,
  直接喂给现有 `relay_http` / `relay_websocket`——Host 改写为 loopback authority、
  剥 Authorization、UDS 优先、WS 在线计数这些既有语义全部复用。上游用新配置
  `DSH_GATEWAY_WEB_UPSTREAM_PORT`(默认取 `upstream_addr`)钉住目标 Mac 的隧道口,
  web 会话与设备令牌是**两套独立凭证**,互不传染。
- **CSRF/跨源防线**(cookie 鉴权必须补的环,照抄 dsh-mobile 插件管理 API 的三重门):
  - 非 GET/HEAD 请求要求 `Sec-Fetch-Site ∈ {same-origin, none}` 或 `Origin` 匹配
    web 主机名,否则 403(dsh web UI 自身全部同源,不受影响;恶意网页发起的跨源
    POST 必带 cross-site,被拒);
  - 登录 POST 同样过这道门 + 限速;
  - 响应不加 `Access-Control-Allow-Origin`,不给跨源读开的口子。

### 3. Mac 侧(dsh-mobile 插件)

**零改动**。SSH 反向隧道由插件随 `dsh web` 起停,web 面只是隧道下游的又一个消费者。
可选(非必须):「移动接入」dialog 的隧道区加一行 web 面在线指示。

## 安全属性(威胁对照)

| 威胁 | 防线 |
|---|---|
| 公网扫描直连 dsh | dsh 仍绑 loopback;唯一公网面 = 网关,TLS 由 nginx 终结 |
| 撞库/爆破密码 | argon2 + 每 IP 登录限速 + 默认禁用(不配 hash 即 404) |
| 会话被 XSS/JS 窃取 | cookie HttpOnly,页面脚本读不到 |
| 跨站请求伪造 | SameSite=Strict + Sec-Fetch-Site/Origin 门 |
| 令牌混用/泄漏放大 | web 会话与 30 天设备令牌是独立凭证、独立密钥派生;relay 侧照旧剥 Authorization,设备令牌不进上游 |
| 中间人 | 全程 HTTPS,WS 同域 wss |
| 内网钓鱼页 | 登录页内联自足,不代理任何 `/_gateway/*` 之外的网关内部路径 |
| dsh 信任围栏 | Host 改写 loopback authority(既有 relay 语义),无需 `--trusted-host` |

已知残留面(如实记录):持有有效会话 cookie 的浏览器 = 完整 agent 控制权(与桌面同机
等价),故有效期刻意短(12h)且不设「记住我」;网关服务器被攻破则一切皆失(与现状
相同,信任根本来就是那台服务器)。

## 设计问答(关键决策依据)

- **配置放哪?** 服务器 env 只留一次性拓扑配置(`DSH_GATEWAY_WEB_HOSTNAME` 等);
  **web 密码 hash 存 SQLite**,经管理面(:8103,loopback + ssh 唯一入口)新增
  `web.setPassword` 写入 —— 在 Mac 侧「移动接入」dialog 填一次,dsh-mobile 插件
  ssh 推送即时生效(照抄 CF 形态 ADMIN_KEY 的管理模式)。"能改 web 密码 = 有服务器
  ssh 权限",与配对同信任级,不新增公网面。
- **登录形态?** 经典登录页:无 cookie → 302 `/_gateway/login`(网关自渲染内联
  HTML)→ 输密码 → Set-Cookie → 302 回原 URL,之后整个 GUI 正常使用。单用户
  单密码,无注册/邮件环节。
- **静态资源/WS 会带鉴权吗?** 会。cookie 按域+路径(`/`,整域)自动携带,与 URL
  写法无关;dsh web 是相对路径 SPA,在 web 子域下解析回同域,静态资源、`/api/*`、
  WS 握手全部自动带 cookie。不存在写死 localhost 的资源 URL(选独立子域而非路径
  前缀,正是为了让相对路径零改写工作)。

## 否决的备选

- **Cloudflare Access 前置**:零代码,但流量必须过 CF 边缘 —— 已实测 CF 对空闲 WS
  ~126s 必掐(AGENTS 坑位记录),dsh web 的事件 WS 会陷入整代重连循环;且要把该子域
  DNS 橙云迁移。否决。
- **dsh web 绑 0.0.0.0 + `--trusted-host` 公网域名**:`--trusted-host` 只解决围栏放行,
  不提供任何鉴权 —— 能路由到端口即拿到完整 agent 控制权。否决(除非叠加本方案的
  网关门,而那时 `--trusted-host` 也没有必要)。
- **Tailscale/WireGuard**:安全但要求每个访问者装客户端,不符合「简单网页访问」。

## 落地顺序(估工)

1. 网关:`web.rs` 模块(分流 + 登录页 + cookie 签发校验 + CSRF 门)+ 2 个新配置项 +
   集成测试(登录/过期/跨源拒/WS 升级/禁用态 404)—— 主要工作量,半天~一天;
2. nginx:server 块 + acme 签证书,十分钟;
3. 联调:手机热点环境过一遍 GUI 全功能(流式、审批卡、todo、主题),观察 WS 长连;
4. 文档:gateway README 增补 web 面章节。

> 本文档所有域名/主机名为占位符;真实部署细节只写 `server/LOCAL.md`(不入库)。
