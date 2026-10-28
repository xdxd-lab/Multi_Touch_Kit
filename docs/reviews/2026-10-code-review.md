# MultiTouchKit 程式碼審查（2026-10，main b80ac9e）

範圍：`Sources/`（MultiTouchKit、MultiTouchKitC、MultiTouchKitGestures、mtk-server／probe／viewer）、`Unity/…/Runtime` 與 `Samples~`、`Examples/`、`scripts/`、`Tests/`，約 7.9k 行全部讀過。
審查者：p3。以下「實施結果」為 5 批改善完成後補上；其後的內容是審查當時（b80ac9e）的問題與建議，保留原貌。

## 實施結果（2026-10-28）

| 批次 | 合併 | 內容 | 結果 |
|---|---|---|---|
| 1 `fix/correctness` | 5aa513c | A1–A10、D3、C API 與描述元測試 | C API 回呼保證「setter 返回後不再呼叫舊回呼」（含回呼內重入）；Unity 重複 Manager、Udp 逾時與對帳、描述元上限等；順帶修正 UdpTransport.Dispose 在 .NET on macOS 會卡住的問題。測試 82 → 97 |
| 2 `perf/hot-path` | 0dd0fcc | golden 測試先行，B1–B7、B11、C9 | mtk-server 輸出全開：rusage 3.7% → 1.6%（−57%），p2 取樣 3.12% → 0.93%；JSON 單次 6.4 → 0.48 µs、TUIO 4.7 → 0.38 µs（3 指）；輸出逐位元組不變；0 leaks。測試 → 109 |
| 3 `perf/unity-gc` | 3795fa5 | B8–B10、Python 範例行緩衝 | UdpTransport 每個封包配置 2.1／4.6 KB → 0 B（3／10 指）；專用 JSON 解析器與 System.Text.Json 差分測試 0 不一致；新增 `GetActiveTouches`、`scripts/test-unity-offline.sh` |
| 4 `refactor/structure` | 2c08f5d | C1–C8、C10 | 檔案拆分、HID 型別 internal／佇列 package、`TouchSource`、`CommandLineArguments`（錯誤參數 exit 2）、`Locked<Value>`、版本一致性測試；C 匯出符號不變。測試 → 111 |
| 5 `docs/comments` | `03a4512` | D1–D8、文件狀態 | 公開 API 文件註解（Swift `///`、C# XML doc，`-doc` 編譯檢查）、複雜演算法的「為什麼」、狀態更新；順帶修正 mtk-viewer 背景啟動時 SIGINT 無效（既有行為），新增 `scripts/check-signals.sh` |

未做（依審查判斷）：B12（手勢辨識器的配置，量很小）、`DisplaySelector` 的 Hashable 只比較 criteria（會改變相等語意）。

待使用者在 Unity 內實機確認：A5（換場景時重複的 Manager）、A7（Udp 逾時與溢位對帳）、B7（KeyWindow 座標）、B8–B10（Profiler 中 GC Alloc 為 0）。

標記：
- **風險**：「無」＝不改變對外行為與 ABI；「行為」＝對外可觀察的行為改變（已註明是否為 bug 修正）；「API」＝Swift／C# 原始碼層級的公開 API 增減；「ABI」＝C 結構或 `MTK_API_VERSION`。本報告沒有任何項目需要改 C ABI。
- **工作量**：S < 0.5 天、M 0.5–1.5 天、L > 1.5 天。

---

## Top 10

| # | 項目 | 類別 | 為什麼重要 |
|---|---|---|---|
| 1 | A1 C API 回呼在鎖外呼叫，`mtk_set_event_callback(NULL)` 返回後仍可能呼叫舊回呼 | 正確性 | C／Python 使用者釋放 user_data 後可能 use-after-free |
| 2 | A5 Unity 第二個 Manager（換場景）被銷毀時，會移除第一個 Manager 的 Input System 裝置 | 正確性 | 帶 `dontDestroyOnLoad` 換場景就會讓 Input System 觸控消失 |
| 3 | A7 Unity UDP 傳輸沒有幽靈觸點保護，佇列也沒有上限 | 正確性 | mtk-server 被 kill 或重啟時，`ActiveTouches` 會永遠卡住 |
| 4 | A3 `MultiTouchManager` 沒呼叫 `stop()` 就被釋放：deinit 在佇列外拆除裝置，加上 `[unowned self]` | 執行緒安全 | 資料競爭，或在 HID 佇列上崩潰 |
| 5 | B1／B2 mtk-server 的輸出成本主要是核心的 socket 處理，不是編碼；連線式 UDP（connect）實測 sys −27% | 效能 | 回應 p2 的 B1 基準（1.85% CPU） |
| 6 | B3／B4 TouchJSON 的 `String(format:)`、TUIO 每則訊息都配置 Data | 效能 | 輸出全開時 user 時間 +63%；可做到輸出位元組不變 |
| 7 | A6／D3 Unity UdpTransport 只綁定 127.0.0.1，文件卻寫可接收另一台 Mac 的資料 | 正確性／文件 | 文件描述的用法不可能成功 |
| 8 | A4 重試中的 io_service 在 `stop()` 時沒有釋放；拔除後顯示誤導的訊息 | 資源洩漏 | 每次 stop 洩漏 IOKit 物件 |
| 9 | C11 缺少 TouchJSON／TUIO 的 golden 測試與 C API 的測試 | 可維護性 | B 類重構前必須先有，才能證明「輸出不變」 |
| 10 | D5／D6 公開 API 文件註解有缺漏；Unmanaged 生命週期與 hybrid mode 等「為什麼」沒有說明 | 註解 | 對外套件的基本門檻 |

