#!/bin/zsh
# Examples/web/index.html 的測試，以 macOS 內建的 jsc（Safari 的 JavaScript 引擎）執行：
#   1. 取出頁面中「座標換算」區段的純函式，測試各種視窗幾何
#   2. 以 DOM／WebSocket 替身執行整個頁面腳本：hello／display／frame → 畫出的位置
# 用法：scripts/test-web-example.sh
set -euo pipefail
cd "$(dirname "$0")/.."
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
OUT=.build/web-example
mkdir -p $OUT
sed -n '/\/\/ MARK: - 座標換算/,/\/\/ MARK: - 瀏覽器/p' Examples/web/index.html > $OUT/mapping.js
if ! grep -q "function mapTouch" $OUT/mapping.js; then
    echo "index.html 中找不到座標換算區段（// MARK: - 座標換算 … // MARK: - 瀏覽器）" >&2
    exit 1
fi
# jsc 遇到例外時不一定以非 0 結束：以最後的 PASS 行判斷
run() {
    local expected=$1; shift
    local output
    output=$($JSC "$@" 2>&1) || true
    print -r -- "$output"
    [[ "$output" == *"$expected"* ]]
}
run "ALL PASS" $OUT/mapping.js Tests/WebExample/mapping-tests.js
# 整個頁面腳本（DOM／WebSocket 替身）
sed -n '/^<script>$/,/^<\/script>$/p' Examples/web/index.html | sed '1d;$d' > $OUT/page.js
run "PAGE ALL PASS" Tests/WebExample/page-tests.js $OUT/page.js Tests/WebExample/page-tests-run.js
