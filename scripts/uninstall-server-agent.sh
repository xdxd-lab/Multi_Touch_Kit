#!/bin/zsh
# 停止並移除 scripts/install-server-agent.sh 安裝的 LaunchAgent 與 MultiTouchKit Server.app（含舊版的純執行檔）。
# 簽章身分（scripts/create-signing-identity.sh --remove）與系統設定中的授權項目不會自動移除。
set -euo pipefail
LABEL=com.xdxd-lab.multitouchkit.server
DEST="$HOME/Library/Application Support/MultiTouchKit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
rm -f -- "$PLIST" "$DEST/mtk-server"
rm -rf -- "$DEST/MultiTouchKit Server.app"
echo "已移除 $LABEL"
echo "系統設定的授權項目可用以下指令清除（或在清單中按「−」）：tccutil reset ListenEvent $LABEL; tccutil reset Accessibility $LABEL"
