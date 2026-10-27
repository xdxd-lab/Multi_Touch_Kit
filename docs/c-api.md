# C ABI／原生外掛使用說明

`MultiTouchKitC` 把 Swift 核心包成純 C 介面，同程序讀取觸控（延遲與 Swift Package 相同）。適用 Unity（`DllImport "MultiTouchKit"`）、C/C++、Python ctypes、Godot GDExtension、Rust FFI 等。

- 標頭：`Sources/CMultiTouchKit/include/multitouchkit.h`（唯一的 ABI 定義）
- 實作：`Sources/MultiTouchKitC/CAPI.swift`（Swift `@_cdecl` 匯出）

## 取得程式庫

| 檔案 | 產生方式 | 架構 |
|---|---|---|
| `.build/release/libMultiTouchKitC.dylib` | `swift build -c release --product MultiTouchKitC` | 本機架構 |
| `Unity/com.xdxd-lab.multitouchkit/Runtime/Plugins/macOS/MultiTouchKit.bundle` | `scripts/build-unity-plugin.sh`（已 commit） | arm64＋x86_64 universal，ad-hoc 簽章 |

bundle 內的執行檔是 `MultiTouchKit.bundle/Contents/MacOS/MultiTouchKit`，可直接 `dlopen`。程式庫只連結系統框架與 `/usr/lib/swift`（macOS 13 起內建），不需另外附帶 Swift runtime。

## 範例

- C：`Examples/c/basic.c`，以 `scripts/build-c-example.sh [秒數]` 編譯並執行。手動編譯：
  ```sh
  swift build -c release --product MultiTouchKitC
  clang -I Sources/CMultiTouchKit/include Examples/c/basic.c -L .build/release -lMultiTouchKitC \
        -Wl,-rpath,"$PWD/.build/release" -o mtk-c-example
  ```
- Python：`python3 Examples/python/native_ctypes.py [秒數] [程式庫路徑]`（未指定路徑時依序嘗試 `.build/release` 的 dylib 與 Unity bundle，載入失敗會換下一個）。

## 生命週期

```c
MTKConfig config;
mtk_default_config(&config);      // 一定要先呼叫：填入 struct_size 與預設值
config.vendor_id = 0x222A;        // 可選
if (mtk_start(&config) != MTK_OK) { /* 用 mtk_poll_log 看原因 */ }

MTKTouchEvent events[256];
for (;;) {                        // 例如每個遊戲幀一次
    int32_t n = mtk_poll_events(events, 256);
    for (int32_t i = 0; i < n; i++) { /* events[i] */ }
}
mtk_stop();
```

- `mtk_start` 已在執行時會先停止再重新開始。觸控螢幕晚接上也可以，接上後自動開始。
- 同一程序只有一份狀態（單例），不需要 handle。
- 也可用 `mtk_set_event_callback` 即時收到事件（在 HID 執行緒上呼叫，請盡快返回，`events` 只在回呼期間有效）。回呼與佇列同時有效。

## 函式一覽

| 函式 | 說明 | 執行緒 |
|---|---|---|
| `int32_t mtk_api_version(void)` | `MTK_API_VERSION`（目前 1）；與標頭不符代表需重新建置 | 任意 |
| `const char *mtk_version(void)` | 程式庫版本字串（例如 `0.1.0`），不需釋放 | 任意 |
| `void mtk_default_config(MTKConfig *)` | 填入預設設定 | 任意 |
| `int32_t mtk_start(const MTKConfig *)` | 開始偵測與讀取；`NULL` = 預設設定 | 任意（不要在回呼內） |
| `void mtk_stop(void)` | 停止並釋放裝置；仍在螢幕上的觸點以 cancelled 放入佇列 | 任意（不要在回呼內） |
| `int32_t mtk_is_running(void)` | 1 = 執行中 | 任意 |
| `int32_t mtk_poll_events(MTKTouchEvent *, int32_t cap)` | 依時間順序取出事件，回傳數量 | 任意 |
| `uint64_t mtk_dropped_event_count(void)` | 佇列滿而丟棄的事件總數 | 任意 |
| `void mtk_set_event_callback(cb, user_data)` | 即時回呼；`NULL` 取消 | 任意 |
| `int32_t mtk_device_count(void)` | 已開啟的裝置數 | 任意 |
| `int32_t mtk_get_device_info(int32_t index, MTKDeviceInfo *)` | 第 index 台裝置資訊 | 任意 |
| `int32_t mtk_poll_log(char *buf, int32_t cap)` | 取出一則 UTF-8 診斷訊息，回傳位元組數；0 = 沒有 | 任意 |
| `uint64_t mtk_now_ns(void)` | 與 `timestamp_ns` 相同時基的現在時間 | 任意 |
| `int32_t mtk_set_display(const char *selector)` | 選擇觸控螢幕所在的顯示器（見下節） | 任意 |
| `uint32_t mtk_touch_display_id(void)` | 目前選到的 `CGDirectDisplayID`，0 = 找不到 | **主執行緒** |
| `int32_t mtk_map_to_window(x, y, display_id, *out_x, *out_y)` | 正規化座標 → 本程序 key window 內容區像素（原點左下） | **主執行緒** |

回傳碼：`MTK_OK` 0、`MTK_ERR_INVALID_ARGUMENT` -1、`MTK_ERR_START_FAILED` -2、`MTK_ERR_NOT_RUNNING` -3、`MTK_ERR_OUT_OF_RANGE` -4、`MTK_ERR_NO_WINDOW` -5。

