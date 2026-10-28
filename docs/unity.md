# Unity 套件使用說明

套件 `com.xdxd-lab.multitouchkit`（`Unity/com.xdxd-lab.multitouchkit`）：C# 包裝、Native／UDP 兩種傳輸、Input System 虛擬觸控螢幕、範例場景。目標 Unity 2022.3 LTS 以上，macOS 編輯器與 macOS 執行檔（Apple Silicon 與 Intel）。

> 狀態：程式碼與 universal bundle 已完成，bundle 已以 Python ctypes 在 arm64／x86_64 驗證可載入並開啟觸控螢幕；**尚未在 Unity 內實際驗證**（開發機尚未安裝 Unity）。

## 安裝

Package Manager → `+` → **Add package from git URL…**：

```
https://github.com/xdxd-lab/multi_touch_kit.git?path=/Unity/com.xdxd-lab.multitouchkit
```

或在 `Packages/manifest.json` 加入：

```json
"com.xdxd-lab.multitouchkit": "https://github.com/xdxd-lab/multi_touch_kit.git?path=/Unity/com.xdxd-lab.multitouchkit"
```

本機開發時也可以用 **Add package from disk…** 選 `Unity/com.xdxd-lab.multitouchkit/package.json`。

範例：Package Manager 選 MultiTouchKit → Samples → 匯入 **Touch Visualizer**（顯示每根手指的位置與編號）或 **Latency Calibration**（跟著節拍器點擊，量出判定偏移）。

Input System（`com.unity.inputsystem` 1.4.0 以上）為選用；安裝後自動啟用 `MTK_INPUT_SYSTEM`，觸控會送進虛擬 `Touchscreen`。

## 基本用法

場景放一個 `MultiTouchKit Manager`（Add Component → MultiTouchKit → MultiTouchKit Manager），或由程式建立：

```csharp
using MultiTouchKit;
using UnityEngine;

public class Drums : MonoBehaviour
{
    void OnEnable() => MultiTouchKitManager.TouchReceived += OnTouch;
    void OnDisable() => MultiTouchKitManager.TouchReceived -= OnTouch;

    void OnTouch(MultiTouchTouch touch)
    {
        if (touch.Phase != MultiTouchPhase.Began) return;
        double hitTime = touch.DspTime;           // 觸碰當下的 AudioSettings.dspTime，用來判定
        Vector2 screen = touch.ScreenPosition;    // Unity 螢幕像素（原點左下）
        Debug.Log($"{touch} dsp={hitTime:F4} screen={screen}");
    }
}
```

- `TouchReceived`：每個事件（began／moved／ended／cancelled，預設不含 stationary）在主執行緒觸發一次。
- `MultiTouchKitManager.Instance.ActiveTouches`：目前仍在螢幕上的觸點（key = `Id`）。
- `GetActiveTouches(List<MultiTouchTouch>)`：把仍在螢幕上的觸點依 `Id` 排序複製到你的 List，重複使用同一個 List 時不配置記憶體。每幀列舉請用它，不要 `foreach (… ActiveTouches.Values)`（透過介面列舉每次都會配置）。
- `TouchesThisFrame`：這一幀收到的所有事件，依時間順序（用 `for` 與索引讀取）。

### GC

穩定狀態下 MultiTouchKit 每幀不配置記憶體：Native 傳輸直接把原生事件複製到固定的陣列；Udp 傳輸在接收執行緒用固定的緩衝區接收，並以專用的解析器直接讀取 UTF-8 位元組（不經過字串與 JsonUtility）。範例的 OnGUI 也只在內容改變時才重建字串。可在 Profiler 的 CPU 模組看 `MultiTouchKitManager.PollNow` 的 GC Alloc 欄位確認。
- 有 Input System 時，`MultiTouchKitManager` 會在 Input System 更新前取出觸控，遊戲當幀就讀得到。

`MultiTouchTouch` 欄位：`Id`（每次觸碰唯一）、`ContactId`、`DeviceId`、`Phase`、`Normalized`（0..1，原點左上）、`ScreenPosition`、`TimestampNs`、`Pressure`（不支援為 -1）、`FrameSequence`，以及換算屬性 `DspTime`、`RealtimeSinceStartup`。

## Manager 設定

