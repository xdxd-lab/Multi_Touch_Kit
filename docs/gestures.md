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
| 一指長按不動 0.6 秒 | 右鍵點擊（到時間立即彈出選單） | 公開 API |
| 兩指點擊 | 右鍵點擊（兩指中點） | 公開 API |
| 兩指平移 | 捲動，內容跟著手指走；放開時依速度產生慣性捲動 | 公開 API（像素捲動＋scroll／momentum phase） |
| 兩指開合 | 縮放（觸控板的 pinch） | **未公開** gesture 事件 |
| 兩指轉動（兩指繞中心轉，或一指為軸另一指繞著轉） | 旋轉 | **未公開** gesture 事件 |
| 三／四指左右滑 | 切換桌面（Space）／全螢幕 App | 預設 Control＋←／→；`--gestures-swipe dock` 為未公開 Dock 手勢 |
| 三／四指往上滑 | Mission Control | 預設 Control＋↑ |
| 三／四指往下滑 | App Exposé | 預設 Control＋↓ |

兩指手勢的判定：把兩指運動拆成「重心平移」與「指間向量的變化」。重心移動超過 12 點、且指間向量變化小於重心位移的 0.8 倍才算捲動；以一指為軸旋轉或單指捏合時，指間向量變化約為重心位移的 2 倍，不會被當成捲動。縮放與旋轉先依「開合的徑向位移」與「旋轉的切向位移」決定主要的一個，另一個要從決定當下再超過 2 倍門檻（縮放 60 點、旋轉 24°）才會一起送出；兩指間距小於 60 點時角度雜訊太大，不送旋轉。

手指不會同時落下：第一指落下後 50 ms 內出現的手指算同一個手勢；手勢決定後新增的手指會被忽略，直到所有手指離開。捲動、縮放、旋轉前會先把游標移到兩指中點（系統把這些事件送給游標下方的視窗）。手指碰到螢幕會立刻停止慣性捲動。

## 選項

| 選項 | 說明 |
|---|---|
| `--gestures` | 啟用手勢合成 |
| `--gestures-dry-run` | 只辨識並印出手勢、不送事件（隱含 `--gestures`） |
| `--gestures-swipe dock\|keys` | 三／四指滑動的送出方式。`keys`（預設）：放開時依位移（≥ 0.25）或甩動速度送出 Mission Control 快速鍵，公開 API、較穩定。`dock`：未公開的 Dock 手勢，畫面跟著手指移動（與觸控板相同），**實驗性** |
| `--gestures-exclude BUNDLE_ID[,…]` | 這些 App 在前景時暫停手勢（手指落下當時判斷，可重複指定） |
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
- LaunchAgent：允許 `~/Library/Application Support/MultiTouchKit/mtk-server`（可用「＋」加入）。重新安裝（重新建置、ad-hoc 簽章改變）後可能需要移除再重新加入。

未授權時 mtk-server 會跳出系統詢問並在 log 提示，系統會靜默丟棄合成的事件。授權後請重新啟動 mtk-server。讀取觸控本身另需「輸入監控」權限（見 README）。

## 實作與分層

`MultiTouchKitGestures`（Swift library product）：

| 型別 | 角色 |
|---|---|
| `GestureRecognizer` | 純狀態機：`process(touches, at:)`／`tick(at:)` → `[GestureEvent]`，不碰系統 API，單元測試涵蓋（`Tests/MultiTouchKitGesturesTests`） |
| `GestureEvent` | 抽象事件（pointer、mouseDown/Dragged/Up、scroll、momentum、magnify、rotate、swipe），全域 Quartz 座標 |
| `GestureController` | 接 `TouchFrame`：以 `DisplayLocator` 選到的顯示器（MF156LR）把正規化座標換成全域座標、長按與慣性計時（120 Hz，只在需要時）、前景 App 排除 |
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
- 捲動：`CGEvent(scrollWheelEvent2Source:units: .pixel…)`，`scrollWheelEventIsContinuous = 1`，`scrollWheelEventScrollPhase`（1 began、2 changed、4 ended、8 cancelled）與 `scrollWheelEventMomentumPhase`（1 begin、2 continue、3 end）。這些欄位是公開的，App 會看到與觸控板相同的 `NSEvent.phase`／`momentumPhase`、`hasPreciseScrollingDeltas = true`。慣性由本專案計算（速度 × e^(−3.5 t)，低於 20 點／秒停止）。
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
| 實機 dry-run（使用者觸碰，第 1 輪） | ✅ 點擊、雙擊、拖曳、長按右鍵、兩指點擊、捲動方向、縮放、三／四指四個方向；❌ 旋轉被當成捲動、捏合時多送 ±2° 旋轉 → 已修正判定（見上），待第 2 輪確認 | `mtk-server --gestures-dry-run` |
| 實機觸碰下 Finder／Safari／預覽程式的實際反應 | ⏳ 待使用者測試 | |
| Dock swipe（`dock` 模式）與方向正負號 | ⏳ 待使用者測試（實驗性；測試會開啟 Mission Control，未在使用者作業中自動測試） | |
| `keys` 模式切換桌面／Mission Control | ⏳ 待使用者測試 | |

## 風險

- **未公開事件可能隨 macOS 更新失效**（縮放、旋轉、Dock swipe）：失效時通常是「沒有反應」，不會造成錯誤操作。點擊、拖曳、捲動、`keys` 模式都是公開 API。更新 macOS 後除了 `--simulate-pattern gestures`，也請以實機觸碰確認一次，並更新上表。
- 合成的縮放／旋轉只對支援觸控板手勢的 App 有效（預覽程式、Safari、地圖、照片等）。
- 長按右鍵會延後「按住不動再拖曳」：按住超過 0.6 秒不動就變成右鍵，之後的移動會被忽略。需要按住再拖的操作請在 0.6 秒內開始移動。
- 點擊在手指離開時才送出（要先確認不是拖曳或兩指手勢），所以按鈕的按下回饋比滑鼠晚一個點擊時間（通常 < 100 ms）。
- 觸控螢幕被 mtk-server 獨占時，其他程式（例如 Unity Native 傳輸）無法開啟它。
- 「輔助使用」權限讓程式可以操作整台電腦，只授權給你信任、自己建置的 mtk-server。

## 參數調整

門檻定義在 `GestureRecognizer.Configuration`（單位為點；MF156LR 約 5.6 點／mm）：點擊容許位移 14、等待其他手指 50 ms、長按 0.6 s、兩指點擊上限 0.35 s、雙擊間隔 0.45 s、捲動起始 12（指間相對位移 < 0.8 倍重心位移）、縮放起始 30、旋轉起始 12°（指間距 ≥ 60）、次要縮放／旋轉 2 倍門檻、多指滑動起始 50、滑動全程 450、慣性最低速度 150 點／秒。目前沒有命令列選項，需要時再提供。
