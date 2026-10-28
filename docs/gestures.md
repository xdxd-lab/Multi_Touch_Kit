# 系統層手勢合成

讓一般 macOS App（Finder、Safari、預覽程式、地圖等）也能用 MF156LR 觸控螢幕操作：點擊、拖曳、右鍵、捲動（含慣性）、縮放、旋轉、多指滑動。這是 `mtk-server` 的可選模式，**不加選項時既有的 Swift Package、C API、mtk-server 行為完全不變**。

## 快速開始

```sh
swift build -c release --product mtk-server

# 先確認辨識結果（只印出、不送事件）
.build/release/mtk-server --gestures-dry-run

# 啟用：觸控會變成系統操作，同時照常廣播 10 點（UDP／WebSocket／TUIO）
.build/release/mtk-server --gestures

# 不需要網路廣播時
.build/release/mtk-server --gestures --no-udp --no-ws --no-tuio

# 登入後自動執行
scripts/install-server-agent.sh --gestures
```

## 手勢對應

| 觸控 | 系統操作 | 送出方式 |
|---|---|---|
| 一指點擊 | 左鍵點擊（連點可雙擊、三擊） | 公開 API（CGEvent 滑鼠） |
| 一指移動 | 左鍵拖曳（移動超過約 14 點才按下，按下位置是手指起點） | 公開 API |
| 一指按住 0.6 秒以上再放開 | 右鍵點擊（以手指落下位置為基準、游標先移過去；放開時才確定；按住期間移動就變成拖曳，第二指落下就是兩指手勢） | 公開 API |
| 兩指點擊 | 右鍵點擊：以兩指**落下位置的中點**為基準，先把游標移過去再送右鍵，選單出現在該點 | 公開 API |
| 兩指平移 | 捲動，內容跟著手指走；放開時依速度產生慣性捲動 | 公開 API（像素捲動＋scroll／momentum phase） |
| 兩指開合 | 縮放（觸控板的 pinch） | **未公開** gesture 事件 |
| 兩指轉動（兩指繞中心轉，或一指為軸另一指繞著轉） | 旋轉 | **未公開** gesture 事件 |
| 三／四指左右滑 | 切換桌面（Space）／全螢幕 App | 預設 Control＋←／→；`--gestures-swipe dock` 為未公開 Dock 手勢 |
| 三／四指往上滑 | Mission Control | 預設 Control＋↑ |
| 三／四指往下滑 | App Exposé | 預設 Control＋↓ |

**三指與四指等價**：只依滑動方向對應（水平 → 切換桌面、往上 → Mission Control、往下 → App Exposé），手指數 3、4（含 5）都相同。這與 macOS 觸控板的預設一致（系統設定 → 觸控式軌跡板 → 更多手勢：「在全螢幕 App 之間滑動」與「Mission Control」預設都是三指或四指）。log 的 `swipe … 3指／4指` 只是記錄手指數，不影響行為。

兩指手勢的判定：
- 以**第二指落下當下**的兩指位置為起點（先放下的手指在第二指落下前的漂移不算進兩指手勢）。
- 兩指運動拆成「重心平移」與「指間向量的變化」：重心移動 ≥ 12 點且指間向量變化 < 0.5 倍重心位移，或重心移動 ≥ 24 點且 < 0.8 倍，才算捲動。以一指為軸旋轉或單指捏合時，指間向量變化約為重心位移的 2 倍，不會被當成捲動。
- 兩指同時接觸至少 80 ms 才判定縮放／旋轉（短暫的兩指觸碰不送）。縮放與旋轉先依「開合的徑向位移」與「旋轉的切向位移」決定主要的一個（旋轉為主需要切向位移 ≥ 25 點且 ≥ 1.5 倍徑向位移，捏合開始時的小角度抖動不會變成旋轉）；旋轉為主時，縮放要再變化超過 ×1.35（或 ×0.74）才一起送出；縮放為主時，旋轉要再超過 24°。兩指間距小於 60 點時角度雜訊太大，不送旋轉。
- 旋轉增益：送出的角度 = 手指轉動角度 × 1.5。兩指在觸控螢幕上不容易轉大角度（留指甲、手腕角度），觸控板約轉 45° 就能讓預覽程式轉 90°；1.5 讓手指轉 60° 等於 90°。可用 `--gestures-rotation-gain` 或 `Configuration.rotationGain` 調整。判定門檻（12°、24°）仍以手指的實際角度計算。
- 縮放增益：送出的倍率 =（指距倍率）^0.6。觸控螢幕可以從 50 點張到 600 點以上（×12），等比例送出會過於靈敏；0.6 讓 ×8 的張開約等於 ×3.5。可用 `--gestures-magnify-exponent` 或 `Configuration.magnifyExponent` 調整（1 = 等比例）。