---

## 量測（回應 p2 B1 基準）

### 方法

1. **整個程序的 CPU**：使用 rusage 計時，比每秒一次的 ps 取樣精確，也能分開 user 與 sys：
   ```sh
   B=.build/release/mtk-server
   /usr/bin/time -p perl -e 'alarm 15; exec @ARGV' $B --simulate [選項] >/dev/null
   ```
2. **編碼微基準**：暫時加入一個測試，以 `ContinuousClock` 量測 20,000 次編碼，`MTK_BENCH=1 ./scripts/test.sh -c release --filter …` 執行（已移除，perf 分支會正式加入，見「需核可」）。
3. **配置次數**（perf 分支前後對照）：
   ```sh
   xctrace record --template Allocations --time-limit 15s --launch -- .build/release/mtk-server --simulate
   ```
   比較每秒的暫時配置數（transient allocations）。另外用 `leaks --atExit -- …` 確認沒有洩漏。
4. **Unity GC**：在 Profiler 的 CPU 模組看 `PollNow` 與 `OnGUI` 的 GC Alloc 欄位，或在 PlayMode 測試中用 `GC.GetAllocatedBytesForCurrentThread()` 包住 `Poll`。

### 結果（`--simulate` drums：每 frame 2–3 指、125 Hz、15 秒，M 系列 Mac）

| 設定 | user (s) | sys (s) | 合計占單核 |
|---|---|---|---|
| 輸出全關 | 0.19 | 0.06 | 1.7% |
| 只有 UDP JSON | 0.22 | 0.22 | 2.9% |
| 只有 WebSocket（沒有用戶端） | 0.20 | 0.06 | 1.7% |
| 只有 TUIO | 0.28 | 0.23 | 3.4% |
| 全開（預設） | 0.31 | 0.27 | 3.9% |
| UDP，接收端 `nc -ul` 有在聽 | 0.24 | 0.24 | 3.2% |
| UDP 改成 connect()＋send()（原型） | 0.22 | **0.16** | 2.5% |
| connect 原型，兩個 UDP 目的地 | 0.23 | 0.15 | 2.5% |

微基準（緊密迴圈，快取是熱的）：

| 編碼 | 3 指 | 10 指 |
|---|---|---|
| `TouchJSON.frame` | 6.4 µs | 17.1 µs |
| `TUIOEncoder.encode` | 4.7 µs | 10.1 µs |
| `ContactTracker.update`（核心觸控處理） | 0.4 µs | 1.1 µs |

結論：
- **輸出成本多半是 sys**（每 frame 的 sendto 讓核心走完 loopback 的 UDP／IP 路徑）。編碼的 user 時間約占整體差距的 1/3。
- 每 frame 的 sys 成本主要是固定開銷（喚醒＋第一次進入網路堆疊），不是每個封包各自的成本：connect 後兩個目的地的 sys 和一個目的地相同。緊密迴圈中 sendto 每次 3.9 µs、connected send 1.4 µs，但 125 Hz 下每次都是冷快取，實際成本大很多。
- WebSocket 沒有用戶端時幾乎零成本，不過每 frame 仍會組 JSON（見 B2）。
- 核心觸控處理（解析＋追蹤）每 frame 約 1 µs，不需要優化。p2 測到的「輸出全關 1.27%」主要是 125 Hz 的計時器喚醒與模擬來源本身。
- 預期效果：B1 至 B4 全做後，全開約從 3.9% 降到 2.5%（−35%）。剩下的是核心網路堆疊，使用者空間無法再降。

---

## (A) 正確性、執行緒安全、資源洩漏、邊界條件

**A1 C API 回呼的 use-after-free 競爭** — `Sources/MultiTouchKitC/CAPI.swift:127-133`、`:67-72`
- 問題：`enqueue` 在鎖內取出 `(callback, userData)`，在鎖外呼叫。其他執行緒呼叫 `mtk_set_event_callback(NULL, …)` 並返回後，HID 佇列可能正要（或正在）以舊的 user_data 呼叫舊回呼。C／Python／Rust 使用者通常在設為 NULL 之後立刻釋放 user_data。Unity 目前只用輪詢，不受影響。
- 建議：另設一個回呼鎖（`NSRecursiveLock`，允許在回呼內再呼叫 set），回呼期間持有。`mtk_set_event_callback` 取得同一把鎖，等進行中的回呼結束才返回。header 註明：「返回後保證不會再以舊的 callback／user_data 呼叫」，並註明不可在回呼內呼叫 `mtk_stop`（會等待 HID 佇列而死鎖）。另外加上 C API 測試（見 C11）。
- 風險：行為（bug 修正，保證變得更強，ABI 不變）。
- 工作量：S

