# 常駐版 mtk-server 的 app bundle（由 install-server-agent.sh 以 source 載入）。
#
# 為什麼包成 .app：系統設定的「輸入監控」「輔助使用」清單不接受直接加入純執行檔（＋與拖曳都無效），
# app 則可以用＋選取，清單中也會顯示名稱。授權以 bundle ID 加上簽章身分記錄，所以 CFBundleIdentifier
# 與簽章的 identifier 相同（com.xdxd-lab.multitouchkit.server，也是 LaunchAgent 的 label）。
# LaunchAgent 直接執行 Contents/MacOS/mtk-server：由 launchd 啟動時，授權的責任程序就是這個 app。

MTK_SERVER_APP_NAME="MultiTouchKit Server"
MTK_SERVER_APP_EXECUTABLE=mtk-server

# 建立 app bundle：$1 = 編好的 mtk-server、$2 = .app 路徑（不可已存在）、$3 = 版本
mtk_build_server_app() {
    local binary=$1 app=$2 version=$3
    mkdir -p "$app/Contents/MacOS"
    cp "$binary" "$app/Contents/MacOS/$MTK_SERVER_APP_EXECUTABLE"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$MTK_SIGN_IDENTIFIER</string>
    <key>CFBundleName</key>
    <string>$MTK_SERVER_APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$MTK_SERVER_APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$MTK_SERVER_APP_EXECUTABLE</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- 沒有 Dock 圖示與選單列：常駐在背景，只透過 UDP／WebSocket／TUIO 提供觸控 -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MultiTouchKit 觸控伺服器：讀取觸控螢幕（輸入監控），並可把觸控轉成系統手勢（輔助使用）</string>
</dict>
</plist>
PLIST
    plutil -lint -s "$app/Contents/Info.plist"
}