- 捲動中一指暫時失去接觸（拖動時壓力不穩）：用剩下的手指繼續捲動，0.15 秒內重新落下的手指會接上；超過 0.15 秒才結束捲動。

一指的判定：按住時手指會慢慢漂移（例如先放軸心手指、停一下再放第二指旋轉），所以位移超過 14 點但最近速度低於 150 點／秒時不算拖曳，要到 40 點才按下；正常速度的拖曳在落下 0.12 秒後按下。按下位置一律是手指起點，不會遺失位移。

## 誤觸（手掌、手的其他部位）

ILITEK-TP 的 HID 描述子每個觸點只有 Contact ID、Tip Switch、X、Y，**沒有 Confidence、Width／Height、壓力**，無法由控制器判斷手掌。目前的處理：

| 情況 | 處理 |
|---|---|
| 同時超過 5 點 | 取消目前手勢（按住的滑鼠鍵放開、連續手勢 cancelled），忽略到所有手指離開 |
| 兩點一碰即離（等待期間就放開、位移 < 24 點） | 不當成捲動甩動 |
| 短暫的兩指觸碰（< 80 ms） | 不判定縮放／旋轉 |
| 手勢決定後新增的觸點（例如拖曳中手腕碰到） | 忽略 |
| 控制器回報 Confidence = false（其他面板） | 該觸點整個生命週期不參與手勢 |

尚未處理：單一點的短暫誤觸會被當成點擊（與真正的輕點無法區分）；若需要，可再加「點擊最短接觸時間」或「離目前手勢很遠的新觸點」規則，但會讓快速輕點失效，需實機資料再決定。

手指不會同時落下：第一指落下後 50 ms 內出現的手指算同一個手勢；手勢決定後新增的手指會被忽略，直到所有手指離開。捲動、縮放、旋轉前會先把游標移到兩指中點（系統把這些事件送給游標下方的視窗）。手指碰到螢幕會立刻停止慣性捲動。

## 選項

| 選項 | 說明 |
|---|---|
| `--gestures` | 啟用手勢合成 |
| `--gestures-dry-run` | 只辨識並印出手勢、不送事件（隱含 `--gestures`） |
| `--gestures-swipe dock\|keys` | 三／四指滑動的送出方式。`keys`（預設）：放開時依位移（≥ 0.25）或甩動速度送出 Mission Control 快速鍵，公開 API、較穩定。`dock`：未公開的 Dock 手勢，畫面跟著手指移動（與觸控板相同），**實驗性** |
| `--gestures-exclude BUNDLE_ID[,…]` | 這些 App 在前景時暫停手勢（手指落下當時判斷，可重複指定） |
| `--gestures-log` | 實際送出事件時也印出手勢摘要（格式與 dry-run 相同，標籤為 `[手勢]`），用來對照實機回饋；預設不印 |
| `--gestures-rotation-gain X` | 旋轉增益（預設 1.5） |
| `--gestures-magnify-exponent X` | 縮放增益指數（預設 0.6；1 = 與指距等比例） |
| `--gestures-momentum-gain X` | 捲動慣性距離倍數（預設 1；2 = 滑行約兩倍遠、時間也較長；實作為衰減率 ÷ X） |
| `--release-buttons` | 在目前游標位置送出左／右／中鍵放開後離開（滑鼠鍵卡住時的復原，見「風險」） |
| `--simulate-pattern gestures` | 模擬觸控改為每 12 秒依序做出所有手勢（隱含 `--simulate`），用來驗證辨識；`drums` 為預設模式 |

`--simulate`／`--simulate-pattern` 時**一律為 dry-run**，啟動時 log 會說明（模擬觸控會在桌面上到處點擊）。

dry-run 的 log 不逐筆印出連續更新，而在結束時印出累計量，方便實機判讀，例如：

```
[手勢 dry-run] scroll ended：共 dx=0.0 dy=207.7 點、7 筆、48 ms
[手勢 dry-run] momentum ended：慣性共 dx=0.0 dy=611.4 點、162 筆、1335 ms
[手勢 dry-run] magnify ended：總倍率 ×2.960、739 ms
[手勢 dry-run] rotate ended：共 59.4°（逆時針為正）、640 ms
```