**A2 `mtk_start`／`mtk_stop` 沒有序列化** — `CAPI.swift:27-65`
- 問題：兩個執行緒同時呼叫 `mtk_start` 時，兩邊都會 `stop()` 再各自建立 manager。後寫入的會覆蓋 `self.manager`，先建立的 manager 不會被停止：它持續獨占裝置，新的 manager 則無限重試。`start` 執行期間的 `mtk_stop` 也有類似的空窗。
- 建議：加一把生命週期鎖（與資料鎖分開，避免 frameHandler 拿資料鎖時死鎖），整個 start／stop 都在鎖內執行。
- 風險：無（bug 修正）。
- 工作量：S

**A3 Manager 未呼叫 stop 就被釋放** — `Sources/MultiTouchKit/MultiTouchManager.swift:69-71`、`:225-228`
- 問題：`deinit` 直接呼叫 `teardown()`。teardown 不在 `queue` 上，與 HID 佇列上正在執行的 `handleReport` 存取同一批 `devices` 與 handler，形成資料競爭。另外 `allocateTouchID` 用 `[unowned self]`：deinit 期間如果佇列上還有一筆已排入的 input report，就會存取已釋放的物件而崩潰。
- 建議：deinit 中若不在 queue 上就 `queue.sync { teardown() }`；若在 queue 上（handler 內釋放了最後一個參照）就直接執行。`allocateTouchID` 改用 `[weak self]`，或把計數器放進 device 與 manager 共用的小盒子。另加一個「start 後直接釋放」的測試（模擬來源不適用；可以在 `TouchDevice` 注入假的 report 測試）。
- 風險：無。
- 工作量：S

**A4 重試中的 service 沒有釋放，拔除後顯示誤導的訊息** — `MultiTouchManager.swift:149`、`:210-212`、`:296-307`
- 問題：`pending` 裡的 `io_service_t` 在 `:210` 做了 `IOObjectRetain`，但 `teardown` 只呼叫 `pending.removeAll()`，沒有逐一 `IOObjectRelease`，所以每次 stop 都會洩漏。另外，被其他程式獨占期間拔掉裝置時，下次重試 `IOHIDDeviceCreate` 會回傳 nil，log 卻寫「不是可解析的多點觸控螢幕，略過」，訊息不正確。
- 建議：teardown 時逐一 release。`TouchDevice.init` 把「無法建立裝置（已移除）」與「描述元不是觸控螢幕」分成兩種結果。
- 風險：無（log 文字改變）。
- 工作量：S

**A5 Unity 重複的 Manager 會拆掉 Input System 裝置** — `Unity/…/Runtime/MultiTouchKitManager.cs:80-99`、`:159-183`
- 問題：第二個 Manager（例如第 2 個場景也放了一個，第一個有 `dontDestroyOnLoad`）在 `Awake` 中 `Destroy(this)`。銷毀時 Unity 會呼叫它的 `OnDisable` → `StopTransport()` → `MultiTouchInputSystemBridge.Disable()`。Bridge 是靜態的，於是第一個 Manager 的虛擬 Touchscreen 被移除，Input System／UI 觸控整個消失，Console 也沒有錯誤。
- 建議：`OnDisable`／`StopTransport` 開頭加上 `if (Instance != this) return;`。Bridge 只由啟用它的那個 Manager 停用（用旗標記錄）。
- 風險：無（bug 修正）。
- 工作量：S（需要 Unity 驗證：兩個場景各放一個 Manager 並切換）

**A6 UdpTransport 只綁定 loopback，與文件不符** — `Unity/…/Transports/UdpTransport.cs:58`、`docs/unity.md:89`
- 問題：程式綁定 `IPAddress.Loopback`，文件卻建議 Windows／Linux 編輯器接收「另一台 Mac 的 `mtk-server --udp <這台 IP>:7777`」。這不可能成功。
- 建議：最小修正是修改文件。若要支援這個用法，可以新增一個綁定位址欄位，預設維持 loopback（安全性考量）；新名稱需要核可。
- 風險：只修文件為無；加欄位為 API。
- 工作量：S

**A7 Unity UDP 沒有幽靈觸點保護，佇列也沒有上限** — `UdpTransport.cs:41`、`:72-125`
- 問題：
  1. mtk-server 被 SIGKILL、當機或重新安裝 LaunchAgent 時，最後的 `ended` 不會送出。loopback 接收緩衝區滿時也可能掉封包。這些情況下 `ActiveTouches` 會永遠留著觸點。Native 傳輸已經有 stale、watchdog 與 resync 保護，UDP 完全沒有。
  2. 主執行緒暫停（`runInBackground=false` 且失焦）時，`ConcurrentQueue<string>` 會無上限成長。
- 建議：UdpTransport 記錄最後收到封包的時間。有觸點時超過 0.5 秒沒有封包（server 按住時以 125 Hz 送出），就把仍在的觸點以 Cancelled 送出。佇列設上限（例如 1024 個封包）：溢位時清空，並在下次 Poll 以「全部 Cancelled、之後的 began 重新建立」的方式對帳。
- 風險：行為（新的 Cancelled 事件，屬於 bug 修正）。新欄位或常數名稱需要核可。
- 工作量：M