## 結構

所有欄位依自然對齊排列，大小固定（標頭與各語言綁定都會檢查）。

`MTKConfig`（32 bytes）：`struct_size`、`vendor_id`／`product_id`（0 = 不限）、`exclusive`（1 = 獨占，預設）、`init_multitouch`（1 = 依 Windows 流程初始化多點模式，預設；ILITEK 必須）、`report_stationary`（0 = 佇列不放 stationary，預設）、`queue_capacity`（0 = 4096，滿了丟最舊的）、`reserved`。

`MTKTouchEvent`（56 bytes）：

| 欄位 | 型別 | 說明 |
|---|---|---|
| `touch_id` | u64 | 每次觸碰唯一，從 1 開始；追蹤手指請用它 |
| `timestamp_ns` | u64 | 收到 HID 報告的時間（`mtk_now_ns` 時基） |
| `device_id` | i32 | 裝置編號 |
| `contact_id` | i32 | 控制器 Contact Identifier，放開後會重複使用 |
| `phase` | i32 | `MTK_PHASE_BEGAN` 0、`MOVED` 1、`STATIONARY` 2、`ENDED` 3、`CANCELLED` 4 |
| `x`, `y` | f32 | 0...1，原點在面板左上角 |
| `pressure`, `width`, `height` | f32 | 不支援時為 -1（ILITEK 不支援） |
| `frame_seq` | u32 | 同一個掃描 frame 的事件數值相同 |
| `flags` | u32 | `MTK_FLAG_HAS_PRESSURE` 1、`HAS_SIZE` 2、`HAS_CONFIDENCE` 4、`LOW_CONFIDENCE` 8 |

`MTKDeviceInfo`（160 bytes）：`device_id`、`vendor_id`、`product_id`、`max_contacts`、`slots_per_report`、`exclusive`、`physical_width_mm`／`physical_height_mm`（未知為 0）、`manufacturer[64]`、`product[64]`（UTF-8、以 0 結尾）。

## 顯示器對應

觸控座標是面板的正規化值；要換算成螢幕位置，必須知道觸控螢幕是哪一台顯示器。系統中可能有多台同名顯示器（例如兩台「Sculptor」），而且觸控螢幕通常不是主螢幕，所以不要假設 `CGMainDisplayID()`。

`mtk_set_display(selector)` 的文字格式（以逗號串接多個條件，全部符合才算）：

| 條件 | 說明 |
|---|---|
| `auto` | 預設。依觸控面板的實體尺寸（HID 描述子）挑選尺寸最接近的顯示器（長短邊都在 ±30% 內）。沒有符合、還沒有觸控裝置、或裝置沒有回報尺寸時用主螢幕，log 會寫明原因。模擬來源的面板尺寸與 MF156LR 相同 |
| `main` | 主螢幕 |
| `id:2` 或 `2` | `CGDirectDisplayID`（重新接線或重開機後可能改變） |
| `uuid:2B0DA454-…` | 顯示器 UUID |
| `edid:6474:aa15[:序號]` | EDID 廠商:型號（16 進位）[:序號]，**最可靠** |
| `name:Sculptor` | 系統名稱包含（不分大小寫）。同名顯示器 macOS 會加上「(1)」「(2)」，但編號不保證固定 |
| `size:1920x1080` | 目前解析度（像素） |
| `hz:60` | 更新率 |

`NULL` 或 `""` 代表使用環境變數 `MTK_DISPLAY`，未設定時為 `auto`。符合多台時取第一台非主螢幕並在 log 中提示。結果會快取，顯示器設定改變（接線、解析度、排列）或觸控裝置改變時自動重新選擇。

`mtk_map_to_window` 的 `display_id = 0` 使用這裡選到的顯示器；非 0 則直接使用該 `CGDirectDisplayID`。

本專案開發機的實例（2026-10-28，`mtk-server --list-displays`）：

```
id=3「SONY TV」1920x1080@60Hz edid=4dd9:f301:16843009 1626x914mm 主螢幕
id=1「Sculptor (2)」1920x2160@100Hz edid=6474:a2d5:4 290x528mm
id=2「Sculptor (1)」1920x1080@60Hz edid=6474:aa15:0 351x200mm   ← MF156LR（觸控面板 309x174mm，auto 會選到）
```

MF156LR 可用 `edid:6474:aa15` 或 `name:Sculptor,size:1920x1080` 指定。

## ABI 相容規則

- 結構欄位只能附加在尾端，不可重排或刪除；`mtk_start` 會檢查 `struct_size`。
- 改結構時要同步更新 `MTK_API_VERSION`、`Unity/.../MultiTouchKitNative.cs`、`Examples/python/native_ctypes.py` 與本文件。
- 新增函式不改 `MTK_API_VERSION`；舊的 bundle 缺少新函式時，呼叫端會得到找不到符號的錯誤（Unity 為 `EntryPointNotFoundException`）。
- 原生程式碼改動後要執行 `scripts/build-unity-plugin.sh` 並 commit 產出的 bundle。

## 權限

獨占 HID 裝置時 macOS 可能要求「輸入監控」權限，授權對象是載入程式庫的 App（終端機、Unity Editor、你的遊戲）。開啟失敗時 log 會出現 `0xe00002e2`（not permitted）。
