# ILITEK 廠商通道調查（V1：步驟 1 解析、步驟 2 查資料）

調查日期：2026-10-30。對象：Sculptor MF156LR 的觸控控制器 ILITEK-TP（VID `0x222A`／PID `0x0001`，bcdDevice 2，USB Full Speed，無序號）。

**本次只用被動資訊，沒有對裝置送出任何 report，也沒有開啟或獨占裝置。**資料來源：

- `ioreg`（`IOUSBHostInterface` 節點上的 `ReportDescriptor` 與 `Max*ReportSize`）
- `docs/hardware/mf156lr-raw.txt`
- `~/ilitek-probe.csv`
- 下文列出的公開資料

結論先講：

1. 面板有一條標準的 ILITEK 指令通道：**介面 1 上的 report ID 3**（vendor page `0xFF00`、usage `0x01`，Input 與 Output 各 63 bytes）。它的結構與 ILITEK 官方程式設計手冊的「USB 協定標頭」完全吻合，封包格式是 `03 A3 <寫入長度> <回傳長度> <指令> …`。
2. 觸控介面上那個 256 bytes 的 vendor feature（report ID 6，usage `0xFF00:0xC5`）**不是 ILITEK 私有通道**，而是 Microsoft 的觸控認證資料區塊（THQA／PTPHQA blob）。同一個 report 的第 1 個 byte 是 Contact Count Maximum（10）。
3. 指令的實際語意（尤其韌體是 V3 還是 V6 協定）只能從公開文件推論，要等步驟 3 才能確認。

---

## 步驟 1：HID 描述子解析

### USB 介面配置

| USB 介面 | 端點 | HID 主要用途 | 描述子長度 | MaxInput／Output／Feature |
|---|---|---|---|---|
| 0 | 1 個（interrupt IN） | Digitizer／Touch Screen（`0x0D:0x04`） | 743 bytes | 64／1／258 |
| 1 | 1 個（interrupt IN） | Generic Desktop／Mouse（`0x01:0x02`），另含 vendor 集合 | 107 bytes | 64／64／1 |

- 兩個介面都只有一個 interrupt IN 端點，沒有 interrupt OUT。所以所有 Output 與 Feature report 都必須走 EP0 控制傳輸（HID `SET_REPORT`）。
- 「MaxOutputReportSize = 1」與「MaxFeatureReportSize = 1」是 macOS 在該類型不存在時填的最小值，並不代表真的有 1 byte 的 report。

### 所有 report 一覽

| 介面 | Report ID | 方向 | 長度（含 ID） | 用途 page:usage | 內容 |
|---|---|---|---|---|---|
| 0 | `0x04` | Input | 64 | `0x0D` Digitizer | 10 組手指，每組 5 bytes：contact ID 6 bit＋tip 1 bit＋padding 1 bit、X 16 bit、Y 16 bit。接著是 Scan Time 32 bit、Contact Count 8 bit、8 bytes padding |
| 0 | `0x06` | Feature | 258 | `0x0D:0x55`＋`0xFF00:0xC5` | 第 1 byte：Contact Count Maximum（邏輯最大值 10）；後 256 bytes：Microsoft 觸控認證 blob |
| 1 | `0x05` | Input | 6 | `0x01:0x02` Mouse | 5 個按鍵 bit＋3 bit padding、X 16 bit、Y 16 bit（絕對座標）：單點滑鼠模擬，給不支援多點觸控的主機使用 |
| 1 | `0x03` | Input | 64 | `0xFF00:0x01` | **ILITEK 指令通道：回應**（63 bytes payload） |
| 1 | `0x03` | Output | 64 | `0xFF00:0x01` | **ILITEK 指令通道：指令**（63 bytes payload） |

### 觸控介面的物理參數（摘自描述子）

這些數值已被 `HIDReportDescriptor` 使用，這裡只做紀錄：

- **X**：邏輯範圍 0–9600，物理範圍 0–3093 × 10⁻² cm（30.93 cm）。
- **Y**：邏輯範圍 0–9600，物理範圍 0–1739 × 10⁻² cm（17.39 cm）。
- **Scan Time**：32 bit，沒有標示單位。實測每個 report 增加 80，間隔約 8 ms，與 Windows 慣例的 100 µs 單位一致。
- `~/ilitek-probe.csv` 共 2,900 筆，全部是 report 4。這份資料只有觸控輸入，沒有 vendor 流量。

### 與 ILITEK 官方參考描述子的對照

依據 ILI2130 等 IC 的 Programming Guide V1.50 第 8 章：

