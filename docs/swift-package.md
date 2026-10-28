# Swift Package 使用說明

同程序直接讀取觸控，延遲最低。適合 Swift／SwiftUI／AppKit／SpriteKit／Metal 程式。

## 加入相依

`Package.swift`：

```swift
dependencies: [
    .package(url: "https://github.com/xdxd-lab/multi_touch_kit.git", branch: "main"),
],
targets: [
    .executableTarget(name: "MyGame", dependencies: [
        .product(name: "MultiTouchKit", package: "multi_touch_kit"),
    ]),
]
```

Xcode：File → Add Package Dependencies… → 貼上 `https://github.com/xdxd-lab/multi_touch_kit.git`，選 `MultiTouchKit` 產品。

需求：macOS 13 以上、Swift 6。目前沒有版本 tag，請用 `branch: "main"`（或指定 commit）。

> **API 穩定性**：1.0 之前公開 API 仍可能有原始碼不相容的改動。2026-10 起以下型別不再公開（只供套件內部使用）：`HIDReportDescriptor`、`HIDField`、`HIDCollection`、`HIDReportKind`、`HIDDescriptorError`（HID 描述元解析），以及 `TouchEventQueue`、`QueuedTouchEvent`（C API 的事件佇列，改為 `package` 層級）。

## 最小範例

```swift
import MultiTouchKit

let manager = MultiTouchManager()          // 預設：所有 HID 觸控螢幕、獨占、初始化多點模式
manager.logHandler = { print($0) }
manager.deviceHandler = { event in print(event) }
manager.frameHandler = { frame in
    for touch in frame.touches where touch.phase == .began {
        print("按下 #\(touch.id) at \(touch.x), \(touch.y)  t=\(frame.timestamp) ns")
    }
}
try manager.start()
dispatchMain()                              // 命令列程式需要讓程序持續執行；App 不需要
```

`manager.stop()` 會釋放裝置，仍在螢幕上的觸點會先以 `.cancelled` 送出。

## 執行緒

所有 handler 都在 `manager.queue`（`userInteractive` 序列佇列）上呼叫，不在主執行緒。請盡快返回；更新 UI 時自行切回主執行緒：

```swift
manager.frameHandler = { frame in
    DispatchQueue.main.async { scene.apply(frame) }
}
```

節奏遊戲的判定請用 `frame.timestamp`（收到 HID 報告的時間），不要用畫面幀時間；音效可直接在 handler 內觸發以減少延遲。

## 設定

```swift
var config = MultiTouchManager.Configuration()
config.vendorID = 0x222A          // nil = 不限
config.productID = 0x0001
config.exclusive = true           // 獨占：系統游標不再跟著觸控移動；同時只有一個程序能獨占
config.initializeMultiTouchMode = true   // 讀 Contact Count Maximum、設 Device Mode（ILITEK 必須）
config.seizeSiblingInterfaces = true     // 一併獨占同裝置的滑鼠相容介面
config.retryInterval = 1.0        // 裝置被其他程式（例如 mtk-server）獨占時每秒重試；0 = 不重試
config.staleTouchTimeout = 30     // 幾乎不動超過 30 秒的觸點視為誤觸並 cancelled（線材等）；0 = 關閉
config.staleTouchTolerance = 0.003 // 「不動」的容許範圍（正規化座標）
config.reportTimeout = 0.5        // 有觸點卻 0.5 秒沒有報告（放開遺失、USB 異常）→ 全部 cancelled
let manager = MultiTouchManager(configuration: config)
```

