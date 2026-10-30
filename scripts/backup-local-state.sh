#!/bin/zsh
# 把 GitHub 上沒有、又無法重建的本機資料打包成 zip，供換機時還原（見 docs/migration.md）。
# 收錄：觸控校正、實機量測原始資料、Unity 測試專案（不含 Library 等快取）。
# 不收錄：簽章私鑰、常駐服務、建置產物（新機重新建立）。
#
# 用法：scripts/backup-local-state.sh [--list] [-o 輸出路徑]
#   --list   只列出會收錄的檔案，不產生 zip
#   -o PATH  zip 輸出路徑（預設 ~/MultiTouchKit-local-state-<日期>.zip）
set -euo pipefail

list_only=0
out="$HOME/MultiTouchKit-local-state-$(date +%Y%m%d).zip"
while (( $# )); do
    case "$1" in
        --list) list_only=1 ;;
        -o) shift; out="${1:?-o 需要輸出路徑}" ;;
        *) print -u2 "未知選項：$1"; exit 2 ;;
    esac
    shift
done

# 備份項目：「zip 內路徑|本機路徑」。本機路徑不存在時略過並提示。
# zip 內路徑以 home/ 開頭，對應還原時的 $HOME，換機後使用者名稱不同也能還原。
items=(
    "home/Library/Application Support/MultiTouchKit/calibration.json|$HOME/Library/Application Support/MultiTouchKit/calibration.json"
    "home/ilitek-probe.csv|$HOME/ilitek-probe.csv"
    "home/Projects/MultiTouchKitUnityTest/Assets|$HOME/Projects/MultiTouchKitUnityTest/Assets"
    "home/Projects/MultiTouchKitUnityTest/Packages|$HOME/Projects/MultiTouchKitUnityTest/Packages"
    "home/Projects/MultiTouchKitUnityTest/ProjectSettings|$HOME/Projects/MultiTouchKitUnityTest/ProjectSettings"
)

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
root="$stage/MultiTouchKit-local-state"
mkdir -p "$root"

for item in "${items[@]}"; do
    dest="${item%%|*}" src="${item#*|}"
    if [[ ! -e "$src" ]]; then
        print -u2 "略過（不存在）：$src"
        continue
    fi
    mkdir -p "$root/${dest:h}"
    cp -R "$src" "$root/$dest"
done

{
    print "# MultiTouchKit 本機資料備份"
    print "建立時間：$(date '+%Y-%m-%d %H:%M:%S %z')"
    print "機器：$(sysctl -n hw.model)，macOS $(sw_vers -productVersion)（$(sw_vers -buildVersion)）"
    print "還原：scripts/restore-local-state.sh <此 zip>"
    print
    print "# SHA-256  路徑"
    (cd "$root" && find home -type f -print0 | sort -z | xargs -0 shasum -a 256)
} > "$root/MANIFEST.txt"

if (( list_only )); then
    (cd "$root" && find home -type f | sort)
    exit 0
fi

rm -f "$out"
(cd "$stage" && zip -q -r -X "$out" MultiTouchKit-local-state)
print "已建立：$out（$(du -h "$out" | cut -f1)）"
