#!/bin/zsh
# 編譯 Examples/c/basic.c 並連結 libMultiTouchKitC.dylib（驗證 C 標頭與 ABI）。
# 用法：scripts/build-c-example.sh [秒數]  → 編譯後執行
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product MultiTouchKitC
BIN=.build/release
clang -Wall -Wextra -Werror -O2 -I Sources/CMultiTouchKit/include Examples/c/basic.c \
    -L "$BIN" -lMultiTouchKitC -Wl,-rpath,"$PWD/$BIN" -o "$BIN/mtk-c-example"
echo "已建置：$BIN/mtk-c-example"
if [[ $# -gt 0 ]]; then "$BIN/mtk-c-example" "$1"; fi
