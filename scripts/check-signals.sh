#!/bin/zsh
# 檢查 mtk-server／mtk-probe／mtk-viewer 收到 SIGINT／SIGTERM／SIGHUP 時都會正常收尾後結束
# （手勢放開滑鼠鍵、停止觸控來源、印出摘要）。也檢查「SIGINT 被繼承為忽略」的情況：
# 在 shell 腳本中以 & 背景啟動的程式就是如此，不自行處理的話 Ctrl-C／kill -INT 完全沒有作用。
# 一律使用 --simulate（不碰觸控硬體）；mtk-viewer 會短暫開啟全螢幕視窗。
# 用法：scripts/check-signals.sh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product mtk-server >/dev/null
swift build -c release --product mtk-probe >/dev/null
swift build -c release --product mtk-viewer >/dev/null
BIN=.build/release
failures=0
check() {
    local name=$1 signals=$2 result
    shift 2
    for mode in default ignored; do
        for sig in ${=signals}; do
            if result=$(perl scripts/lib/signal-exit.pl $mode $sig "$@"); then
                echo "OK  $name $mode SIG$sig：$result"
            else
                echo "NG  $name $mode SIG$sig：$result"
                failures=$((failures + 1))
            fi
        done
    done
}
check mtk-server "INT TERM HUP" $BIN/mtk-server --simulate --no-udp --no-ws --no-tuio
check mtk-probe "INT TERM" $BIN/mtk-probe --simulate --seconds 60
check mtk-viewer "INT TERM HUP" $BIN/mtk-viewer --simulate
if (( failures > 0 )); then
    echo "$failures 項失敗"
    exit 1
fi
echo "ALL PASS"
