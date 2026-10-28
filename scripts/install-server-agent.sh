#!/bin/zsh
# 把 mtk-server 安裝成登入後自動執行的 LaunchAgent（當機會自動重啟）。
# 用法：scripts/install-server-agent.sh [mtk-server 選項…]   例：scripts/install-server-agent.sh --no-tuio
# 注意：常駐的 mtk-server 會獨占觸控螢幕，此時 Unity 請改用 UDP 傳輸方式。
# 簽章：有「MultiTouchKit Local Signing」（scripts/create-signing-identity.sh 建立）或 MTK_SIGN_IDENTITY 指定的身分時以它簽章，
# 重新安裝後授權仍有效；否則為 ad-hoc 簽章，每次更新都要重新授權「輸入監控」與「輔助使用」（見 scripts/lib/sign-server.sh）。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/sign-server.sh
LABEL=com.xdxd-lab.multitouchkit.server
DEST="$HOME/Library/Application Support/MultiTouchKit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/mtk-server.log"

swift build -c release --product mtk-server
mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
# 先在暫存檔簽章，與已安裝版本比較簽章身分後才取代（簽章失敗時保留原本的版本）
BEFORE=$(mtk_designated_requirement "$DEST/mtk-server")
cp .build/release/mtk-server "$DEST/mtk-server.new"
IDENTITY=$(mtk_sign_server "$DEST/mtk-server.new") || { rm -f "$DEST/mtk-server.new"; exit 1; }
AFTER=$(mtk_designated_requirement "$DEST/mtk-server.new")
mv -f "$DEST/mtk-server.new" "$DEST/mtk-server"
echo "簽章：$IDENTITY（identifier $MTK_SIGN_IDENTIFIER）"

xml() { print -r -- "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
ARGS="        <string>$(xml "$DEST/mtk-server")</string>"
for a in "$@"; do ARGS+=$'\n'"        <string>$(xml "$a")</string>"; done

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
$ARGS
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$(xml "$LOG")</string>
    <key>StandardErrorPath</key>
    <string>$(xml "$LOG")</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "已安裝並啟動 $LABEL"
mtk_report_authorization "$BEFORE" "$AFTER" "$IDENTITY"
echo "紀錄檔：$LOG"
echo "移除：scripts/uninstall-server-agent.sh"
