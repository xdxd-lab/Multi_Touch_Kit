#!/bin/zsh
# 還原 scripts/backup-local-state.sh 產生的本機資料備份（見 docs/migration.md）。
# 先以 MANIFEST.txt 驗證 SHA-256，再把 MANIFEST 列出的 home/ 下檔案放回 $HOME；已存在的檔案預設不覆蓋。
#
# 用法：scripts/restore-local-state.sh [--force] [--dry-run] <備份 zip>
#   --force    覆蓋已存在的檔案
#   --dry-run  只列出會還原的檔案，不寫入
set -euo pipefail

force=0 dry=0 zip=""
while (( $# )); do
    case "$1" in
        --force) force=1 ;;
        --dry-run) dry=1 ;;
        -*) print -u2 "未知選項：$1"; exit 2 ;;
        *) zip="$1" ;;
    esac
    shift
done
[[ -f "$zip" ]] || { print -u2 "用法：$0 [--force] [--dry-run] <備份 zip>"; exit 2; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
unzip -q "$zip" -d "$stage"
root="$stage/MultiTouchKit-local-state"
[[ -f "$root/MANIFEST.txt" ]] || { print -u2 "不是 MultiTouchKit 本機資料備份：$zip"; exit 1; }

# 驗證完整性：MANIFEST 的雜湊行格式與 shasum 輸出相同
(cd "$root" && grep -E '^[0-9a-f]{64}  ' MANIFEST.txt | shasum -a 256 -c --quiet) \
    || { print -u2 "SHA-256 驗證失敗，停止還原"; exit 1; }
# 只還原 MANIFEST 列出（已驗證）的檔案；路徑必須在 home/ 之下且不含 ..，避免寫到 $HOME 以外
files=(${(f)"$(sed -n -E 's/^[0-9a-f]{64}  //p' "$root/MANIFEST.txt")"})
for rel in $files; do
    if [[ "$rel" != home/* || "/$rel/" == */../* ]]; then
        print -u2 "MANIFEST 中有不允許的路徑，停止還原：$rel"
        exit 1
    fi
done

restored=0 skipped=0
for rel in $files; do
    dest="$HOME/${rel#home/}"
    if [[ -e "$dest" ]] && (( ! force )); then
        print "略過（已存在）：$dest"
        (( skipped += 1 ))
        continue
    fi
    if (( dry )); then
        print "會還原：$dest"
    else
        mkdir -p "${dest:h}"
        cp -p "$root/$rel" "$dest"
    fi
    (( restored += 1 ))
done

print "完成：還原 $restored 個檔案，略過 $skipped 個$( (( dry )) && print '（dry run，未寫入）')"
