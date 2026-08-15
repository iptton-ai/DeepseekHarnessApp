#!/usr/bin/env bash
# 退役 launchd 隧道代理(由 dsh 插件 ~/.dsh/profiles/web/dsh-tunnel.mjs 接管)。
#
# 迁移顺序(一次性):
#   1. 运行本脚本 —— launchd 停止并移除,释放服务器 13100 口
#   2. 重启 dsh(dsh web)—— 插件随启动自动接管 13100(启动前运行本脚本则
#      一次成功;若 dsh 先起,插件会退避重试并告警,本脚本运行后 ≤30s 自动接上)
#   3. 验证:ssh example.com "curl -s http://127.0.0.1:13100/api/host.describe \
#            -X POST -H 'content-type: application/json' \
#            -d '{\"type\":\"client-request\",\"rpcId\":\"v\",\"method\":\"host.describe\",\"payload\":{}}'"
#      返回 server-response 即通。
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.yltech.dsh-tunnel.plist"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
# 兜底:清掉可能残留的 ssh 进程(只杀带 13100 转发的)。
pkill -f "127.0.0.1:13100:127.0.0.1:3080" 2>/dev/null || true

echo "✅ launchd 隧道代理已退役"
echo "   下次 dsh web 启动时,插件 dsh-tunnel 自动接管 13100(端口跟随,无需配置)"
echo "   插件配置:~/.dsh/profiles/web/cordis.patch.yml(dsh-tunnel 行)"
