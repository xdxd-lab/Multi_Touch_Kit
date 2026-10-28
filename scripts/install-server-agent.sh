#!/bin/zsh
# 把 mtk-server 安裝成登入後自動執行的 LaunchAgent（當機會自動重啟）。
# 安裝為 ~/Library/Application Support/MultiTouchKit/MultiTouchKit Server.app（授權清單只接受 app，見 scripts/lib/server-app.sh）。
# 用法：scripts/install-server-agent.sh [mtk-server 選項…]   例：scripts/install-server-agent.sh --no-tuio
# 注意：常駐的 mtk-server 會獨占觸控螢幕，此時 Unity 請改用 UDP 傳輸方式。
# 簽章：有「MultiTouchKit Local Signing」（scripts/create-signing-identity.sh 建立）或 MTK_SIGN_IDENTITY 指定的身分時以它簽章，
# 重新安裝後授權仍有效；否則為 ad-hoc 簽章，每次更新都要重新授權「輸入監控」與「輔助使用」（見 scripts/lib/sign-server.sh）。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/sign-server.sh
source scripts/lib/server-app.sh
LABEL=com.xdxd-lab.multitouchkit.server
DEST="$HOME/Library/Application Support/MultiTouchKit"
APP="$DEST/$MTK_SERVER_APP_NAME.app"
EXECUTABLE="$APP/Contents/MacOS/$MTK_SERVER_APP_EXECUTABLE"
# 2026-10 以前安裝成純執行檔（無法加入授權清單）：安裝 app 後移除
LEGACY="$DEST/mtk-server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/mtk-server.log"
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/MultiTouchKit/Touch.swift)

swift build -c release --product mtk-server
mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
# 先在暫存的 app 上簽章，與已安裝版本比較簽章身分後才取代（失敗時保留原本的版本）
if [[ -d "$APP" ]]; then
    BEFORE=$(mtk_designated_requirement "$APP")
else
    BEFORE=""
fi
STAGING="$DEST/.$MTK_SERVER_APP_NAME.app.new"
rm -rf -- "$STAGING"
mtk_build_server_app .build/release/mtk-server "$STAGING" "$VERSION" Assets/Brand/MultiTouchKit.icns
IDENTITY=$(mtk_sign_server "$STAGING") || { rm -rf -- "$STAGING"; exit 1; }
AFTER=$(mtk_designated_requirement "$STAGING")
# 舊版先改名，新版就位後才刪除：mv 失敗時仍可還原
PREVIOUS="$DEST/.$MTK_SERVER_APP_NAME.app.old"
rm -rf -- "$PREVIOUS"
[[ -d "$APP" ]] && mv "$APP" "$PREVIOUS"
if ! mv "$STAGING" "$APP"; then
    [[ -d "$PREVIOUS" ]] && mv "$PREVIOUS" "$APP"
    echo "無法安裝 $APP" >&2
    exit 1
fi
rm -rf -- "$PREVIOUS"
echo "已安裝 $APP（簽章：$IDENTITY，bundle ID $MTK_SIGN_IDENTIFIER）"

xml() { print -r -- "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
ARGS="        <string>$(xml "$EXECUTABLE")</string>"
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
    <!-- 系統設定「登入項目」中把這個背景項目顯示為 MultiTouchKit Server -->
    <key>AssociatedBundleIdentifiers</key>
    <string>$LABEL</string>
    <key>StandardOutPath</key>
    <string>$(xml "$LOG")</string>
    <key>StandardErrorPath</key>
    <string>$(xml "$LOG")</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
if [[ -f "$LEGACY" ]]; then
    rm -f -- "$LEGACY"
    echo "已移除舊版的純執行檔 $LEGACY（系統設定中若還留有「mtk-server」項目，可用「−」移除）"
fi
launchctl bootstrap "gui/$UID" "$PLIST"
echo "已啟動 $LABEL"
mtk_report_authorization "$BEFORE" "$AFTER" "$IDENTITY"
echo "紀錄檔：$LOG"
echo "移除：scripts/uninstall-server-agent.sh"