**A8 公開 handler 屬性沒有同步** — `Sources/MultiTouchKit/SimulatedTouchSource.swift:22`、`Sources/MultiTouchKitGestures/GestureController.swift:29`
- 問題：兩者都是 `@unchecked Sendable` 類別的公開 `var`，會在 `queue` 上讀取。`start()` 之後才設定（或從主執行緒改）時有資料競爭。`MultiTouchManager` 的同類屬性有加鎖，這兩處不一致。
- 建議：比照 `MultiTouchManager` 用 `NSLock` 包裝，或另寫一個小型的 `Locked<T>`（見 C7）。
- 風險：無。
- 工作量：S

**A9 HID 描述元解析沒有上限** — `Sources/MultiTouchKit/HIDReportDescriptor.swift:194-207`、`:231-233`
- 問題：Report Count／Report Size 直接取用 32 位元值。畸形或惡意的 USB 裝置可以宣告 `Report Count = 0xFFFFFFFF`，迴圈會配置數十億個 `HIDField`，造成記憶體耗盡或卡住。HID 描述元來自外部裝置，屬於不可信輸入。
- 建議：Report Count 上限 4096、Report Size 上限 256，以及單一報告的總位元數上限，超過就 throw `HIDDescriptorError`。加入 fuzz 式的測試（隨機位元組不崩潰）。
- 風險：無。
- 工作量：S

**A10 其他小問題**（每項 S，可併入 A 分支）
- `Unity/…/Samples~/TouchVisualizer/TouchVisualizerDemo.cs:29`、`LatencyCalibrationDemo.cs:37`：`Texture2D`／`AudioClip` 沒有在 `OnDestroy` 中 `Destroy`，編輯器每次 Play 都會累積。範例會被照抄，應該示範正確寫法。
- `CAPI.swift:261-268`：在背景執行緒呼叫 `mtk_set_display` 是非同步套用的，緊接著在主執行緒呼叫 `mtk_touch_display_id` 可能還是舊值。只需在 header 註明。
- `MultiTouchManager.swift:321-331`：`PowerObserver.init` 在 `rootPort != 0` 但沒有取得 port 的分支回傳 nil，沒有 `IOServiceClose`。實務上不會發生，可順手修。
- `Sources/MultiTouchKit/Protocols/TUIOEncoder.swift:71`：`frameID &+= 1` 是 Int32，約 198 天（125 Hz）後會變成負數。TUIO 把 fseq −1 視為特殊值，改成在 1…Int32.max 之間循環即可。

---

## (B) 熱路徑效能與記憶體

**B1 UDP 改用 connect() 的 socket** — `Sources/mtk-server/Outputs.swift:11-40`
- 問題：每次 `sendto` 都要查路由並複製位址。
- 建議：init 時 `connect()`，之後改用 `send()`。connect 後，沒有接收端時下一次 send 可能回傳 `ECONNREFUSED`，目前的程式本來就忽略回傳值，維持忽略即可。
- 量測：上表原型 sys 0.22 → 0.16（−27%）。
- 風險：無。
- 工作量：S

**B2 沒有接收者時不組 JSON；UDP 與 WS 共用同一份 Data** — `Sources/mtk-server/ServerMain.swift:319-334`、`Outputs.swift:90-94`
- 問題：`TouchJSON.frame` 在沒有 UDP 目的地、也沒有 WS 用戶端時仍然每 frame 執行。UDP 用 `Data(json.utf8)`，`broadcast` 又把同一個字串再轉一次 Data。另外 TUIO 每 frame 都會執行 `active.values.sorted` 與 `filter`。
- 建議：先判斷 `udp.isEmpty && webSocket?.hasClients != true` 就略過，只產生一份 `Data` 給兩邊共用。`active` 改為依 id 排序的小陣列（最多 10 筆），省去每 frame 排序。
- 風險：無。
- 工作量：S

**B3 TouchJSON 編碼** — `Sources/MultiTouchKit/Protocols/TouchJSON.swift:8-23`、`:54-56`
- 問題：每根手指 2–5 次 `String(format: "%.5f")`（經過 NSString 橋接與配置），再加上 `"\(t.phase)"` 的字串插值，以及沒有預留容量、反覆成長的 `s +=`。
- 建議：直接寫進預留容量的 `[UInt8]`（或 `String(unsafeUninitializedCapacity:)`），整數與 0…1 定點小數手寫格式化，phase 用靜態字串表。新版本提供 `frameData(_:) -> Data` 給 server 使用；舊的 `frame(_:) -> String` 保留並改為包裝新版本。
- 輸出必須逐位元組相同：以 100 萬個亂數加邊界值（0、1、0.000005、0.999995、四捨五入的 tie）與 `String(format:)` 比對。`%.5f` 是依二進位值精確四捨五入，手寫版要用整數運算處理，不能單純用 `(v*1e5).rounded()`。
- 量測：微基準與 rusage（預期 user 時間降到 1/3 以下）。
- 風險：無（以測試保證）。
- 工作量：M

