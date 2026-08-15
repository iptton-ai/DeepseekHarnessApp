// dsh-tunnel — `dsh web` 一条命令自带远程隧道(M6 后续:消除双命令/端口漂移)。
// 部署位:~/.dsh/profiles/web/dsh-tunnel.mjs + cordis.patch.yml 的 dsh-tunnel 行;
// 本文件是仓库留档,改动后复制过去生效
//
// 行为:webserver 绑定成功后立即拉起 `ssh -N -T -R` 反向隧道,把服务器上的
// remotePort 转发到本机 dsh 实际监听端口。本机端口永远读自 webServer 服务
// 的运行时值 —— `dsh web --port 0`(OS 随机分配)也自动正确,无需任何协调。
// dsh 退出(任意原因)→ composition dispose → ssh 子进程随之终止,服务器口释放。
//
// 行(profiles/web/cordis.patch.yml):
//   - id: dsh-tunnel
//     name: './dsh-tunnel.mjs'
//     config:
//       target: example.com      # ~/.ssh/config 别名或 user@host
//       remotePort: 13100         # 服务器侧隧道落地口(网关 DSH_GATEWAY_UPSTREAM)
//
// 环境变量覆盖(测试用):DSH_TUNNEL_TARGET / DSH_TUNNEL_REMOTE_PORT。
// 端口被占(ExitOnForwardFailure)→ ssh 立即退出 → 有监督退避重启并告警,
// 不静默失败;日志走 ctx.logger(兜底 console)。
import { spawn } from 'node:child_process'

export const name = 'dsh-tunnel'
export const inject = ['webServer']

const SSH = '/usr/bin/ssh'

export function apply(ctx, config) {
	const target = process.env.DSH_TUNNEL_TARGET ?? config?.target ?? 'example.com'
	const remotePort = Number(process.env.DSH_TUNNEL_REMOTE_PORT ?? config?.remotePort ?? 13100)
	const localPort = ctx.webServer.port
	if (!Number.isInteger(remotePort) || remotePort <= 0 || remotePort > 65535) {
		throw new Error(`dsh-tunnel: invalid remotePort ${String(remotePort)}`)
	}
	if (!Number.isInteger(localPort) || localPort <= 0) {
		throw new Error('dsh-tunnel: web server has no bound port')
	}

	const emit = (level, message) => {
		const logger = ctx.logger
		const line = `dsh-tunnel: ${message}`
		if (logger && typeof logger[level] === 'function') logger[level](line)
		else console[level === 'warning' ? 'warn' : 'log'](`[${line}]`)
	}

	const args = () => [
		'-N', '-T',
		'-o', 'BatchMode=yes',
		'-o', 'ServerAliveInterval=30',
		'-o', 'ServerAliveCountMax=3',
		'-o', 'ExitOnForwardFailure=yes',
		'-o', 'StrictHostKeyChecking=accept-new',
		'-o', 'ConnectTimeout=15',
		'-R', `127.0.0.1:${String(remotePort)}:127.0.0.1:${String(localPort)}`,
		String(target),
	]

	let child = null
	let stopped = false
	let attempt = 0
	let timer = null

	const start = () => {
		if (stopped) return
		child = spawn(SSH, args(), { stdio: ['ignore', 'pipe', 'pipe'] })
		let first = true
		child.stderr.on('data', (d) => {
			const text = String(d).trim()
			// 首次连接的 host-key 提示属正常噪音,降为 info;其余(含端口占用)告警。
			if (first && text.includes('Permanently added')) {
				first = false
				return
			}
			emit(text ? 'warning' : 'info', text || 'ssh stderr (empty)')
		})
		child.on('exit', (code, signal) => {
			child = null
			if (stopped) return
			const delay = Math.min(1000 * 2 ** Math.min(attempt, 5), 30000)
			attempt += 1
			emit('warning', `ssh exited (code=${String(code)} signal=${String(signal)}); restart in ${String(delay)}ms — 若持续失败,检查 remotePort ${String(remotePort)} 是否被旧隧道占用(launchctl list | grep dsh-tunnel)`)
			timer = setTimeout(start, delay)
		})
	}

	emit('info', `up: ${String(target)} 127.0.0.1:${String(remotePort)} → local :${String(localPort)}`)
	start()

	ctx.effect(() => () => {
		stopped = true
		if (timer !== null) clearTimeout(timer)
		if (child !== null) child.kill('SIGTERM')
	}, 'dsh-tunnel: supervised ssh child')
}
