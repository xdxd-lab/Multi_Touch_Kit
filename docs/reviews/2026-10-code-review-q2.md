# MultiTouchKit 程式碼審查 Q2（2026-10-29，main fbc8148）

範圍：Q1（[2026-10-code-review.md](2026-10-code-review.md)）之後新增的程式，審查標準與 Q1 相同：
- W1 網頁範例：`Examples/web/index.html`、`Tests/WebExample/`
- `display` 訊息：`TouchJSON.display`、`mtk-server` 的廣播
- L1／L2 簽章與 app：`scripts/create-signing-identity.sh`、`scripts/install-server-agent.sh`、`scripts/uninstall-server-agent.sh`、`scripts/lib/sign-server.sh`、`scripts/lib/server-app.sh`
- `Sources/mtk-server/Permissions.swift`（授權請求與 PermissionWatcher）

另外重新量測記憶體與 CPU，並依量測結果決定 Q1 中「未做」的低優先項。

## 量測

方法與 Q1 相同（`/usr/bin/time -l -p perl -e 'alarm 15; exec @ARGV' .build/release/mtk-server --simulate …`，每項 15 秒）。

| 設定 | user (s) | sys (s) | 合計占單核 | maxRSS |
|---|---|---|---|---|
| 輸出全開（UDP／WS／TUIO） | 0.04 | 0.12 | 1.1% | 17.8 MB |
| 輸出全關 | 0.03 | 0.06 | 0.6% | 16.9 MB |
| 手勢 dry-run（`--simulate-pattern gestures --gestures-dry-run`，輸出全關） | 0.04 | 0.09 | 0.9% | 17.0 MB |
| 手勢（模擬時一律 dry-run），輸出全關 | 0.03 | 0.07 | 0.7% | 16.8 MB |

- Q1 前（b80ac9e）輸出全開為 3.9%；本輪修正後全開為 user 0.04／sys 0.11，與修正前相同。本輪沒有效能改動。
- `leaks --atExit`：`--simulate` 與手勢 dry-run 都是 **0 leaks**（約 5.7k 個配置、1.0 MB）。
- Unity 離線（`scripts/test-unity-offline.sh`）：UdpTransport 3 指／10 指皆 **0 B/封包**。

### Q1「未做」項目的決定

| 項目 | 決定 | 理由 |
|---|---|---|
| B12 手勢辨識器每 frame 的配置 | 不做 | 手勢路徑相對輸出全關只多約 0.1–0.3%，在量測誤差範圍內；改寫會增加辨識器的複雜度與回歸風險 |
| ScreenMapping 的 CGDisplayBounds 快取（GestureController、mtk-viewer） | 不做 | 同上，量不到效益；且快取需要處理顯示器重新設定，增加出錯機會 |
| DisplaySelector 的 Hashable 只比較 criteria | 不做 | 會改變現有的相等語意（Q1 已決定） |

## 發現與修正

| # | 位置 | 問題 | 修正 | 風險 |
|---|---|---|---|---|
| R1 | `Examples/web/index.html` 的 `connect` | WebSocket 斷線時沒有清除觸點：mtk-server 被強制結束或重新啟動時，最後的 ended 不會送達，畫面留下幽靈圓點（與 Q1 A7 的 Unity UDP 同類） | `onclose` 清除觸點與擴散圈 | 行為（bug 修正） |
| R2 | `Examples/web/index.html` 的 `draw` | 收過 frame 之後，HUD 每幀都會被重寫，「連線中斷，2 秒後重試」只會閃一下，使用者看不到斷線狀態 | 以 `connected` 狀態組 HUD 第一行 | 行為（bug 修正） |
| R3 | 同上 | HUD 每幀重設 `textContent`，即使內容沒變也會造成版面重算 | 內容改變時才更新 | 無 |
| R4 | `scripts/create-signing-identity.sh --remove` | `security delete-identity -c` 以名稱的子字串比對，可能刪到名稱相近的其他憑證 | 以 SHA-1（`-Z`）逐一刪除名稱完全相同的身分；以暫時 keychain 加入誘餌憑證「MultiTouchKit Local Signing Backup」驗證只刪除目標 | 無 |
| R5 | `Sources/mtk-server/ServerMain.swift` 的 PermissionWatcher 回呼 | 取得「輸入監控」授權後一律重開 manager：若裝置在授權前已能開啟（觸控螢幕可能不受此授權限制），會取消正在觸碰的手指一次 | 只在沒有任何已開啟的裝置時才重開 | 無 |
| R6 | `scripts/install-server-agent.sh` | 先刪除舊 app 再移入新 app：移入失敗時兩者都不在，LaunchAgent 也起不來 | 舊版先改名為 `.…app.old`，新版就位後才刪除，失敗時還原 | 無 |

