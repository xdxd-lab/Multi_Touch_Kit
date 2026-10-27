#!/bin/zsh
# 把 mtk-server 安裝成登入後自動執行的 LaunchAgent（當機會自動重啟）。
# 用法：scripts/install-server-agent.sh [mtk-server 選項…]   例：scripts/install-server-agent.sh --no-tuio
# 注意：常駐的 mtk-server 會獨占觸控螢幕，此時 Unity 請改用 UDP 傳輸方式。
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL=com.xdxd-lab.multitouchkit.server
DEST="$HOME/Library/Application Support/MultiTouchKit"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/mtk-server.log"

swift build -c release --product mtk-server
mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp .build/release/mtk-server "$DEST/mtk-server"

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
echo "紀錄檔：$LOG"
echo "移除：scripts/uninstall-server-agent.sh"