| 項目 | 官方參考設計 | 本面板 | 判斷 |
|---|---|---|---|
| 觸控 report | ID 4，每點 5 bytes × 10 點（第 4.3 節「USB=0x04」） | ID 4，相同配置 | ✅ 一致 |
| Contact Count Maximum | 獨立的 feature report ID 2 | 併入 feature report ID 6 的第 1 byte | ⚠️ 韌體客製 |
| 0xC5 認證 blob | feature report ID 6，256 bytes | 相同 | ✅ 一致 |
| vendor 指令通道 | report ID 3，63 bytes Input／Output | 相同 | ✅ 結構一致 |
| vendor 通道所在介面 | 第 7.1 節的 USB 封包紀錄：`SET_REPORT` 的 setup 為 `21 09 03 02 00 00 40 00`，`wIndex = 0`，表示在介面 0 | **介面 1**（與滑鼠模擬同介面） | ⚠️ 不同，送指令時必須指向介面 1 |
| 滑鼠模擬 | 選用的介面 1 | 介面 1，report ID 5 | ✅ 概念一致，ID 不同 |
| 長指令 report（ID 8，fwupd 使用） | — | **不存在** | 長指令（1 KB 寫入）不適用 |

### 驅動目前對裝置做了什麼（供對照）

MultiTouchKit 本身在初始化時（`TouchDevice.initializeMultiTouchMode`）會讀取最大觸點數：在**觸控介面 0**對 **feature report 6** 做一次 `GetReport`。這是 Windows 列舉流程中的標準讀取，回傳內容包含上述 256 bytes 的認證 blob。

- 本面板沒有 Device Mode（`0x0D:0x52`）feature，所以驅動**不會**送出任何 `SetReport`。
- 驅動從未碰過介面 1 的 report 3。

---

## 步驟 2：公開資料中的 ILITEK 協定

### 資料來源與可信度

| 代號 | 來源 | 內容 | 可信度 |
|---|---|---|---|
| **G** | ILI TECHNOLOGY CORP.《ILITek TP Programming Guide》V1.50（2020），適用 ILI2520/2521/2322/2323/2316/2326/2130/2131/2132。由經銷商公開放置：<https://www.lcd-module.de/eng/pdf/zubehoer/ILI2130_Programming_Guide_V1_50.pdf> | USB 標頭、完整指令表、USB 封包紀錄、參考描述子 | **高**（原廠文件）。但文件頁尾標示「ILI Confidential Disclosed Under NDA」，本文只摘要事實、不轉載全文。本面板 IC 型號未知，所以套用到本面板只算「中」 |
| **L** | Linux kernel `drivers/input/touchscreen/ilitek_ts_i2c.c`（GPL-2.0，作者為 ILITEK 員工）：<https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/input/touchscreen/ilitek_ts_i2c.c> | I2C 版的指令碼與回應格式（23XX、25XX、Lego 系列） | **高**（上游主線）。但只涵蓋 I2C，USB 要套用 G 的標頭 |
| **F** | fwupd 2.1.3 `plugins/ilitek-its`（LGPL-2.1+，2025 年由 ILITEK 員工撰寫）：<https://github.com/fwupd/fwupd/tree/2.1.3/plugins/ilitek-its>，說明頁 <https://fwupd.github.io/libfwupdplugin/ilitek-its-README.html> | V6 協定的新指令、韌體更新流程；以 **feature** report 送出 report 3 | **高**（原廠維護）。但目標是 I2C-HID 與新款 USB 裝置，report 3 的類型與本面板不同（本面板是 Output） |
| **C** | ChromiumOS `touch_updater` 的 `chromeos-ili-its-touch-firmware-update-legacy.sh`：<https://chromium.googlesource.com/chromiumos/platform/touch_updater/+/refs/heads/release-R139-16328.B/scripts/chromeos-ili-its-touch-firmware-update-legacy.sh> | 原廠工具 `ilitek_ld` 的用法（`PanelInfor`、`FWID`、`Chrome`、`FWUpgrade`），以及協定版本與 V3／V6 的對應 | **中**（只有呼叫方式，沒有封包細節） |
| **M** | Microsoft〈Windows Precision Touchpad collection〉的 Device Certification Status 說明：<https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchpad-windows-precision-touchpad-collection> | `0xFF00:0xC5` 是 256 bytes 的認證 blob | **高** |

### USB HID 封裝格式（G §5.2、§5.3；F 的結構定義相同）

指令從主機送到裝置，是 Output report 3，經 EP0 控制傳輸 `SET_REPORT`：

```
byte 0   Report ID      0x03
byte 1   Header         0xA3
byte 2   Write_Length   指令本身的長度（含指令碼）
byte 3   Return_Length  期望回傳的資料長度（不含 4 bytes 標頭）
byte 4   CMD            指令碼
byte 5…  參數，其餘補 0，總長 64 bytes
```