**B4 TUIO 編碼** — `TUIOEncoder.swift:11-55`、`:70-94`
- 問題：每則 OSC 訊息新建一個 `Data`，`appendString` 每次又配置 `Array(s.utf8)` 與補零陣列；`bundle` 再複製所有元素。每 frame 還有 `alive.map`、`Set(...)`，以及 `last.filter` 產生新字典。3 指時每 frame 約 30 次配置。
- 建議：用單一 `[UInt8]` 緩衝區（保留在 encoder 內重複使用）直接寫入 bundle，每則訊息的長度先留空、寫完再回填。固定的 `source` 訊息預先編好。`last` 改為依 id 就地移除。
- 輸出必須逐位元組相同：先補上 golden 測試（C11）。
- 量測：微基準與 rusage。
- 風險：無。
- 工作量：M

**B5 核心解析與追蹤的配置** — `Sources/MultiTouchKit/DigitizerLayout.swift:119-143`、`:153-176`、`:222-279`
- 問題：每份報告會配置 `contacts`、`pending`／`filter`、`seen: Set`，`active.sorted` 每 frame 都執行（即使所有觸點都在），再加上 `out`，約 5 次配置。
- 量測結果：10 指時每 frame 1.1 µs（0.014% CPU），**不值得為此增加複雜度**。
- 建議：只做兩個零風險的小改動：`sorted` 改成「先找出沒出現的觸點，有才排序」；`seen` 改用小陣列（最多 10 筆，線性搜尋比 Set 快）。`HIDField.value` 的逐位元迴圈維持現狀，因為它已包含在上述量測內。
- 風險：無。
- 工作量：S（低優先）

**B6 C API 的佇列路徑** — `CAPI.swift:74-88`、`:105-134`、`Sources/MultiTouchKit/TouchEventQueue.swift:62-92`
- 問題：`enqueue` 每 frame 拿兩次鎖（`reportStationary` 一次、push 一次），並配置一個 `events` 陣列。`poll` 先 `pop` 成新的陣列再逐筆複製到呼叫者的 buffer。
- 建議：
  - `TouchEventQueue` 新增 `pop(into: UnsafeMutableBufferPointer<Event>) -> Int`，在鎖內直接寫入呼叫者的 buffer。
  - `enqueue` 合併成一次加鎖；暫存陣列改用 `withUnsafeTemporaryAllocation`。
  - `copyCString`（`:299-314`）每個 Unicode scalar 都配置 `Array(String(scalar).utf8)`，改用 `scalar.utf8` 的長度判斷邊界。
- 風險：無。新增的 `pop(into:)` 為 package 層級 API。
- 工作量：S

**B7 Unity KeyWindow 對應的每個觸點成本** — `CAPI.swift:229-248`、`:277-297`；呼叫端 `MultiTouchKitManager.cs:226-234`
- 問題：每個觸點都會呼叫 `mtk_map_to_window` → `TouchDisplay.resolve()` → `CRuntime.devices`（兩把鎖，加上複製含 String 的結構陣列），再做陣列相等比較，最後 `CGDisplayBounds` 呼叫 2 次。
- 建議：`CRuntime` 維護一個裝置世代計數（deviceHandler 事件時加 1），快取檢查改為比較整數；`CGDisplayBounds` 隨同一份快取一起保存（顯示器重新設定時清除）。
- 風險：無。
- 工作量：S

**B8 Unity UdpTransport 每個封包的 GC** — `UdpTransport.cs:79-80`、`:95-124`
- 問題：每個封包會產生以下配置，約 1–2 KB；125 Hz 時主執行緒每秒產生 150–250 KB 垃圾：
  - `Receive` 新配置一個 `byte[]`。
  - `GetString` 產生字串。
  - `JsonUtility.FromJson` 建立 `FrameMessage`、`TouchMessage[]` 與 phase 字串。
  - 另外還有一次 `IndexOf` 掃描。
- 建議：
  - 改在接收執行緒解析，把結果放進 `ConcurrentQueue<MultiTouchTouch>`，主執行緒只負責取出。
  - 解析改用 `JsonUtility.FromJsonOverwrite` 搭配重複使用的物件，或為固定格式寫一個專用的小型解析器。
  - 接收改用 `Socket.ReceiveFrom(byte[] 重用緩衝區)`。
- 量測：Profiler GC Alloc（目標：每幀主執行緒 0 B）。
- 風險：無。
- 工作量：M（需要 Unity 驗證）

**B9 `ActiveTouches` 列舉會 boxing** — `MultiTouchKitManager.cs:67`；使用處 `TouchVisualizerDemo.cs:69`
- 問題：型別是 `IReadOnlyDictionary`，`foreach (… .Values)` 透過介面取得 enumerator，每次列舉都會配置。
- 建議：保留現有屬性，另外新增一個不配置的存取方式，例如把觸點複製到呼叫者提供的 List 的方法，或直接回傳 `Dictionary<,>.ValueCollection`。新名稱需要核可。
- 風險：API（新增）。
- 工作量：S

**B10 Unity 範例的 OnGUI 配置** — `TouchVisualizerDemo.cs:75`、`:79-81`；`LatencyCalibrationDemo.cs:82-89`、`:111-115`
- 問題：OnGUI 每幀會呼叫多次（Layout、Repaint 等）。每次都重新組 HUD 字串、為每個觸點呼叫 `Id.ToString()`，還有 enum 的 `ToString()`。`Median()` 每次呼叫都 `new List` 並排序，每次 OnGUI 會呼叫 1–2 次。
- 建議：數值改變時才重組字串並快取；`Median`／`StandardDeviation` 在新增樣本時計算一次。範例會被照抄，應示範零 GC 的寫法。
- 風險：無。
- 工作量：S

