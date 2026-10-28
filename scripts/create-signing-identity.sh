#!/bin/zsh
# 建立本機自簽的程式碼簽章憑證「MultiTouchKit Local Signing」（只需要執行一次）。
# install-server-agent.sh 會用它簽 mtk-server：簽章身分固定，重新建置、安裝後「輔助使用」「輸入監控」的授權仍有效
# （ad-hoc 簽章每次更新都要重新授權；原理見 scripts/lib/sign-server.sh）。
#
# 用法：scripts/create-signing-identity.sh            建立（已存在時不做任何事）
#       scripts/create-signing-identity.sh --remove   移除憑證與私鑰
#
# 會動到 login keychain：匯入一張憑證與它的私鑰，並允許 codesign 使用該私鑰而不跳出詢問（只限這把私鑰，會詢問一次登入密碼；
# 略過的話第一次簽章時會跳出「codesign 想要使用金鑰」視窗，按「永遠允許」即可）。
# 憑證不需要設為信任，也不會被系統其他地方使用；能讀取你 login keychain 的人才能用它簽章。
#
# 環境變數（只在測試時使用）：MTK_SIGN_KEYCHAIN（keychain 路徑）、MTK_SIGN_KEYCHAIN_PASSWORD（該 keychain 的密碼）
set -euo pipefail
NAME="MultiTouchKit Local Signing"
KEYCHAIN=${MTK_SIGN_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}

exists() {
    security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$NAME\""
}

if [[ "${1:-}" == "--remove" ]]; then
    if ! exists; then
        echo "沒有「$NAME」，不需要移除"
        exit 0
    fi
    # 以 SHA-1 逐一刪除名稱完全相同的身分：delete-identity -c 是子字串比對，可能刪到名稱相近的其他憑證
    security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\"" | awk '{print $2}' | sort -u | while read -r hash; do
        security delete-identity -Z "$hash" "$KEYCHAIN" >/dev/null
    done
    echo "已移除「$NAME」。之後 install-server-agent.sh 會改用 ad-hoc 簽章（每次更新都要重新授權）"
    exit 0
elif [[ $# -gt 0 ]]; then
    echo "用法：scripts/create-signing-identity.sh [--remove]" >&2
    exit 2
fi

if exists; then
    echo "「$NAME」已存在，不需要重新建立"
    exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mtk-signing.XXXXXX")
trap 'rm -f "$WORK"/key.pem "$WORK"/cert.pem "$WORK"/identity.p12; rmdir "$WORK"' EXIT
# p12 只在這個程序中短暫使用，用隨機密碼保護
PASS=$(openssl rand -hex 16)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" -passout "pass:$PASS"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "允許 codesign 使用這把私鑰而不跳出詢問（只限「$NAME」）："
if [[ -n "${MTK_SIGN_KEYCHAIN_PASSWORD:-}" ]]; then
    security set-key-partition-list -S apple-tool:,apple: -s -l "$NAME" -k "$MTK_SIGN_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
elif ! security set-key-partition-list -S apple-tool:,apple: -s -l "$NAME" "$KEYCHAIN" >/dev/null; then
    echo "  略過（第一次簽章時會跳出詢問，按「永遠允許」）"
fi

exists || { echo "建立失敗：找不到「$NAME」" >&2; exit 1; }
security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\"" | sed 's/^ *[0-9]*) /已建立：/'
echo "接著執行 scripts/install-server-agent.sh [選項…]，最後再授權一次「輸入監控」（與「輔助使用」），之後的更新都不必再授權"