回應從裝置送到主機，是 Input report 3，經 interrupt IN：

```
byte 0   0x03
byte 1   0xA3
byte 2   指令碼（回顯，用來比對）
byte 3   回傳長度
byte 4…  資料
```

- I2C 版本就是把前 4 bytes 拿掉，從指令碼開始（G、L）。
- F 的做法：送出後先等 100 ms，再以 200 ms 逾時讀取，最多重試 50 次，並比對回顯的指令碼。
- F 另外定義了「長指令」report ID `0x08`：寫入／回傳長度各 2 bytes，資料 1024 bytes，用於韌體寫入。**本面板沒有 report 8。**

### 指令表與風險分級

各欄來源以代號標示。「本面板」欄的意思：

- ✅：封包格式可對應到本面板的 report 3。
- ❓：語意需要步驟 3 才能確認。

#### A. 唯讀查詢（只回傳資料，依文件不改變狀態）

| 指令 | 名稱 | 送出（含 USB 標頭） | 回傳 | 來源 | 本面板 |
|---|---|---|---|---|---|
| `0x40` | Get_Firmware_Version | `03 A3 01 08 40` | 8 bytes：G 的格式是 chip ID、韌體版本 X.X.X、客戶韌體版本 X.X.X.X；F 讀成 64 bit 大端序 | G、L、F | ✅ 格式可對應；三個來源都有，碼值一致 ❓ |
| `0x61` | Get_Kernel_Version（L 稱 GET_MCU_VER） | `03 A3 01 20 61` | 32 bytes：IC 名稱（2 bytes LE，例如 `0x2521`）、flash 資訊、模組名稱 ASCII（G 的範例是 `ILI2521001215A00`） | G、L、F | ✅／❓。可得知 IC 型號，最有資訊量 |
| `0x20` | Get_Panel_Information（G）／GET_TP_RES（L） | `03 A3 01 0F 20` | 15 bytes：X/Y 最大值、Rx/Tx 通道數、觸點數… | G、L | ✅／❓。G 與 L 的欄位略有差異 |
| `0x42` | Get_Protocol_Version | `03 A3 01 03 42` | 3 bytes（大端序），例如 `06 00 07` | L、F（**G 沒有**） | ❓。V3 韌體可能不支援 |
| `0x21` | Get_Screen_Resolution | `03 A3 01 08 21` | 8 bytes：min/max X/Y | L | ❓ |
| `0xC0` | Get_Mode_Check／GET_IC_MODE | `03 A3 01 01 C0` | G 為 1 byte、L 與 F 讀 2 bytes；第 1 byte 為 `0x5A` 表示 AP（正常）模式、`0x55` 表示 BL（bootloader）模式（G §7.1 的封包紀錄） | G、L、F | ✅／❓ |
| `0x80` | Get_System_Status | `03 A3 01 01 80` | 1 byte：忙碌狀態 | G | ❓ |
| `0x46` | Get_Firmware_ID | `03 A3 01 04 46` | customer ID＋FWID（各 2 bytes LE） | F（協定版本需 ≥ 6.0.7 或 ≥ 1.8.2） | ❓ |
| `0x62` | Get_MCU_Info | `03 A3 01 20 62` | IC 名稱、模組名稱 | F（協定版本需 ≥ 6.0.9 或 ≥ 1.8.3） | ❓ |
| `0x27` | Get_Sensor_ID | `03 A3 01 04 27` | `5A A5`＋sensor ID | F（協定版本需 ≥ 6.0.4 或 ≥ 1.8.3） | ❓ |
| `0xC7`／`0xCD` | Get_AP_CRC／Get_Block_CRC | — | CRC | G、F | ⚠️ 雖是讀取，但 `0xCD` 要先下參數觸發計算（G §7.1），屬於韌體更新流程的一部分，**歸到 C 級** |

#### B. 狀態控制（改變運作狀態，可回復，但會影響觸控）

| 指令 | 名稱 | 效果 | 來源 | 風險 |
|---|---|---|---|---|
| `0x30` | Set_Sleep | IC 進入睡眠，觸控停止 | G、L | 觸控失效，需要 `0x31` 或重新上電 |
| `0x31` | Set_Wakeup | 喚醒 | G、L | 低 |
| `0xF0` | Mode_Control | 參數 1：0 正常、1 測試、2 除錯、3 暫停（suspend）。參數 2：Engineer Mode（觸控資料改從 report 3／4 輸出） | G、F | **中**：會改變觸控 report 的輸出方式，可能讓 macOS 與本驅動收不到觸控。F 在任何查詢前都會先切到 suspend，結束後再切回 normal |
| `0x60` | Reset | 整顆晶片重置 | G | 中：USB 可能重新列舉，觸控短暫中斷 |
| `0xF1`／`0xF2` | Set_CDC_Initial／Get_CDC_Data | 讀取感測器原始電容資料（測試模式） | G | 中：需要先進測試模式 |

