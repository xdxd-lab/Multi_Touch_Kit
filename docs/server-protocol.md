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
scripts/install-server-agent.sh [mtk-server 選項…]   # 例：scripts/install-server-agent.sh --no-tuio --display edid:6474:aa15
scripts/uninstall-server-agent.sh
```

安裝到 `~/Library/Application Support/MultiTouchKit/mtk-server`，LaunchAgent 標籤 `com.xdxd-lab.multitouchkit.server`，當機自動重啟，紀錄檔 `~/Library/Logs/mtk-server.log`。常駐時 mtk-server 會獨占觸控螢幕，Unity 等程式請改用 UDP 傳輸。由 launchd 啟動的 mtk-server 需要自己的「輸入監控」權限（每次重新安裝、簽章改變後可能需重新授權）。

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

每個 frame 包含所有仍在螢幕上的觸點（含 `stationary`）與這一次剛放開的觸點，所以單一 frame 就能得到完整狀態。所有手指離開後不再送 frame（不會送空 frame）。

## `device`：裝置加入／移除／重新初始化

```json
{"type":"device","v":1,"event":"added","device":{"id":1,"vendorId":8746,"productId":1,
 "manufacturer":"ILITEK","product":"ILITEK-TP","maxContacts":10,"slotsPerReport":10,
 "widthMM":309.3,"heightMM":173.9,"exclusive":true}}
```

`event`：`added`、`removed`、`reinitialized`（系統喚醒後，或偵測到控制器退回滑鼠模式時重新送出多點模式初始化）。`widthMM`／`heightMM` 為觸控面板實體尺寸，未知時省略。UDP 與 WebSocket 都會送。`--simulate` 不送 `device` 訊息。

## `hello`：WebSocket 連線後的第一則訊息（只有 WebSocket）

```json
{"type":"hello","v":1,"server":"mtk-server","version":"0.1.0",
 "devices":[{"id":1,"vendorId":8746,"productId":1,"manufacturer":"ILITEK","product":"ILITEK-TP",
             "maxContacts":10,"slotsPerReport":10,"widthMM":309.3,"heightMM":173.9,"exclusive":true}],
 "display":{"id":2,"name":"Sculptor (1)","edid":"6474:aa15:0","uuid":"2B0DA454-C0ED-4523-96BE-AFD4B00CD7FE",
            "main":false,"bounds":[1920,0,1920,1080],"pixels":[1920,1080],"hz":60}}
```

`display` 為觸控螢幕所在的顯示器（依 `--display` 選擇；找不到時省略）：`bounds` 是全域 Quartz 座標 `[x, y, 寬, 高]`（點，原點在主螢幕左上、y 向下），`pixels` 為目前解析度。把觸控換算成全域螢幕座標：`X = bounds[0] + x * bounds[2]`、`Y = bounds[1] + y * bounds[3]`。

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
| `Examples/web/index.html` | 瀏覽器開啟即可畫出觸點；`?ws=ws://主機:埠` 可覆寫網址 |
| Unity `UdpTransport` | 見 [unity.md](unity.md) |

2026-10-28 以 `--simulate` 驗證：3 秒內 UDP 376 則、WebSocket 377 則（含 hello）、TUIO 376 個 bundle，frame 間隔中位數 8.00 ms。