**B11 mtk-probe 每 frame 查詢游標** — `Sources/mtk-probe/Probe.swift:169-172`
- 問題：`CGEvent(source: nil)` 是對 WindowServer 的 IPC，每秒 125 次，會干擾量測本身。
- 建議：改用 10 Hz 計時器取樣。
- 風險：無（統計值的意義不變）。
- 工作量：S

**B12 低優先，不建議現在做**
- `GestureRecognizer`：每 frame 有 `pendingHistory` 複製 `down` 字典、`samples + [Sample]`、enum 酬載的陣列複製。只在 `--gestures` 時執行，量很小，等 profiler 顯示有需要再做。
- `ScreenMapping.globalPoint`／`cocoaPoint`（`MultiTouchClock.swift:62-73`）每次呼叫 `CGDisplayBounds` 1–2 次，viewer 與 GestureController 每個觸點都會呼叫。可以每 frame 快取一次 bounds，屬於微小改善。

記憶體：RSS 16.8 → 17.9 MB（輸出全開）是 Network.framework 與 socket 的固定成本。程式中沒有看到會持續成長的結構，唯一的例外是 A7 的 Unity UDP 佇列。perf 分支會加上 `leaks --atExit` 驗證。

---

## (C) 結構與可維護性

**C1 拆分 `DigitizerLayout.swift`** — `Sources/MultiTouchKit/DigitizerLayout.swift`（305 行，5 個型別）
- 建議：拆出 `ContactTracker.swift`（含 StalePolicy）、`FrameAssembler.swift`、`ReportTimeoutMonitor.swift`；`HIDUsage` 移到 `HIDReportDescriptor.swift`。
- 風險：無。
- 工作量：S

**C2 公開 API 的存取層級** — `HIDReportDescriptor.swift`（`HIDReportKind`、`HIDCollection`、`HIDField`、`HIDReportDescriptor` 都是 public）、`TouchEventQueue.swift`（`QueuedTouchEvent`、`TouchEventQueue` 是 public）
- 問題：HID 解析型別只在模組內使用（測試透過 `@testable` 存取）。佇列型別 public 只是為了給 MultiTouchKitC 使用。這些實作細節因此暴露成公開 API，以後很難修改。
- 建議：HID 型別改為 internal；佇列型別改為 `package`（tools 6.0 可用）。
- 風險：API（移除公開符號，對外部 Swift 使用者是原始碼不相容的改動；套件尚未 1.0，應該沒有外部使用者）。**需要 p1 決定。**
- 工作量：S

**C3 `MultiTouchDeviceInfo` 沒有 public init** — `Sources/MultiTouchKit/Touch.swift:91-107`
- 問題：外部程式無法自行建立，不能用來測試或模擬 `DisplayLocator.resolve(panel:)`。
- 建議：加上 public 的逐欄 init。
- 風險：API（新增）。
- 工作量：S

**C4 `GestureRecognizer.process` 過長，且有一段不會執行的程式** — `Sources/MultiTouchKitGestures/GestureRecognizer.swift:146-296`、`:366-368`
- 問題：`process` 有 150 行，各狀態的處理全部寫在同一個 switch 裡。`tap()` 第 366 行的 `case 1 where duration >= longPressDuration` 永遠不會執行：第 361 行已經涵蓋這個情況，因為 tapSlop 14 小於 slowDragSlop 40。
- 建議：拆成 `processPointer`、`processScroll`、`processTransform`、`processSwipe`，以現有 40 多項手勢測試保護；刪除不會執行的分支。
- 風險：無。
- 工作量：M

**C5 三個執行檔各自解析參數**
- 位置：`ServerMain.swift:61-142`、`Probe.swift:24-46`、`ViewerApp.swift:28-56`。
- 問題：
  - `--stale-touch-timeout`、`--display`、`--simulate` 寫了三份。
  - viewer 用 `firstIndex(of:)`：未知選項不會報錯，`--rotate` 給錯誤值也會被默默忽略。
  - probe 的 `--seconds abc` 也會被默默忽略。
- 建議：以 `package` 層級在 MultiTouchKit 加一個小型的共用解析輔助，三個執行檔統一行為：未知選項與格式錯誤都以 exit 2 結束。
- 風險：行為（viewer／probe 遇到錯誤參數時改為報錯，屬於 bug 修正）。
- 工作量：M

**C6 「觸控來源」沒有共同介面**
- 問題：server、probe、viewer 都各自寫了 `if simulate { SimulatedTouchSource } else { MultiTouchManager }` 的分支與 queue 選擇；`onQueue` 輔助函式也重複了兩份（`MultiTouchManager.swift:133`、`SimulatedTouchSource.swift:39`）。
- 建議：新增一個觸控來源 protocol，涵蓋 queue、frameHandler、start／stop 與裝置清單，兩個實作都遵循它。名稱需要核可。
- 風險：API（新增）。
- 工作量：M