檢查後沒有問題的部分：
- `display` 訊息：在主執行緒解析、在觸控來源的佇列上廣播，與 WebSocketHub 的執行緒規則一致；DisplayInfo 的相等比較包含 bounds，重新排列顯示器時也會送出。
- 網頁範例的換算（`mapTouch`／`viewportOnScreen`）：與 `scripts/test-web-example.sh` 的 17 項換算測試、加上整頁測試一致。
- `sign-server.sh`：codesign 失敗時中止、簽章身分的比較、ad-hoc 後備（L1／L2 已修正並測試）。
- `server-app.sh`：Info.plist 以 `plutil -lint` 檢查；bundle 以 `codesign --verify --deep --strict` 驗證。

## 驗證

- `./scripts/test.sh` 112/112、`./scripts/test-web-example.sh`（換算 17 項＋整頁 9 項）、`./scripts/check-signals.sh`、`./scripts/test-unity-offline.sh` 全部通過，release 建置沒有警告。
- R6 的安裝流程依指示沒有在本機實際執行（常駐的 LaunchAgent 正在使用中），只做了語法檢查；下次由使用者執行 `install-server-agent.sh` 時一併確認。

## 第 2 批：品牌視覺（2026-10-29，merge 834e027）

| 項目 | 內容 |
|---|---|
| 品牌圖示 | 深色圓角方塊上的五個指尖觸點與中央擴散圈，沿用 mtk-viewer 的觸控特效（色相 = id × 37°，取 id 1、3、5、7、9）。由 `Sources/MultiTouchKitArt` 以程式繪製，同一份幾何輸出 PNG 與 SVG；`scripts/generate-art.sh` 重新產生後位元組完全相同（可重現） |
| 產出 | `Assets/Brand`：`MultiTouchKit.icns`、`MultiTouchKit-1024.png`、`MultiTouchKit.svg`、`banner-dark.svg`／`banner-light.svg`；`Examples/web/favicon.svg`；Unity `Editor/Icons/MultiTouchKitManager.png` |
| 套用 | MultiTouchKit Server.app 的 `AppIcon.icns`（`CFBundleIconFile`）；mtk-viewer 的 Dock 圖示；Unity `MultiTouchKitManager` 元件圖示；README 頂部 banner（`<picture>` 依 GitHub 深淺色切換） |
| 網頁範例 | 毛玻璃 HUD 面板（品牌圖示＋連線狀態燈）、膠囊式全螢幕按鈕、深淺色主題（深色維持 mtk-viewer 的黑底） |

### macOS 26 的圖示外框

macOS 26 會把輪廓不符系統遮罩的舊式 `.icns` 放進灰色外框。實測：
- superellipse（n=5）的外形，以及滿版方形、無陰影的版本，都被加上外框。
- 量測只有 `.icns` 的第三方 App（VS Code）的 alpha 輪廓：本體 824 × 824，轉角與半徑 185 的圓角相差不到 2 px。
- 改用 Apple 圖示範本的圓角（185.4）後，系統直接顯示並加上玻璃邊緣（有陰影與無陰影皆可，採用有陰影版）。

`Assets.car`（Icon Composer 的分層圖示）需要完整 Xcode 的 actool，目前環境只有 Command Line Tools，所以維持 `.icns`。

### 驗證

p2：`test.sh` 112/112、`test-web-example.sh`（新增狀態燈 2 項）、`test-unity-offline.sh`（Runtime 3 組＋Samples 編譯、0 B/封包）、`check-signals.sh`、release 無警告、`generate-art.sh` 可重現、icns 含 10 種尺寸、Unity 元件圖示 GUID 相符。網頁深淺色以 WKWebView 截圖確認；p1 目視覆核圖示 256 與 32@2x。

### 待使用者實機目視

- MultiTouchKit Server.app 在 系統設定 →「輸入監控」「輔助使用」清單與「登入項目」中的圖示（下次執行 `install-server-agent.sh` 時；同時確認第 1 批「保留舊 app 直到新版就位」的安裝流程）
- mtk-viewer 的 Dock 圖示
- 網頁範例在 Safari 中的 favicon、HUD 面板與深淺色
- GitHub 上 README banner 的深色與淺色主題
- Unity Inspector 與 Add Component 選單中 MultiTouchKitManager 的圖示