| 欄位 | 說明 |
|---|---|
| `transport` | `Native`：程序內直接讀取（最低延遲）。`Udp`：接收 `mtk-server` 的 UDP JSON |
| `udpPort` | Udp 模式監聽的埠（預設 7777） |
| `udpBindAddress` | Udp 模式監聽的位址。空白 = 127.0.0.1（只接收本機）；接收其他電腦的 `mtk-server` 時填 `0.0.0.0` |
| `udpTimeout` | Udp 模式：有觸點時超過此秒數沒有收到資料就全部 Cancelled（預設 0.5；0 = 關閉）。`mtk-server` 按住時約以 125 Hz 送出，被強制結束或重新啟動時最後的 ended 會遺失 |
| `exclusive` | 獨占觸控螢幕，系統游標不再跟著動（Native） |
| `vendorId`／`productId` | 只使用指定裝置（0 = 不限） |
| `screenMapping` | `FullScreen`：假設遊戲全螢幕顯示在觸控螢幕上，正規化座標直接乘上 `Screen` 尺寸。`KeyWindow`：依目前視窗在觸控螢幕上的位置換算（視窗模式；需要原生外掛） |
| `displaySelector` | 觸控螢幕所在的顯示器（KeyWindow 使用）。空白 = 自動依面板實體尺寸挑選；例：`edid:6474:aa15`、`name:Sculptor,size:1920x1080`。格式見 [c-api.md 顯示器對應](c-api.md#顯示器對應) |
| `displayId` | 直接指定 `CGDirectDisplayID`；非 0 時優先於 `displaySelector`（重新接線後可能改變，不建議） |
| `feedInputSystem` | 把觸控送進 Input System 的虛擬 `Touchscreen` |
| `logNativeMessages` | 把原生診斷訊息（裝置開啟、選到哪台顯示器等）印到 Console |
| `dontDestroyOnLoad` | 切換場景時保留 |
| `runInBackground` | 預設 true：設定 `Application.runInBackground`，失去焦點時繼續接收觸控（觸控螢幕通常是第二螢幕，使用者點主螢幕時遊戲不應停住）。關閉時失焦期間的觸控會在回到前景時重新同步 |
| `staleTouchTimeout` | 觸點幾乎不動超過此秒數就以 Cancelled 取消（線材等幽靈觸點；預設 30，0 = 關閉）。Udp 傳輸時由 `mtk-server --stale-touch-timeout` 決定 |

修改設定後呼叫 `Restart()`。`TouchDisplayId` 可查目前對應到的顯示器。

### 失去焦點、暫停與誤觸

- Unity 失去焦點或暫停時若停止 Update，原生佇列可能溢位。溢位**不會遺失觸點狀態**：回來後第一次取出時會先重新同步（已離開的觸點 Cancelled、仍在的 Began／Moved），Console 會出現警告與丟棄筆數（`DroppedEventCount`）。`OnApplicationFocus(true)`／`OnApplicationPause(false)` 時 Manager 也會主動 `RequestResync()` 對帳。
- 長時間不動的觸點（例如滑鼠線碰到面板）會在 `staleTouchTimeout` 秒後以 Cancelled 取消。**遊戲請把 Cancelled 當成放開**（長按音符判失敗），不要當作仍按著。
- TouchVisualizer 讀的是 `GetActiveTouches`（原生觸點），不是 Input System；本套件不會啟用 Input System 的 TouchSimulation（滑鼠模擬觸控）。

## 選擇傳輸方式

| 情況 | 傳輸 |
|---|---|
| 只有 Unity 使用觸控 | `Native` |
| `mtk-server` 已在執行（例如裝成 LaunchAgent），或要和其他程式共用 | `Udp`（Native 會因裝置已被獨占而持續重試） |
| 沒有觸控螢幕，想開發／測試 | `Udp` ＋ `mtk-server --simulate` |
| Windows／Linux 編輯器 | 原生外掛只支援 macOS；可用 `Udp`（`udpBindAddress` 設為 `0.0.0.0`）接收另一台 Mac 上 `mtk-server --udp <這台 IP>:7777` 的資料（未驗證；請注意防火牆，UDP 沒有驗證來源） |

UDP 模式的保護：佇列最多保留 1024 個封包（約 8 秒），主執行緒暫停導致溢位時會丟棄舊資料，並依下一個 frame 對帳（不在其中的觸點 Cancelled、新的觸點 Began）；有觸點卻超過 `udpTimeout` 沒有資料時全部 Cancelled。

UDP 模式下時間戳記與原生時鐘相同時基（同一台 Mac）；`DspTime` 換算需要原生外掛可載入（macOS），否則以 `Stopwatch` 近似。

## Input System

安裝 Input System 且 `feedInputSystem = true` 時，會新增名為「MultiTouchKit Touchscreen」的 `Touchscreen` 裝置，可直接使用：

```csharp
using UnityEngine.InputSystem.EnhancedTouch;
EnhancedTouchSupport.Enable();
foreach (var t in UnityEngine.InputSystem.EnhancedTouch.Touch.activeTouches) { /* 與 iOS／Android 寫法相同 */ }
```

事件時間會換算成 Input System 時間（`InputState.currentTime`），`touch.time` 對應觸碰當下而非幀時間。UI（EventSystem＋Input System UI Input Module）也能用觸控操作。

## 節奏遊戲建議

- 判定用 `touch.DspTime` 與譜面的 dspTime 比較，不要用 `Time.time`；`MultiTouchClock.DspTimeToNs` 可反向換算。
- 收到 `Began` 立即播放打擊音效；使用有線音訊（藍牙延遲大且不固定）。
- 用 Latency Calibration 範例量出「觸控＋音訊輸出＋個人習慣」的總偏移，作為遊戲的判定偏移。
- 實測 ILITEK 回報率約 125 Hz（8 ms），時間戳記取自 HID 報告到達時間。

## 建置 macOS 執行檔

外掛 `Runtime/Plugins/macOS/MultiTouchKit.bundle` 已設定為 Editor（OSX）與 Standalone OSXUniversal，建置時自動包入。bundle 為 ad-hoc 簽章；若要簽章／公證你的 App，請連同 bundle 以你的身分重新簽章。執行檔首次開啟觸控螢幕時可能需要授權「輸入監控」。

## 更新原生外掛

C# 改動後可執行 `scripts/test-unity-offline.sh`：不開 Editor，用 Unity 內建的 Roslyn 編譯 Runtime（多組 define）與範例，再用內建的 dotnet 跑 Udp 傳輸與 JSON 解析器的測試（行為、與 System.Text.Json 的差分測試、零配置）。

原生程式碼（`Sources/MultiTouchKit`、`Sources/MultiTouchKitC`）改動後執行 `scripts/build-unity-plugin.sh`，並 commit 產出的 bundle。新增 C# 檔後執行 `python3 scripts/generate-unity-meta.py`（以 git URL 安裝的套件是唯讀的，缺 `.meta` 的檔案會被忽略）。C# 結構必須與 `multitouchkit.h` 一致（見 [c-api.md](c-api.md)）。
