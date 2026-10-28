# mtk-server 的簽章（由 install-server-agent.sh 以 source 載入）。
#
# 為什麼：macOS 的「輔助使用」「輸入監控」授權記錄的是程式的 designated requirement（DR），不是路徑。
# ad-hoc 簽章的 DR 是內容的雜湊（cdhash），每次重建都不同，授權就失效；以固定的憑證簽章時，
# DR 只包含 identifier 與憑證（identifier "…" and certificate leaf = H"…"），重建後不變，授權持續有效。
# 憑證由 scripts/create-signing-identity.sh 建立（本機自簽，不需要被信任；只供本機使用，Gatekeeper 不接受）。
#
# 環境變數：
#   MTK_SIGN_IDENTITY   簽章身分（預設 "MultiTouchKit Local Signing"；可改為自己的 Apple Development／Developer ID）
#   MTK_SIGN_KEYCHAIN   只在測試時使用：改用指定的 keychain（預設搜尋清單中的 keychain，通常是 login）。
#                       codesign 只找得到搜尋清單中的 keychain，測試時須先以 security list-keychains -s 加入（測完還原）

MTK_SIGN_DEFAULT_IDENTITY="MultiTouchKit Local Signing"
MTK_SIGN_IDENTIFIER=com.xdxd-lab.multitouchkit.server

# 簽章身分存在時回傳 0（自簽憑證不受信任，所以不能用 find-identity -v）
mtk_sign_identity_exists() {
    local identity=$1
    security find-identity -p codesigning ${MTK_SIGN_KEYCHAIN:+"$MTK_SIGN_KEYCHAIN"} 2>/dev/null | grep -qF "\"$identity\""
}

# 程式的 designated requirement；ad-hoc 時 codesign 以「# designated => cdhash …」顯示
mtk_designated_requirement() {
    [[ -f "$1" ]] || return 0
    codesign -d -r- "$1" 2>&1 | sed -n 's/^#* *designated => //p'
}

# 為 $1 簽章。印出使用的身分；指定的 MTK_SIGN_IDENTITY 不存在時失敗
mtk_sign_server() {
    local file=$1 identity=${MTK_SIGN_IDENTITY:-$MTK_SIGN_DEFAULT_IDENTITY}
    local output keychain=()
    # zsh 不會對 ${VAR:+…} 分詞，所以用陣列傳遞選項
    [[ -n "${MTK_SIGN_KEYCHAIN:-}" ]] && keychain=(--keychain "$MTK_SIGN_KEYCHAIN")
    if mtk_sign_identity_exists "$identity"; then
        # 失敗時（例如私鑰存取被拒）必須中止：否則檔案保留連結器的 ad-hoc 簽章，使用者會以為已改用固定身分
        if ! output=$(codesign --force --sign "$identity" --identifier $MTK_SIGN_IDENTIFIER $keychain "$file" 2>&1); then
            echo "以「$identity」簽章失敗：$output" >&2
            return 1
        fi
        echo "$identity"
    elif [[ -n "${MTK_SIGN_IDENTITY:-}" ]]; then
        echo "找不到簽章身分「$MTK_SIGN_IDENTITY」（MTK_SIGN_IDENTITY）" >&2
        return 1
    else
        if ! output=$(codesign --force --sign - --identifier $MTK_SIGN_IDENTIFIER "$file" 2>&1); then
            echo "ad-hoc 簽章失敗：$output" >&2
            return 1
        fi
        echo "ad-hoc"
    fi
}

# 比較安裝前後的 DR，說明授權是否仍有效
mtk_report_authorization() {
    local before=$1 after=$2 identity=$3
    if [[ -z "$before" ]]; then
        echo "第一次安裝：請到 系統設定 → 隱私權與安全性，在「輸入監控」（以及使用 --gestures 時的「輔助使用」）允許 mtk-server"
    elif [[ "$before" == "$after" ]]; then
        echo "簽章身分沒有改變：「輔助使用」「輸入監控」的授權仍有效"
    else
        echo "簽章身分改變了，需要重新授權：系統設定 → 隱私權與安全性 → 輸入監控（以及輔助使用），移除 mtk-server 後重新加入"
        echo "  之前：$before"
        echo "  現在：$after"
    fi
    if [[ "$identity" == "ad-hoc" ]]; then
        echo "注意：目前是 ad-hoc 簽章，之後每次更新都要重新授權。執行一次 scripts/create-signing-identity.sh 建立固定的簽章身分即可避免"
    fi
}
