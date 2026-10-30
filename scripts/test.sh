#!/bin/zsh
# 執行可攜性檢查與單元測試（不需要觸控硬體）。
# 只裝 Command Line Tools（沒有 Xcode）時，SwiftPM 找不到 Swift Testing，需要手動加上框架路徑。
set -euo pipefail
cd "$(dirname "$0")/.."
# 換機可攜性（本機絕對路徑、個人檔案、Unity 外掛架構）
scripts/check-portability.sh
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ -d "$CLT/Frameworks/Testing.framework" ]] && [[ "$(xcode-select -p)" != *Xcode*.app* ]]; then
    swift test \
        -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
        -Xlinker -F -Xlinker "$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
else
    swift test "$@"
fi