自動處理：裝置插拔（啟動後才接上也可以）、系統睡眠喚醒後重新初始化、控制器退回滑鼠模式時重新初始化、誤觸與放開遺失（見 [c-api.md 誤觸](c-api.md#誤觸長時間不動的觸點與放開遺失)）。

## 資料型別

`TouchFrame`：一次完整掃描（ILITEK 約每 8 ms 一個）。

| 欄位 | 說明 |
|---|---|
| `deviceID` | 裝置編號（從 1 開始；模擬來源為 0） |
| `sequence` | 每個裝置各自遞增 |
| `timestamp` | 收到 HID 報告的時間，奈秒，`MultiTouchClock` 時基（`mach_absolute_time`） |
| `scanTime` | 控制器的 Scan Time（通常 100 µs 單位）；不支援時為 nil |
| `touches` | 這個 frame 的所有觸點，包含 `.stationary` 與剛放開的 `.ended`／`.cancelled` |
| `activeTouches` | 仍在螢幕上的觸點 |

`Touch`：

| 欄位 | 說明 |
|---|---|
| `id` | 每次觸碰唯一（從 1 遞增，跨裝置不重複）；追蹤手指請用它 |
| `contactID` | 控制器的 Contact Identifier，放開後會被重複使用 |
| `phase` | `.began` `.moved` `.stationary` `.ended` `.cancelled` |
| `x`, `y` | 正規化 0...1，原點在面板左上角 |
| `rawX`, `rawY` | 控制器原始座標 |
| `pressure`, `width`, `height`, `confidence` | 裝置支援才有值（ILITEK 沒有，為 nil） |

`MultiTouchDeviceInfo`（`manager.connectedDevices`、`DeviceEvent`）：VID／PID、廠商與產品名稱、`maxContacts`（讀到 feature 後為 10）、`slotsPerReport`、實體尺寸（mm）、是否獨占。

## 座標換算與顯示器對應

觸控螢幕通常不是主螢幕，系統中也可能有同名顯示器（例如兩台「Sculptor」），所以要先找出觸控螢幕是哪一台：

```swift
// 自動：依觸控面板實體尺寸挑選（需先 start，才有面板尺寸）
let panel = manager.connectedDevices.first
if let match = DisplayLocator.resolve(.automatic, panel: panel) {
    print(match.display, match.note)
}

// 明確指定（最可靠：EDID 廠商:型號）
let selector = DisplaySelector("edid:6474:aa15")!          // 或 "name:Sculptor,size:1920x1080"
var mapping = ScreenMapping(selector: selector, panel: panel) ?? ScreenMapping()

let quartz = mapping.globalPoint(x: touch.x, y: touch.y)   // 全域 Quartz 座標（原點主螢幕左上），可用於 CGEvent
let cocoa = mapping.cocoaPoint(x: touch.x, y: touch.y)     // 全域 Cocoa 座標（原點主螢幕左下），可用於 NSWindow
```

- `DisplaySelector` 文字格式（`auto`、`main`、`id:N`、`uuid:…`、`edid:VVVV:MMMM[:序號]`、`name:…`、`size:WxH`、`hz:N`，逗號串接）見 [c-api.md 顯示器對應](c-api.md#顯示器對應)；`DisplaySelector.environment` 讀取環境變數 `MTK_DISPLAY`。
- `DisplayLocator.onlineDisplays()` 列出所有顯示器（id、名稱、EDID、UUID、bounds、解析度、更新率、實體尺寸）。名稱只有在主執行緒呼叫時才會填入。
- `ScreenMapping(displayID:)` 預設仍是 `CGMainDisplayID()`，請改用上面的方式。顯示器重新接線後 `CGDirectDisplayID` 可能改變，可在 `CGDisplayRegisterReconfigurationCallback` 中重新解析。
- 螢幕在「顯示器」設定中旋轉時設定 `rotation`；面板方向相反時用 `flipX`／`flipY`。
- `mtk-viewer --display SEL`、`mtk-server --display SEL` 使用相同格式；`--list-displays` 可列出目前的顯示器。

## 時鐘

`MultiTouchClock.now()` 與 `timestamp` 同一時基（同一台 Mac 所有程序共用），可直接相減得到「收到觸控到現在」的時間，也能和 `mtk-server` 送出的 `t` 比較。

## 無硬體開發

```swift
let sim = SimulatedTouchSource(rate: 125)    // 一指畫圓、一指滑動、四個鼓面輪流點擊
sim.frameHandler = { frame in /* 與 MultiTouchManager 相同 */ }
sim.start()
```

`MultiTouchManager` 與 `SimulatedTouchSource` 都遵循 `TouchSource`（`queue`、`frameHandler`、`connectedDevices`、`start()`、`stop()`），程式只依賴它就能用一個旗標切換實體與模擬：

```swift
let source: TouchSource = simulate ? SimulatedTouchSource() : MultiTouchManager()
source.frameHandler = { frame in /* … */ }
try source.start()
```

測試時可用 `MultiTouchDeviceInfo(id:vendorID:…)` 自行建立裝置資訊（例如傳給 `DisplayLocator.resolve(_:panel:)`）。

## 其他公開工具

- `TouchJSON`：產生 `mtk-server` 使用的 JSON（見 [server-protocol.md](server-protocol.md)）。
- `TUIOEncoder`：產生 TUIO 1.1 `/tuio/2Dcur` OSC bundle。

## 權限與發布

- 獨占 HID 裝置可能需要「輸入監控」權限；`IOHIDDeviceOpen` 回傳 `0xe00002e2`（not permitted）時請到系統設定授權執行的 App。
- 授權綁定的是程式的簽章身分：ad-hoc 簽章的程式每次建置都不同，需要重新授權；以固定的憑證簽章（Developer ID，或本機用的自簽憑證，見 [server-protocol.md 授權與簽章](server-protocol.md#授權與簽章)）時，更新後授權仍有效。
- App Sandbox 下的行為尚未驗證，建議先以非沙盒 App 發布。
