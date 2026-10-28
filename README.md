# MultiTouchKit

macOS 上的 HID 多點觸控螢幕驅動（使用者空間），讓 Sculptor MF156LR 這類 Windows 相容觸控螢幕（ILITEK-TP，VID `0x222A`／PID `0x0001`）在 Mac 上取得 **10 點獨立觸控**，供 Swift、C/C++、Unity、Python、網頁等程式使用。

- GitHub：[xdxd-lab/multi_touch_kit](https://github.com/xdxd-lab/multi_touch_kit)
- 背景、方案決策與實機量測：[docs/PRE_ANALYSIS.md](docs/PRE_ANALYSIS.md)

## 為什麼需要它

macOS 內建驅動只把這類觸控螢幕當單點滑鼠。MultiTouchKit 在使用者空間以 IOHIDManager／IOHIDDevice **獨占**觸控螢幕（同時獨占同一 USB 裝置的滑鼠相容介面，系統游標不會再跟著動），依 Windows 流程讀取 Contact Count Maximum feature（ILITEK 面板讀過才會送多點報告），再自行解析 HID Digitizer 報告與追蹤手指。

不需要 Xcode、關閉 SIP、DriverKit 或 Apple 開發者帳號；只要 Command Line Tools（Swift 6）。

實機量測（M4、macOS 26.2）：約 125 Hz（中位數 8.01 ms）、最多 10 點、獨占時游標 0 移動。

限制：
- 一般 macOS App（Finder、瀏覽器等）拿不到這些觸點，只有透過本專案 API／網路協定的程式才收得到 10 點。`mtk-server --gestures` 可把觸控合成為系統操作（點擊、捲動、縮放、旋轉、多指滑動），見 [docs/gestures.md](docs/gestures.md)。
- 同一時間只有一個程序能獨占觸控螢幕。多個程式同時使用時，請執行 `mtk-server`，其他程式改收網路訊息。

## 架構

```
ILITEK 觸控螢幕 ──USB HID──▶ MultiTouchKit（Swift 核心）
                               │  HID 描述子解析、多點模式初始化、獨占、熱插拔、睡眠喚醒、手指追蹤、時間戳記
        ┌──────────────────────┼─────────────────────────────┐
        ▼                      ▼                             ▼
  Swift Package          MultiTouchKitC（C ABI）          mtk-server（常駐程式）
  同程序、最低延遲       libMultiTouchKitC.dylib          UDP JSON ／ WebSocket ／ TUIO 1.1
                         Unity MultiTouchKit.bundle        ▲ Unity UdpTransport、Python、網頁、TUIO App
                         ▲ Unity NativeTransport、C/C++、Python ctypes
```

## 呼叫方式

| 方式 | 適合 | 延遲 | 說明 |
|---|---|---|---|
| Swift Package | Swift／SwiftUI／SpriteKit／Metal App | 最低（同程序） | [docs/swift-package.md](docs/swift-package.md) |
| C ABI／原生外掛 | Unity、C/C++、Python ctypes、Godot、Rust | 最低（同程序） | [docs/c-api.md](docs/c-api.md) |
| `mtk-server` | 多個程式共用、網頁、TUIO App、其他電腦 | 多一次本機 UDP／WS 傳遞 | [docs/server-protocol.md](docs/server-protocol.md) |
| Unity 套件 | Unity 遊戲（Native 或 UDP 傳輸、Input System） | 依傳輸方式 | [docs/unity.md](docs/unity.md) |
| 系統手勢（`mtk-server --gestures`） | 一般 macOS App：點擊、右鍵、捲動、縮放、旋轉、切換桌面 | — | [docs/gestures.md](docs/gestures.md) |

## 快速開始

```sh
git clone https://github.com/xdxd-lab/multi_touch_kit.git MultiTouchKit
cd MultiTouchKit
swift build -c release

# 看裝置是否被偵測到、量測回報率（觸控後開始記錄 30 秒）
.build/release/mtk-probe

# 列出顯示器，確認觸控螢幕是哪一台
.build/release/mtk-server --list-displays

# 視覺化（全螢幕顯示在觸控螢幕上；預設 auto 依面板尺寸挑選，也可指定 --display edid:6474:aa15）
.build/release/mtk-viewer

# 常駐廣播給其他程式（沒有觸控螢幕時加 --simulate）
.build/release/mtk-server
```

觸控螢幕通常不是主螢幕，且可能有同名顯示器；所有工具與 API 都用同一種顯示器選擇格式（`auto`、`edid:6474:aa15`、`name:Sculptor,size:1920x1080`…），也可用環境變數 `MTK_DISPLAY` 統一設定，詳見 [docs/c-api.md](docs/c-api.md#顯示器對應)。

第一次執行時 macOS 可能要求「輸入監控」權限（系統設定 → 隱私權與安全性 → 輸入監控），請允許執行程式的 App（終端機、Unity 等）。

## 專案內容

| 路徑 | 內容 |
|---|---|
| `Sources/MultiTouchKit` | Swift 核心程式庫 |
| `Sources/CMultiTouchKit/include/multitouchkit.h` | C API 標頭（ABI 定義） |
| `Sources/MultiTouchKitC` | C API 實作（Swift `@_cdecl` 匯出），產出 `libMultiTouchKitC.dylib` |
| `Sources/MultiTouchKitGestures` | 系統層手勢：辨識（純邏輯）與 CGEvent 送出 |
| `Sources/mtk-server` | 常駐程式：UDP JSON、WebSocket、TUIO 1.1 |
| `Sources/mtk-probe` | 量測工具：回報率、觸點數、連打、CSV 原始資料 |
| `Sources/mtk-viewer` | 觸點視覺化視窗 |
| `Unity/com.xdxd-lab.multitouchkit` | Unity 套件（含 universal `MultiTouchKit.bundle`） |
| `Examples/` | C、Python（ctypes／UDP／WebSocket／TUIO）、網頁範例 |
| `scripts/` | 測試、建置 Unity 外掛、C 範例、LaunchAgent 安裝／移除 |
| `Tests/` | 單元測試（以實機擷取的報告為 fixture，不需硬體）；`Tests/UnityOffline` 為 Unity C# 的離線測試 |

## 開發

```sh
swift build                       # 建置全部
./scripts/test.sh                 # 單元測試（只有 Command Line Tools 時不要直接用 swift test，會找不到 Testing 模組）
./scripts/build-c-example.sh 5    # 編譯並執行 C 範例 5 秒
./scripts/test-unity-offline.sh   # 不開 Unity Editor 檢查 C#：編譯套件與範例、執行 Udp 傳輸／JSON 解析器測試
./scripts/test-web-example.sh     # 網頁範例的位置換算與頁面腳本測試（macOS 內建的 JavaScriptCore）
./scripts/check-signals.sh        # 三個執行檔收到 SIGINT／SIGTERM／SIGHUP 時都正常收尾後結束（含背景啟動的情況）
./scripts/build-unity-plugin.sh   # 重建 Unity 外掛（改了 Sources/MultiTouchKit 或 MultiTouchKitC 後要執行並 commit）
MTK_BENCH=1 ./scripts/test.sh -c release --filter HotPathBenchmarks   # 熱路徑微基準（平常略過）
.build/release/mtk-server --simulate   # 無硬體開發：模擬 125 Hz 觸控
```

ABI 規則：`multitouchkit.h` 的結構欄位只能附加在尾端；改動時要同步更新 `MTK_API_VERSION`、`Unity/.../MultiTouchKitNative.cs`、`Examples/python/native_ctypes.py` 與 [docs/c-api.md](docs/c-api.md)。

需求：macOS 13 以上、Swift 6（Command Line Tools 即可）。Apple Silicon 與 Intel 都支援（Unity 外掛為 arm64＋x86_64 universal）。

## 狀態

- 第一階段（核心、三種呼叫方式、Unity 套件）、系統層手勢合成、誤觸與放開遺失的處理都已完成，並在 MF156LR 與 Unity 6000.3 實機驗證（[docs/hardware/mf156lr-summary.md](docs/hardware/mf156lr-summary.md)）。
- **2026-10 程式碼審查（Q1）**：[docs/reviews/2026-10-code-review.md](docs/reviews/2026-10-code-review.md)。分 5 批改善：
  - 正確性：C API 回呼的 use-after-free、Unity 重複 Manager、UDP 幽靈觸點、資源洩漏、畸形描述元等。
  - 效能：mtk-server 輸出全開時 CPU 約 −57%（輸出位元組不變，以 golden 測試保證）；Unity 每幀零 GC。
  - 結構：`TouchSource`、共用的命令列解析、公開 API 收斂。
  - 文件註解。
  - 測試：82 → 111 項，另有 Unity 離線測試與信號處理檢查。不改 C ABI。
- 待使用者在 Unity 內實機確認的項目（審查後的 Unity 端修正）見 [docs/unity.md](docs/unity.md) 開頭的狀態。
