#!/usr/bin/env bash
# 安装并启动 dsh 反向隧道 launchd 代理(Mac → example.com 服务器)。
#
# 隧道语义:服务器 127.0.0.1:13100 → 本机 127.0.0.1:3080(dsh web)。
# dsh-gateway(服务器)经此口中转所有移动端流量;dsh 本体保持 loopback 绑定,零改动。
#
# 前置:
#   1. `ssh example.com` 可免密登录(root@203.0.113.10)
#   2. 本机 dsh web 跑在 127.0.0.1:3080(默认)
set -euo pipefail

PLIST_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/dsh-tunnel.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.yltech.dsh-tunnel.plist"

mkdir -p "$HOME/Library/LaunchAgents"
launchctl unload "$PLIST_DST" 2>/dev/null || true
cp "$PLIST_SRC" "$PLIST_DST"
# plist 里的 HOME 写的是本仓库作者的用户名;别的机器上替换之。
if [ "$HOME" != "/Users/you" ]; then
  sed -i '' "s|/Users/you|$HOME|g" "$PLIST_DST"
fi
launchctl load "$PLIST_DST"
sleep 2
if launchctl list | grep -q com.yltech.dsh-tunnel; then
  echo "✅ 隧道代理已启动(断线自动重连,开机自启)"
  echo "   服务器 127.0.0.1:13100 → 本机 127.0.0.1:3080"
  echo "   验证: ssh example.com 'curl -s --max-time 3 http://127.0.0.1:13100/api/host.describe -o /dev/null -w %{http_code}; echo'"
else
  echo "❌ 启动失败,看日志: /tmp/dsh-tunnel.log" >&2
  exit 1
fi