#### C. 寫入、校正、韌體更新（高風險，可能讓面板變磚）

| 指令 | 名稱 | 效果 | 來源 |
|---|---|---|---|
| `0xC1` | Set_AP_Mode | 從 bootloader 切回應用程式 | G、F |
| `0xC2` | Set_BL_Mode | 切到 bootloader：**USB 重新列舉成另一個 PID**（F 的 quirk 例子：ILI2901 bootloader 為 `0x222A:0xFF29`），期間觸控完全失效 | G、F |
| `0xC3` | Set_ROM_Code／Write_Data | 寫入 flash | G、F |
| `0xCC` | Set_Flash_Enabled | 解鎖 flash（G §7.1 的範例參數 `5A A5`） | G、F |
| `0xCD` | Get_Block_CRC | 觸發 CRC 計算 | G、F |

**本面板禁止任何 C 級指令**：韌體檔、IC 型號、bootloader 行為都未知，一旦中斷就可能無法回復。

### 能確認與無法確認的事項

**能確認**（描述子與官方文件結構吻合）：

- report 4 就是 ILITEK 的 USB 觸控 report。
- report 6 是 Microsoft 認證 blob 加上最大觸點數。
- report 3（介面 1）是 ILITEK 的 `0xA3` 指令通道，Input 與 Output 各 63 bytes。
- 本面板沒有長指令 report 8，也沒有 feature 形式的 report 3。

**無法確認**（需要步驟 3）：

- 韌體使用 V3 還是 V6 協定，因此 `0x42`、`0x46`、`0x27`、`0x62` 是否支援仍未知。
- `0x20` 的欄位定義應採 G 還是 L。
- 指令通道的回應會不會從介面 1 的 interrupt IN 回來。G 的參考設計把通道放在介面 0，本面板在介面 1。
- 未定義的指令碼送出後，韌體會忽略、回錯誤，還是有副作用。
- IC 型號（要靠 `0x61` 回傳的名稱）。

**fwupd 的做法不能直接套用**：fwupd 以 `HIDIOCSFEATURE` 送 feature report 3，但本面板的 report 3 是 Output 類型。macOS 上應該用 `IOHIDDeviceSetReport(kIOHIDReportTypeOutput, 3, …)`，對應 USB `SET_REPORT`，setup 為 `wValue = 0x0203`、`wIndex = 1`、`wLength = 64`。

---

## 步驟 3 的建議（尚未執行，需要使用者同意）

**只送一個指令：Get_Firmware_Version（`0x40`）。**

送出的 64 bytes（Output report 3，送到 USB 介面 1 對應的 IOHIDDevice，也就是 `PrimaryUsagePage 1`／`PrimaryUsage 2`、LocationID `0x00100000` 的那個節點）：

```
03 A3 01 08 40 00 00 00  00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00
```

選它的依據：

- G、L、F 三個獨立來源都有這個指令，碼值相同，而且都定義為唯讀。
- G 附有實際的 USB 封包紀錄：送出 `03 a3 01 08 40`，收到 `03 a3 40 08` 加 8 bytes。
- 它不需要先進 suspend 或測試模式。

做法：

1. 以**非獨占**方式開啟介面 1 的 IOHIDDevice（`kIOHIDOptionsTypeNone`，不 seize），並註冊 Input report 回呼。
2. 送出上述 Output report。
3. 最多等待 500 ms，接受第一個 `03 A3 40` 開頭的回應，記錄完整 64 bytes 後立刻關閉。

不要比照 F 先送 `0xF0` 切到 suspend，那是 B 級指令。

預期結果與後續：

- **成功**：回傳 8 bytes。依 G 的格式，第 1 byte 是 chip ID，第 2–4 byte 是韌體版本 X.X.X。若成功，下一步可以再考慮 `0x61`（`03 A3 01 20 61`，得知 IC 型號），以及 `0xC0`（`03 A3 01 01 C0`，確認是 AP 模式 `0x5A`）。
- **沒有回應**：代表此面板的通道行為與文件不同。不要嘗試其他指令或其他 report ID，回報後再討論。

風險：

- 依文件，這是唯讀指令，不改變狀態。
- 剩下的風險來自「韌體與文件不一致」，屬於低機率、也無法事前排除的未知。
- 送出前應先確認觸控正常、常駐服務狀態已記錄；送出後確認觸控仍正常。
