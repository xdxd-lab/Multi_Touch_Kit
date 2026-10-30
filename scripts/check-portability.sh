#!/bin/zsh
# 檢查 repo 換到另一台 Mac（不同使用者名稱、不同路徑）後仍可直接 clone 建置：
#   1. 已追蹤的檔案（含二進位檔，例如 Unity 外掛 bundle）中沒有本機絕對路徑 /Users/<名稱>/、/home/<名稱>/
#   2. 沒有提交編輯器或系統的個人檔案（xcuserdata、.DS_Store、.swiftpm、.vscode、.idea）
#   3. Unity 外掛 bundle 是 arm64 + x86_64 universal
# 只讀取檔案，不建置；test.sh 會先執行它。
# 用法：scripts/check-portability.sh
set -euo pipefail
cd "$(dirname "$0")/.."
BUNDLE=Unity/com.xdxd-lab.multitouchkit/Runtime/Plugins/macOS/MultiTouchKit.bundle/Contents/MacOS/MultiTouchKit
failures=0
ng() { echo "NG  $1"; failures=$((failures + 1)); }

# 1. grep -a 也搜尋二進位檔：除錯符號會把建置機器上 .o 的絕對路徑寫進執行檔
hits=$(git ls-files -z | xargs -0 grep -laE '/(Users|home)/[A-Za-z0-9._-]+/' 2>/dev/null || true)
if [[ -n "$hits" ]]; then
    ng "含本機絕對路徑的檔案："
    print -r -- "$hits" | sed 's/^/      /'
    git ls-files -z | xargs -0 grep -naIE '/(Users|home)/[A-Za-z0-9._-]+/' 2>/dev/null | head -20 | sed 's/^/      /' || true
else
    echo "OK  沒有本機絕對路徑"
fi

# 2.
personal=$(git ls-files | grep -E '(^|/)(xcuserdata|\.swiftpm|\.vscode|\.idea)/|(^|/)\.DS_Store$' || true)
if [[ -n "$personal" ]]; then
    ng "提交了個人檔案："
    print -r -- "$personal" | sed 's/^/      /'
else
    echo "OK  沒有個人檔案"
fi

# 3.
archs=$(lipo -archs "$BUNDLE" 2>/dev/null || true)
if [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]]; then
    echo "OK  Unity 外掛架構：$archs"
else
    ng "Unity 外掛不是 arm64 + x86_64 universal（$archs）：執行 scripts/build-unity-plugin.sh"
fi

if (( failures > 0 )); then
    echo "$failures 項失敗"
    exit 1
fi
echo "ALL PASS"
