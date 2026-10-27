#!/bin/zsh
# 停止並移除 scripts/install-server-agent.sh 安裝的 LaunchAgent。
set -euo pipefail
LABEL=com.xdxd-lab.multitouchkit.server
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
rm -f "$PLIST" "$HOME/Library/Application Support/MultiTouchKit/mtk-server"
echo "已移除 $LABEL"
