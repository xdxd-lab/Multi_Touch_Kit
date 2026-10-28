# mtk-server 使用說明與協定格式

`mtk-server` 獨占觸控螢幕，把觸控以三種格式廣播給其他程式。適合多個程式同時使用觸控、網頁、TUIO App，或在沒有觸控螢幕時用 `--simulate` 開發。

## 執行

```sh
swift build -c release --product mtk-server
.build/release/mtk-server                 # UDP 127.0.0.1:7777、WebSocket 7778、TUIO 127.0.0.1:3333
.build/release/mtk-server --simulate      # 模擬觸控（125 Hz：一指畫圓、一指滑動、四個鼓面輪流點擊）
```

| 選項 | 說明 |
|---|---|
| `--udp HOST:PORT` | UDP JSON 目的地，可重複（預設 `127.0.0.1:7777`）；IPv6 寫成 `[::1]:7777` |
| `--no-udp` | 不送 UDP JSON |
| `--ws PORT` | WebSocket 埠（預設 7778） |
| `--ws-lan` | WebSocket 開放給區網（預設只接受本機） |
| `--no-ws` | 不開 WebSocket |
| `--tuio HOST:PORT` | TUIO 1.1 目的地（預設 `127.0.0.1:3333`） |
| `--no-tuio` | 不送 TUIO |
| `--vid N`／`--pid N` | 只使用指定的 Vendor／Product ID（可寫 `0x222A`） |
| `--shared` | 不獨占裝置（系統游標仍會跟著動） |
| `--display SEL` | 觸控螢幕所在的顯示器，放在 hello 的 `display` 欄位（預設 `auto` 或環境變數 `MTK_DISPLAY`；格式見 [c-api.md 顯示器對應](c-api.md#顯示器對應)） |
| `--list-displays` | 列出顯示器（id、名稱、解析度、EDID、實體尺寸）後離開 |
| `--simulate` | 使用模擬觸控（模擬面板尺寸沿用 MF156LR 的 309x174mm，`auto` 會選到與實機相同的顯示器） |
| `--verbose` | 印出每個觸控事件 |
| `--stale-touch-timeout SEC` | 觸點幾乎不動超過 SEC 秒就以 cancelled 取消（線材等幽靈觸點；預設 30，0 = 關閉；見 [c-api.md 誤觸](c-api.md#誤觸長時間不動的觸點與放開遺失)） |
| `--gestures` | 同時把觸控合成為系統操作（點擊、捲動、縮放等），見 [gestures.md](gestures.md) |
| `--gestures-dry-run`／`--gestures-swipe dock\|keys`／`--gestures-exclude BUNDLE_ID[,…]` | 手勢選項，見 [gestures.md](gestures.md) |
| `--release-buttons` | 送出左／右／中鍵放開後離開（手勢模式異常結束、滑鼠鍵卡住時的復原，見 [gestures.md](gestures.md)） |
| `--simulate-pattern drums\|gestures` | 模擬觸控的模式（隱含 `--simulate`；預設 `drums`）。`gestures` 依序做出各種手勢（手勢一律 dry-run） |

`Ctrl+C`、SIGTERM、SIGHUP（關閉終端機）、SIGQUIT 都會先放開手勢按住的滑鼠鍵、釋放裝置再結束。

### 登入後自動執行（LaunchAgent）

```sh
scripts/create-signing-identity.sh                   # 第一次：建立固定的簽章身分（只需一次，見下方）
scripts/install-server-agent.sh [mtk-server 選項…]   # 例：scripts/install-server-agent.sh --no-tuio --display edid:6474:aa15
scripts/uninstall-server-agent.sh
```

安裝為 `~/Library/Application Support/MultiTouchKit/MultiTouchKit Server.app`（bundle ID 與 LaunchAgent 標籤都是 `com.xdxd-lab.multitouchkit.server`，沒有 Dock 圖示），LaunchAgent 執行其中的 `Contents/MacOS/mtk-server`，當機自動重啟，紀錄檔 `~/Library/Logs/mtk-server.log`。常駐時 mtk-server 會獨占觸控螢幕，Unity 等程式請改用 UDP 傳輸。舊版安裝的純執行檔 `…/MultiTouchKit/mtk-server` 會在安裝時自動移除。

#### 授權與簽章

由 launchd 啟動的 mtk-server 需要自己的「輸入監控」權限（使用 `--gestures` 時另需「輔助使用」）。啟動時 mtk-server 會主動請求，
系統會把 **MultiTouchKit Server** 加入 系統設定 → 隱私權與安全性 的這兩個清單並跳出詢問：**在清單中打開它的開關即可**。
授權在已執行的程序內不會生效（觸控介面不需要「輸入監控」也能開啟，但一併獨占的滑鼠相容介面需要；原本的程序中仍會失敗），
所以 mtk-server 每 3 秒以子程序檢查一次，發現新取得的授權就正常收尾並結束，由 LaunchAgent 以新的程序重新啟動
（launchd 的節流可能讓重新啟動延後到約 10 秒；紀錄檔會出現「授權：已取得…」「結束並由 LaunchAgent 重新啟動」）。
手動重新啟動：`launchctl kickstart -k gui/$UID/com.xdxd-lab.multitouchkit.server`。
清單中沒有出現時，可用「＋」選取 `~/Library/Application Support/MultiTouchKit/MultiTouchKit Server.app`（在選檔視窗按 ⌘⇧G 輸入路徑）。
紀錄檔中的「授權：」開頭訊息會說明目前缺少哪一項。

從終端機執行 mtk-server 時，授權的對象是終端機 App（Terminal、iTerm2 等），不是 MultiTouchKit Server。

macOS 記錄授權時看的是程式的簽章身分（designated requirement），不是路徑：

| 簽章 | 簽章身分 | 更新（重新建置後安裝）時 |
|---|---|---|
| ad-hoc（沒有建立簽章身分時） | 內容的雜湊，每次建置都不同 | **每次都要重新授權** |
| 本機自簽憑證「MultiTouchKit Local Signing」 | identifier `com.xdxd-lab.multitouchkit.server`＋憑證，固定 | 授權持續有效 |

1. 執行一次 `scripts/create-signing-identity.sh`：在 login keychain 建立 10 年期的自簽程式碼簽章憑證，並允許 codesign 使用它的私鑰（會詢問一次登入密碼；略過時第一次簽章會跳出詢問，按「永遠允許」）。憑證不需要設為信任，只用於本機，Gatekeeper 不接受（本機建置、由 launchd 啟動的程式不經過 Gatekeeper）。
2. 執行 `scripts/install-server-agent.sh`，它會自動使用這個身分，並印出「簽章身分沒有改變，授權仍有效」或「需要重新授權」。第一次安裝（或從 ad-hoc 改為固定身分）時，在清單中打開 MultiTouchKit Server 的開關。
3. 之後的更新都不必再授權。

- 已有 Apple Development／Developer ID 憑證時，可用 `MTK_SIGN_IDENTITY="憑證名稱" scripts/install-server-agent.sh …` 改用它。
- 移除：`scripts/create-signing-identity.sh --remove`（之後安裝回到 ad-hoc）。
- 安全性：能讀取你 login keychain 的人可以用這個憑證簽出相同身分的程式，並沿用這兩項授權；這等同已經能控制你的帳號。不再需要時請移除。

## 共通

- 所有訊息都是 UTF-8 JSON 物件，`type` 區分種類，`v` 為協定版本（目前 1）。新版本只會**新增**欄位，用戶端請忽略不認識的欄位。
- UDP：每個 datagram 一則訊息。WebSocket：每個 text frame 一則訊息。
- 時間 `t` 為奈秒，`mach_absolute_time` 時基；同一台 Mac 上與 C API 的 `mtk_now_ns()`、Swift 的 `MultiTouchClock.now()` 可直接比較。
- 座標 `x`、`y` 為 0...1，原點在觸控面板左上角。

## `frame`：一次觸控掃描（約每 8 ms）

```json
{"type":"frame","v":1,"device":1,"seq":1234,"t":5123456789012,"scan":263280,
 "touches":[
  {"id":17,"cid":0,"phase":"began","x":0.41250,"y":0.73333,"rx":3960,"ry":7040},
  {"id":16,"cid":1,"phase":"stationary","x":0.20000,"y":0.80000,"rx":1920,"ry":7680}
 ]}
```

| 欄位 | 說明 |
|---|---|
| `device` | 裝置編號（從 1 開始；`--simulate` 為 0） |
| `seq` | 每個裝置各自遞增 |
| `t` | 收到 HID 報告的時間（奈秒）。節奏遊戲判定請用它而不是收到訊息的時間 |
| `scan` | 控制器 Scan Time（通常 100 µs 單位）；裝置不支援時省略 |
| `touches[].id` | 每次觸碰唯一（從 1 遞增）；追蹤手指用它 |
| `touches[].cid` | 控制器 Contact Identifier，放開後會重複使用 |
| `touches[].phase` | `began`、`moved`、`stationary`、`ended`、`cancelled` |
| `touches[].x`, `y` | 0...1（小數 5 位） |
| `touches[].rx`, `ry` | 控制器原始座標（ILITEK 為 0...9600） |
| `touches[].p`, `w`, `h`, `conf` | 壓力、寬、高（0...1）、是否為有意觸碰；裝置支援才有（ILITEK 沒有） |
| `touches[].ux`, `uy` | 套用觸控校正前的 x、y；只在該裝置套用校正時才有（`x`、`y` 為校正後的值）。校正工具（`mtk-viewer --calibrate`）以它收集原始位置 |

每個 frame 包含所有仍在螢幕上的觸點（含 `stationary`）與這一次剛放開的觸點，所以單一 frame 就能得到完整狀態。所有手指離開後不再送 frame（不會送空 frame）。

## `device`：裝置加入／移除／重新初始化

```json
{"type":"device","v":1,"event":"added","device":{"id":1,"vendorId":8746,"productId":1,
 "manufacturer":"ILITEK","product":"ILITEK-TP","serial":"","locationId":1048576,"maxContacts":10,"slotsPerReport":10,
 "widthMM":309.3,"heightMM":173.9,"exclusive":true,"calibrated":true}}
```

`event`：`added`、`removed`、`reinitialized`（系統喚醒後，或偵測到控制器退回滑鼠模式時重新送出多點模式初始化；套用的觸控校正改變時也會送出）。
`serial`（沒有時為空字串）、`locationId`（USB 位置）用來識別裝置；`calibrated` 表示正在套用觸控校正。`widthMM`／`heightMM` 為觸控面板實體尺寸，未知時省略。UDP 與 WebSocket 都會送。`--simulate` 不送 `device` 訊息。

## `hello`：WebSocket 連線後的第一則訊息（只有 WebSocket）

```json
{"type":"hello","v":1,"server":"mtk-server","version":"0.1.0",
 "devices":[{"id":1,"vendorId":8746,"productId":1,"manufacturer":"ILITEK","product":"ILITEK-TP",
             "serial":"","locationId":1048576,"maxContacts":10,"slotsPerReport":10,"widthMM":309.3,"heightMM":173.9,
             "exclusive":true,"calibrated":true}],
 "display":{"id":2,"name":"Sculptor (1)","edid":"6474:aa15:0","uuid":"2B0DA454-C0ED-4523-96BE-AFD4B00CD7FE",
            "main":false,"bounds":[1920,0,1920,1080],"pixels":[1920,1080],"hz":60}}
```

`display` 為觸控螢幕所在的顯示器（依 `--display` 選擇；找不到時省略）：`bounds` 是全域 Quartz 座標 `[x, y, 寬, 高]`（點，原點在主螢幕左上、y 向下），`pixels` 為目前解析度。把觸控換算成全域螢幕座標：`X = bounds[0] + x * bounds[2]`、`Y = bounds[1] + y * bounds[3]`。

## `display`：觸控螢幕對應的顯示器改變（只有 WebSocket）

```json
{"type":"display","v":1,"display":{"id":2,"name":"Sculptor (1)","edid":"6474:aa15:0", … ,"bounds":[1920,0,1920,1080],"pixels":[1920,1080],"hz":60}}
```

hello 只在連線時送一次；之後對應的顯示器改變時另外送出，內容與 hello 的 `display` 相同（找不到顯示器時為 `null`）。
常見情況：觸控螢幕晚於 `mtk-server` 接上（例如原本被 Unity 獨占），`auto` 從主螢幕改為觸控螢幕；或在「顯示器」設定中重新排列。
需要換算螢幕座標的用戶端請以最後收到的 `display` 為準。

用戶端送給伺服器的訊息一律忽略。

## TUIO 1.1

`/tuio/2Dcur` profile，每個 frame 一個 OSC bundle（時間標記 = 立即）：

```
/tuio/2Dcur source MultiTouchKit@<主機名稱>
/tuio/2Dcur alive <s_id…>            所有仍在螢幕上的觸點
/tuio/2Dcur set <s_id> x y X Y m     這個 frame 按下或移動的觸點（速度 X、Y 為每秒正規化單位，m 固定 0）
/tuio/2Dcur fseq <frame 編號>
```

`s_id` = 觸碰 `id` 的低 31 位元。座標 0...1、原點左上（TUIO 標準）。

## 範例用戶端

| 檔案 | 說明 |
|---|---|
| `Examples/python/udp_receiver.py [PORT]` | 印出 UDP JSON |
| `Examples/python/ws_client.py [ws://127.0.0.1:7778] [秒數]` | 只用標準函式庫的 WebSocket 用戶端 |
| `Examples/python/tuio_receiver.py [PORT] [秒數]` | 內含極簡 OSC 解碼 |
| `Examples/web/index.html` | 瀏覽器開啟即可畫出觸點；`?ws=ws://主機:埠` 可覆寫網址、`?debug` 顯示診斷。位置換算見下節 |
| Unity `UdpTransport` | 見 [unity.md](unity.md) |

### 網頁範例的位置對齊

觸點座標是「整片觸控面板」的 0..1，網頁的內容區（viewport）通常不等於整片面板：視窗模式時只佔一部分；Safari 以綠色按鈕全螢幕時，若「顯示方式 → 在全螢幕中永遠顯示工具列」開著，頂部的工具列／分頁列仍會佔用。
若直接以 `x × 畫布寬`、`y × 畫布高` 換算，就會出現系統性偏差，例如「底部最準、越往上越偏下」。範例的做法：

1. **建議**：把瀏覽器視窗移到觸控螢幕，按 **F**（或右上角「全螢幕」按鈕）以 Fullscreen API 全螢幕。內容區就是整個螢幕，直接相乘即可，各瀏覽器都準。
2. 其他情況（視窗模式、Safari 綠色按鈕全螢幕）：以 `display.bounds` 與視窗位置（`screenX`／`screenY`，加上視窗外框與內容區的高度差＝上方工具列）換算出觸點在內容區中的位置，與 Unity 的 KeyWindow 模式相同。前提是頁面縮放為 100%，且開發者工具沒有停靠在側邊或下方；不符合時畫面上會出現警告。
3. 按 **D**（或網址加 `?debug`）顯示診斷資訊（換算方式、bounds、視窗與內容區的位置、devicePixelRatio）與 9 個校正十字：觸碰十字中心，圓點應落在十字上。

換算邏輯的測試：`scripts/test-web-example.sh`（以 macOS 內建、Safari 所用的 JavaScriptCore 執行）。

2026-10-28 以 `--simulate` 驗證：3 秒內 UDP 376 則、WebSocket 377 則（含 hello）、TUIO 376 個 bundle，frame 間隔中位數 8.00 ms。
