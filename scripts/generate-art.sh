#!/bin/zsh
# 重新產生品牌素材（圖示、.icns、README banner、favicon、Unity 元件圖示），產出的檔案要 commit。
# 全部由 Sources/MultiTouchKitArt 以程式繪製：改設計時改那裡，再執行這個腳本。
set -euo pipefail
cd "$(dirname "$0")/.."
swift run -c release mtk-art "$PWD"
iconutil -c icns Assets/Brand/MultiTouchKit.iconset -o Assets/Brand/MultiTouchKit.icns
python3 scripts/generate-unity-meta.py >/dev/null
echo "已輸出 Assets/Brand/MultiTouchKit.icns"