**C7 加鎖屬性的樣板程式重複出現**
- 位置：`MultiTouchManager.swift:44-94`、`GestureController.swift:31-64`、`ServerMain.swift:178-180`、A8 的兩處。
- 建議：寫一個內部用的 `Locked<T>`，以 `NSLock` 實作。`Synchronization.Mutex` 需要 macOS 15，部署目標是 13，所以不能用。
- 風險：無。
- 工作量：S

**C8 版本字串有兩個來源**
- 位置：`Touch.swift:4`（0.1.0）、`Unity/…/package.json`（0.1.0）；`build-unity-plugin.sh:9` 用 sed 從 Swift 原始碼取出版本。
- 建議：加一個測試，比對 `package.json` 與 `MultiTouchKitVersion.string` 是否一致。
- 風險：無。
- 工作量：S

**C9 server 的輸出邏輯集中在 `handle`** — `ServerMain.swift:319-341`
- 建議：拆成一個「輸出分送」型別，負責 JSON、UDP、WS、TUIO 與「有沒有接收者」的判斷，配合 B2 一起做。
- 風險：無。
- 工作量：S

**C10 其他命名與一致性**
- `GestureOutputState.MouseButtonKey`（`GestureOutput.swift:28`）存在的原因是 `MouseButton` 沒有 Hashable。直接讓 `MouseButton` 加上 `Hashable` 即可移除這個型別（API 新增 Hashable 遵循，無風險）。
- `DisplaySelector` 的 Hashable 同時比較 `text` 與 `criteria`：條件相同、文字不同的兩個 selector 會被視為不相等，可只比較 `criteria`。目前沒有程式依賴這個比較，屬於低優先。

**C11 測試缺口（B 類重構前必須先補）**
- `TouchJSON.frame`／`device`／`hello` 的 golden 字串測試，含 escape、控制字元與 `%.5f` 邊界值。
- `TUIOEncoder` 的 golden 位元組測試，含 alive、set、fseq 與速度。
- C API 測試：讓測試 target 依賴 MultiTouchKitC，驗證：
  - `MemoryLayout` 大小與 header 一致（32／56／160）。
  - `mtk_start(NULL)` 與 struct_size 檢查。
  - poll 與 resync 的訊息。
  - A1 的回呼保證（以 `CRuntime` 注入 frame）。
- `HIDReportDescriptor` 的畸形輸入測試（A9）。
- 風險：無。
- 工作量：M

---

## (D) 註解

**D1 錯置的文件註解** — `DigitizerLayout.swift:179-181`
- 問題：「把每個 frame 的觸點轉成帶有 began／moved／ended 的 Touch」是 `ContactTracker` 的說明，卻和 `ReportTimeoutMonitor` 的說明併在一起，掛在 `ReportTimeoutMonitor` 上。`ContactTracker`（`:201`）本身反而沒有型別說明。
- 建議：拆開，各自放到正確的型別上。
- 工作量：S

**D2 過時的狀態說明** — `docs/unity.md:5`
- 問題：仍寫著「尚未在 Unity 內實際驗證（開發機尚未安裝 Unity）」，但 D3 與 D4 已經在 Unity 實機驗證過。
- 建議：更新為實際的驗證範圍（Native 傳輸、失焦 resync、stale）。`docs/PRE_ANALYSIS.md:63` 是歷史文件，不改內容，只在檔頭註明「為前期分析紀錄」。
- 工作量：S

**D3 錯誤的用法說明** — `docs/unity.md:89`
- 見 A6。

**D4 註解中混入調整歷程** — `GestureRecognizer.swift:74-76`
- 問題：`momentumFriction` 的註解記錄了使用者的調整過程（「使用者在 2.8 實測後要求再多 33%…」）。
- 建議：註解只保留「為什麼」（距離 ≈ 速度 ÷ friction，以及初速沿用手指速度的理由）；調整歷程移到 `docs/gestures.md` 的「參數調整紀錄」段落。
- 工作量：S

**D5 公開 API 缺少文件註解**（`///` 或 XML doc）
- Swift：
  - `MultiTouchError` 各 case。
  - `MultiTouchManager.start()`：會丟出什麼錯誤、重複呼叫的行為、找不到裝置時仍會成功。
  - `stop()`、`isRunning`。
  - `MultiTouchDeviceInfo` 的 id、vendorID、product、serialNumber、locationID、exclusive。
  - `DeviceEvent.added`／`removed`。
  - `TouchFrame.deviceID`、`Touch.phase`。
  - `DisplayInfo` 的 isMain、isBuiltin、pixelWidth、refreshRate、rotation。
  - `DisplaySelector.Criterion` 與 `init(criteria:text:)`。
  - `TUIOEncoder.source`。
  - `SimulatedTouchSource.start`／`stop`／`deviceID`。
  - `GestureEvent` 的 mouseDown、mouseUp 與 clickCount 的意義。
  - `MouseButton`、`GestureTouch.position` 的座標系。
  - `GestureController.handle`／`cancel` 的執行緒要求，目前寫在類別說明，個別方法沒有。
- Unity：
  - `MultiTouchKitNative` 的三個結構欄位與每個 extern 函式：至少一行說明，並註明「詳見 multitouchkit.h」。
  - `IMultiTouchTransport` 各成員。
  - `MultiTouchKitManager` 的公開欄位：目前只有 Tooltip，IDE 看不到；加上 `<summary>`，或在類別說明中列出。
  - `MultiTouchTouch.ContactId`／`DeviceId`。
