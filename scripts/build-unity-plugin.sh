#!/bin/zsh
# 建置 Unity 原生外掛：arm64 + x86_64 universal 的 MultiTouchKit.bundle，放進 Unity 套件。
# 原生程式碼（Sources/MultiTouchKit、Sources/MultiTouchKitC）有改動時要重新執行並 commit 產出的 bundle。
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGE=Unity/com.xdxd-lab.multitouchkit
OUT=$PACKAGE/Runtime/Plugins/macOS/MultiTouchKit.bundle
VERSION=$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/MultiTouchKit/Touch.swift)
DEPLOYMENT=13.0

# 本機架構放在最後建置：SwiftPM 會把 .build/release 指向最後一次建置的架構，
# 否則 .build/release 裡的 libMultiTouchKitC.dylib、mtk-server 等會變成另一個架構而無法在本機執行
if [[ "$(uname -m)" == arm64 ]]; then ARCHS=(x86_64 arm64); else ARCHS=(arm64 x86_64); fi
for arch in $ARCHS; do
    echo "== 建置 $arch"
    swift build -c release --product MultiTouchKitC --triple "$arch-apple-macosx$DEPLOYMENT"
done

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
lipo -create \
    ".build/arm64-apple-macosx/release/libMultiTouchKitC.dylib" \
    ".build/x86_64-apple-macosx/release/libMultiTouchKitC.dylib" \
    -output "$OUT/Contents/MacOS/MultiTouchKit"
install_name_tool -id "@rpath/MultiTouchKit.bundle/Contents/MacOS/MultiTouchKit" "$OUT/Contents/MacOS/MultiTouchKit"
# 移除除錯符號（-S）與非匯出的本機符號（-x）：除錯符號表中的 N_OSO 項目記錄建置機器上 .o 的絕對路徑
# （/Users/<名稱>/…），提交到 repo 會洩漏本機路徑，換機重建時也會產生無意義的差異。匯出符號（C API）不受影響
strip -S -x "$OUT/Contents/MacOS/MultiTouchKit"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MultiTouchKit</string>
    <key>CFBundleIdentifier</key>
    <string>com.xdxd-lab.multitouchkit.plugin</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MultiTouchKit</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$DEPLOYMENT</string>
</dict>
</plist>
PLIST

# Apple Silicon 上的程式碼至少要 ad-hoc 簽章
codesign --force --sign - "$OUT"

python3 scripts/generate-unity-meta.py
lipo -info "$OUT/Contents/MacOS/MultiTouchKit"
echo "已輸出 $OUT（版本 $VERSION）"