`keys` 模式使用系統設定 → 鍵盤 → 鍵盤快速鍵 → Mission Control 的預設快速鍵；若被改掉或停用，請恢復預設或改用 `dock`。

## 與 10 點觸控同時使用（設計）

同一時間只有一個程序能獨占觸控螢幕，所以手勢合成**放在 mtk-server 裡**：mtk-server 獨占裝置，每個 frame 同時（1）以 UDP／WebSocket／TUIO 廣播 10 點、（2）交給手勢辨識。不另做會搶裝置的執行檔。

| 情境 | 建議 |
|---|---|
| 平常使用桌面 App | `mtk-server --gestures`（可裝成 LaunchAgent） |
| 玩自己的 Unity 遊戲，同時保留桌面手勢 | 遊戲用 `Udp` 傳輸接收 10 點，並把遊戲加入 `--gestures-exclude`，遊戲在前景時觸控不會同時變成滑鼠點擊 |
| 遊戲要最低延遲（Native 傳輸） | 先停止 mtk-server（`scripts/uninstall-server-agent.sh` 或 Ctrl+C），遊戲直接獨占 |

查 bundle ID：`osascript -e 'id of app "App 名稱"'`；Unity Editor 例如 `com.unity3d.UnityEditor5.x`，自己建置的遊戲為 Player Settings 的 Bundle Identifier。

## 權限

合成事件需要「輔助使用」權限：系統設定 → 隱私權與安全性 → 輔助使用，允許**執行 mtk-server 的程序**：