- 工作量：M

**D6 需要補「為什麼」的地方**
- `TouchDevice.activate`／`cancel`／`attachSibling`（`TouchDevice.swift:85-123`、`:267-280`）：Unmanaged context 的擁有權。`passRetained` 讓裝置在 IOKit 回呼期間不會被釋放；cancel handler 中的 `takeRetainedValue` 釋放這個參照，且 cancel handler 之後保證不會再有回呼，所以 `deinit` 才釋放 `reportBuffer` 是安全的。這是全專案最容易被改壞的地方。
- `FrameAssembler`（`DigitizerLayout.swift:146-177`）：Microsoft hybrid mode 的規則（第一份報告的 Contact Count 為總數，後續報告為 0），以及遺失後續報告時如何恢復。
- `DisplayLocator.closestBySize`（`DisplayLocator.swift:204-220`）：
  - 為什麼用 log 比例：對放大與縮小對稱，長短邊可以直接相加。
  - 為什麼是 30%：EDID 尺寸常以公分捨入；MF156LR 的觸控面板 309×174 mm 與面板 EDID 有差距。
  - 為什麼長短邊分開比對：不受旋轉影響。
- `GestureRecognizer`：檔頭加上狀態轉移概要（idle → pending → pointer、scroll、transform、swipe → waitLift → idle）與「手勢決定後不再改變」的原則；詳細的狀態圖放在 `docs/gestures.md`。
- `CAPI.mtkStart`（`CAPI.swift:158`）：為什麼用 `struct_size >=`。舊程式的結構小於目前大小時拒絕；未來新增欄位後，新程式的結構較大，舊版程式庫仍可接受，只讀取自己知道的部分。
- `CGEventGestureOutput.field`（`GestureOutput.swift:404`）：為什麼 force unwrap 是安全的（匯入的 C enum 接受任意 rawValue）。
- `ContactTracker.update` 的 stale 判斷（`DigitizerLayout.swift:237-247`）：錨點只在明顯移動時更新，而不是每 frame 更新，否則緩慢漂移的幽靈觸點永遠不會被判定為 stale。
- 工作量：S

**D7 `multitouchkit.h` 需要補充的保證**
- A1 的回呼保證，以及不可在回呼內呼叫 `mtk_stop`。
- `mtk_start` 的 struct_size 規則。
- `mtk_set_display` 從非主執行緒呼叫時是非同步套用。
- `mtk_poll_events` 與回呼同時使用時，事件會分別出現在兩邊（目前寫「同時有效」，語意不夠明確）。
- 工作量：S

**D8 語言與風格**
- 現有註解全部是繁體中文，術語保留英文，風格一致，維持即可。
- 冗餘註解很少；`ViewerApp.swift:244` 的 `ViewerAppViewBox` 說明正確，保留。

---

## 分批實作計畫

| 順序 | 分支 | 內容 | 驗證（p2） | 需要實機或 Unity |
|---|---|---|---|---|
| 1 | `fix/correctness` | A1–A10、D3，以及 C11 中的 C API 與描述元測試 | `./scripts/test.sh`；新增的回呼與描述元測試；`mtk-server --simulate` 加 SIGKILL 後的 Unity UDP 測試 | A5、A7 需要 Unity（先問 p1）；A3、A4 用單元測試即可 |
| 2 | `perf/hot-path` | 先補 C11 的 golden 測試，再做 B1–B7、B11，C9 一起做 | golden 測試逐位元組一致；上表 rusage 前後對照（目標全開 sys −25%、user −40%）；`leaks --atExit`；xctrace 配置數 | 不需要實機；B7 建議在 Unity KeyWindow 模式快速確認 |
| 3 | `perf/unity-gc` | B8–B10 | Profiler GC Alloc 降到每幀 0 B（Native 與 UDP 兩種傳輸） | 需要 Unity |
| 4 | `refactor/structure` | C1、C3–C8、C10（C2 待決定） | 全部測試；三個執行檔的參數行為對照表 | 不需要 |
| 5 | `docs/comments` | D1、D2、D4–D8 | 人工審閱；C# 以 Unity 內建的 Roslyn 離線編譯確認 XML doc 沒有警告 | 不需要 |

第 4、5 批可以平行進行（檔案重疊時以 4 為準，5 rebase）。第 1 批應該最先合併。

## 需要 p1 核可的事項

1. **C2** 把 HID 解析型別與 `TouchEventQueue` 從 public 降為 internal 或 package（原始碼不相容）。
2. **新名稱**：
   - B9：不配置的 ActiveTouches 存取方式。
   - C6：觸控來源 protocol。
   - A6：Unity UDP 綁定位址欄位，或只修文件。
   - A7：Unity UDP 逾時欄位，或改用固定常數。
   - 微基準的開關環境變數（暫定 `MTK_BENCH`，只影響測試）。
3. **行為改變（bug 修正）**：
   - A7：Unity UDP 新增 Cancelled 事件。
   - C5：viewer／probe 遇到錯誤參數時改為以 exit 2 結束。
   - A1：`mtk_set_event_callback` 會等待進行中的回呼結束。
4. **Unity 實機測試的時機**：A5、A7、B7–B10。