- 從終端機執行：允許終端機 App（Terminal、iTerm2 等）。
- LaunchAgent：啟動時系統會把 **MultiTouchKit Server** 加入清單並詢問，打開它的開關即可（mtk-server 偵測到後會自動重新啟動以套用，約 10 秒內）。先執行一次 `scripts/create-signing-identity.sh`，之後更新時授權就不會失效（見 [server-protocol.md 授權與簽章](server-protocol.md#授權與簽章)）。

未授權時 mtk-server 會跳出系統詢問並在 log 提示，系統會靜默丟棄合成的事件。打開開關後：LaunchAgent 版會偵測到並自動重新啟動以套用；從終端機執行時請重新啟動 mtk-server。讀取觸控本身另需「輸入監控」權限（見 README）。

## 實作與分層

`MultiTouchKitGestures`（Swift library product）：

| 型別 | 角色 |
|---|---|
| `GestureRecognizer` | 純狀態機：`process(touches, at:)`／`tick(at:)` → `[GestureEvent]`，不碰系統 API，單元測試涵蓋（`Tests/MultiTouchKitGesturesTests`） |
| `GestureEvent` | 抽象事件（pointer、mouseDown/Dragged/Up、scroll、momentum、magnify、rotate、swipe），全域 Quartz 座標 |
| `GestureController` | 接 `TouchFrame`：以 `DisplayLocator` 選到的顯示器（MF156LR）把正規化座標換成全域座標、慣性計時（120 Hz，只在需要時）、前景 App 排除 |
| `GestureOutput` | 送出端協定；`CGEventGestureOutput`（實際送出）、`LoggingGestureOutput`（dry-run） |
| `SwipeShortcut` | keys 模式的方向 → 快速鍵判斷（純函式，可測） |

其他 Swift 程式也可直接使用：

```swift
import MultiTouchKit
import MultiTouchKitGestures

let manager = MultiTouchManager()
let gestures = GestureController(queue: manager.queue, output: CGEventGestureOutput())
gestures.displayID = DisplayLocator.resolve(.automatic, panel: manager.connectedDevices.first)?.display.id
manager.frameHandler = { gestures.handle($0) }
```

### 送出方法

- 滑鼠：`CGEvent(mouseEventSource:mouseType:…)`，`mouseEventClickState` 帶連點次數，送到 `cghidEventTap`（會移動游標）。
- 捲動：`CGEvent(scrollWheelEvent2Source:units: .pixel…)`，`scrollWheelEventIsContinuous = 1`，`scrollWheelEventScrollPhase`（1 began、2 changed、4 ended、8 cancelled）與 `scrollWheelEventMomentumPhase`（1 begin、2 continue、3 end）。這些欄位是公開的，App 會看到與觸控板相同的 `NSEvent.phase`／`momentumPhase`、`hasPreciseScrollingDeltas = true`。慣性由本專案計算：初速 = 手指放開時的速度，速度 × e^(−2.1 t) 衰減，低於 20 點／秒停止；總滑行距離約為放開速度 ÷ 2.1（例如 1000 點／秒放開約滑 470 點、1.9 秒）。2.1 是依使用者兩次回饋由 3.5 → 2.8（+25%）→ 2.1（再 +33%）調低。初速不放大，以免放開瞬間速度跳動。
- 縮放／旋轉：未公開 gesture 事件。欄位 55（事件類型）= 29（NSEventTypeGesture）、110（IOHIDEventType）= 8 Zoom／5 Rotation、132 = IOHIDEventPhase（1／2／4／8）、113 = 放大量、114 = 角度，送到 `cgSessionEventTap`。
- Dock swipe（`dock` 模式）：欄位 55 = 30（DockControl）、110 = 23（DockSwipe）、123／165 = 方向（1 水平、2 垂直）、124／135 = 累積進度、129／130 = 放開速度、41 = 33231，並附一個 type 29 的伴隨事件。
- 快速鍵（`keys` 模式）：`CGEvent(keyboardEventSource:virtualKey:keyDown:)`，Control＋方向鍵（123–126）。

未公開欄位編號來自社群逆向（例如開源的 Mac Mouse Fix 的 TouchSimulator 與 Apple 的 IOHIDEventTypes），本專案依欄位語意自行實作並實測。

## macOS 26.2（25C56，M4）實測

| 項目 | 結果 | 方法 |
|---|---|---|
| 捲動像素量、scroll phase、momentum phase | ✅ 解碼正確（`scrollingDeltaY`、`phase` 1/4/8、`momentumPhase` 1/4/8、precise） | 以 `CGEventPostToPid` 送到測試視窗程序，記錄收到的 `NSEvent`（不影響使用者桌面） |
| 縮放（未公開） | ✅ 收到 `NSEvent.magnify`，`magnification` 與 `phase` 正確 | 同上 |
| 旋轉（未公開） | ✅ 收到 `NSEvent.rotate`，`rotation` 與 `phase` 正確 | 同上 |
| 左鍵／右鍵按下放開、clickCount | ✅ 收到 | 同上 |
| 手勢辨識（全部手勢） | ✅ `--simulate-pattern gestures` 一個週期全部辨識正確，座標落在 MF156LR（全域 x 1920–3840） | dry-run |
| 實機送出（第 2 次回饋） | ✅ Finder 點擊良好；兩指右鍵基準改為游標先移到兩指中點；慣性距離 +25%（衰減 3.5 → 2.8） | 使用者回饋 |
| 實機送出（第 3 次回饋） | ✅ 兩指右鍵位置、旋轉增益 1.5（60° → 90°）良好；慣性再 +33%（衰減 2.8 → 2.1） | 使用者回饋 |
| 實機送出（`--gestures`，Finder／Safari／預覽／滑動） | ✅ 可操作；預覽程式旋轉需要轉很多 → 新增旋轉增益 1.5；三指與四指行為相同（設計如此，見上） | 使用者回饋 |
| 實機 dry-run（第 3 輪） | ✅ 5 次旋轉全對（兩種轉法）、縮放手感合理（×0.33–×3.3）、正常／慢速拖曳；❌ 停留後被提早送右鍵、一次捏合先判成旋轉、兩指拖動中途斷觸只捲了 14 點 → 已修正（放開才確定右鍵、旋轉主導條件、捲動斷觸容忍），待第 4 輪確認 | 同上 |
| 實機 dry-run（第 2 輪） | ✅ 繞中心旋轉、捏合不再帶出旋轉、甩動＋慣性 1488 點；❌ 旋轉時帶出 ×0.85 縮放、先放軸心指再旋轉被當成拖曳／捲動、短暫觸碰判成旋轉 → 已修正（第二指起點、慢速漂移、比例門檻、最短接觸），待第 3 輪確認 | 同上 |
| 實機 dry-run（使用者觸碰，第 1 輪） | ✅ 點擊、雙擊、拖曳、長按右鍵、兩指點擊、捲動方向、縮放、三／四指四個方向；❌ 旋轉被當成捲動、捏合時多送 ±2° 旋轉 → 已修正判定（見上），待第 2 輪確認 | `mtk-server --gestures-dry-run` |
| 實機觸碰下 Finder／Safari／預覽程式的實際反應 | ⏳ 待使用者測試 | |
| Dock swipe（`dock` 模式）與方向正負號 | ⏳ 待使用者測試（實驗性；測試會開啟 Mission Control，未在使用者作業中自動測試） | |
| `keys` 模式切換桌面／Mission Control | ⏳ 待使用者測試 | |

## 風險

### 事故（2026-10-28）：結束時滑鼠左鍵卡住

`mtk-server --gestures` 在拖曳中被直接結束時，`mouseDown` 已送出、`mouseUp` 沒送，系統一直認為左鍵按住，滑鼠左鍵完全失效。原因：只處理 SIGINT／SIGTERM，關閉終端機或 herdr pane（SIGHUP）會照預設行為直接結束；結束流程也只靠辨識器的狀態推導 mouseUp。

修正後的保護（`GestureController`＋`CGEventGestureOutput`）：

| 情況 | 處理 |
|---|---|
| SIGINT、SIGTERM（pkill、`launchctl bootout`）、SIGHUP（關閉終端機）、SIGQUIT | 結束前 `shutdown()`：放開按住的鍵、以 cancelled／ended 結束捲動、慣性、縮放、旋轉、swipe，之後不再處理觸控 |
| 觸控裝置拔除 | `cancel()` 同上 |
| 系統即將睡眠 | 同上 |
| 超過 5 點（手掌） | 同上 |
| 拖曳中切到 `--gestures-exclude` 的 App | 立即取消並放開，忽略到所有手指離開 |
| 有手指在螢幕上卻 2 秒沒有任何觸控報告（裝置斷線、卡住） | watchdog 自動取消並放開（ILITEK 按住不動時仍以 125 Hz 回報） |
| 啟動 `--gestures` 時系統顯示滑鼠鍵按住中（例如上次被 SIGKILL 或當機後由 LaunchAgent 重新啟動） | 啟動時先送出放開 |

放開依送出端自己記錄的「已送出 mouseDown 但還沒 mouseUp」狀態處理，與辨識器的狀態無關，不會漏掉。

**仍然卡住時的復原**（例如 `kill -9`／SIGKILL 無法攔截）：用還能用的觸控板、鍵盤開終端機執行

```sh
~/Projects/MultiTouchKit/.build/release/mtk-server --release-buttons
# LaunchAgent 安裝版：
"$HOME/Library/Application Support/MultiTouchKit/MultiTouchKit Server.app/Contents/MacOS/mtk-server" --release-buttons
```

它會在目前游標位置送出左、右、中鍵的放開事件後離開（需要「輔助使用」權限）。也可以直接用實體滑鼠按一下左鍵再放開。


- **未公開事件可能隨 macOS 更新失效**（縮放、旋轉、Dock swipe）：失效時通常是「沒有反應」，不會造成錯誤操作。點擊、拖曳、捲動、`keys` 模式都是公開 API。更新 macOS 後除了 `--simulate-pattern gestures`，也請以實機觸碰確認一次，並更新上表。
- 合成的縮放／旋轉只對支援觸控板手勢的 App 有效（預覽程式、Safari、地圖、照片等）。
- 慢速的精細拖曳（< 150 點／秒）要移動 40 點才開始（按下位置仍是起點）。
- 長按右鍵在放開時才送出，所以選單比觸控板的右鍵晚出現（按住期間沒有回饋）。好處是按住後仍可改成拖曳或兩指手勢。
- 點擊在手指離開時才送出（要先確認不是拖曳或兩指手勢），所以按鈕的按下回饋比滑鼠晚一個點擊時間（通常 < 100 ms）。
- 觸控螢幕被 mtk-server 獨占時，其他程式（例如 Unity Native 傳輸）無法開啟它。
- 「輔助使用」權限讓程式可以操作整台電腦，只授權給你信任、自己建置的 mtk-server。

## 參數調整

門檻定義在 `GestureRecognizer.Configuration`（單位為點；MF156LR 約 5.6 點／mm）：點擊容許位移 14、等待其他手指 50 ms、拖曳等待 0.12 s（慢速漂移 < 150 點／秒時拖曳門檻 40）、長按 0.6 s、兩指點擊上限 0.35 s、雙擊間隔 0.45 s、捲動起始 12（指間相對位移 < 0.5 倍重心位移；0.5–0.8 倍時等到 24 點）、縮放起始 30、旋轉起始 12°（指間距 ≥ 60）、兩指最短接觸 80 ms（縮放／旋轉）、次要縮放 ×1.35／次要旋轉 24°、旋轉主導 切向 ≥ 25 點且 ≥ 1.5 倍徑向、捲動斷觸容忍 0.15 s、旋轉增益 1.5、縮放增益 0.6、最多 5 點、多指滑動起始 50、滑動全程 450、慣性最低速度 150 點／秒、慣性衰減 2.8／秒。旋轉增益與縮放增益有命令列選項，其他門檻目前只能在程式中設定。
