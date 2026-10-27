# MultiTouchKit 前期分析（2026-10-28）

Sculptor（雕塑家）MF156LR 可攜式螢幕的 macOS 10 點觸控驅動程式。本文件整理先前的 Survey 與階段性成果，作為後續開發與交接（Claude／ChatGPT Codex）的起點。

## 1. 問題與硬體 Survey

- 症狀：macOS 26.2（Apple Silicon, M4）上觸控有效但只有 1 點。
- 觸控晶片：ILITEK-TP，VID `0x222A`／PID `0x0001`，標準 HID 多點觸控（Digitizer）裝置，另有一組滑鼠介面。
- HID 描述子：每份報告 10 個觸點槽位（Contact ID、Tip Switch、X、Y），附 Contact Count；Contact Count Maximum = 10。
- 原因：macOS 內建 `AppleUserHIDEventDriver` 只把觸控螢幕當單點滑鼠，系統內無第三方觸控驅動。
- 關鍵發現：**面板必須先被讀取 Contact Count Maximum feature，才會改送多點格式報告**（第一次量測收不到資料的原因）。

## 2. 方案評估與決策

| 方案 | 結論 |
|---|---|
| 商用 UPDD（Touch-Base） | 付費、未明確支援 macOS 26；多指僅轉成觸控板手勢。不採用。 |
| 逆向 UPDD | 違反授權條款，不做。 |
| DriverKit 核心驅動 | 需 Apple 特殊權限或關閉 SIP，且系統不會把非 Apple 觸點轉成手勢。不採用。 |
| **使用者空間常駐程式（IOHIDManager 獨占裝置）** | **採用**。不需 Xcode、SIP、開發者帳號；Command Line Tools（Swift 6.3）即可。 |

macOS 限制：App 拿不到觸控螢幕觸點，觸控板觸點也無法偽造。因此一般 App 只能透過「手勢合成」使用多點；10 個獨立觸點只能透過本專案的 API／網路協定取得。

## 3. 實機量測（ilitek-probe，原始資料 `~/ilitek-probe.csv`）

| 項目 | 結果 |
|---|---|
| 回報率 | 約 125 Hz（中位數 8.01 ms，p99 12.04 ms），1 指與 10 指相同 |
| 資料中斷 | 0 / 2799 個間隔 |
| 最多同時觸點 | 10 |
| 連打 | 1 秒內最多 58 次按下；兩次按下最短間隔 6.9 ms |
| 最短點擊 | 15 ms |
| 獨占時游標移動 | 0 次（成功擋掉系統單點游標） |
| 未量測 | 手指觸碰到收到資料的固定延遲（需慢動作錄影；遊戲內以判定偏移校正） |

結論：足以支撐太鼓達人類／多點敲擊節奏遊戲。判定須用觸控時間戳而非畫面幀時間；音效收到觸控即播放；使用有線音訊。

## 4. 開發方向與優先順序（使用者決策：全部都要做）

使用者目標：自行開發多點敲擊類音樂節奏遊戲，遊戲引擎傾向 Unity（3D）。

1. **Swift 觸控核心**：自動偵測、插拔與睡眠喚醒恢復、切多點模式並獨占、解析 10 點、手指追蹤、精確時間戳、座標換算到螢幕。
2. **三種呼叫方式**（都收錄在本專案並附使用說明）：
   - Swift Package（同程序，最低延遲）
   - C ABI + Unity `.bundle` 原生外掛（亦供 C/C++、Python、Godot、Rust）
   - 常駐程式 `mtk-server` + 本機網路廣播（UDP JSON、WebSocket、TUIO 1.1）
3. **Unity 套件**：C# 包裝、Native／UDP 傳輸、Input System 虛擬觸控螢幕、範例場景（觸點視覺化、延遲校正）。
4. **遊戲開發**（Unity）。
5. **系統層手勢合成**（點擊、拖曳、雙指捲動、縮放、旋轉、多指滑動）：優先度低，但是一般 App 使用多點的唯一途徑。

限制：同一時間只能有一個程序獨占觸控螢幕；多個程式同時使用時須透過 `mtk-server` 分送。

## 5. 階段性成果（2026-10-25，已 commit 為 `main` 基線）

| 項目 | 狀態 |
|---|---|
| `MultiTouchKit` Swift 核心（HID 描述子解析、Max Contacts feature、獨占含兄弟介面、熱插拔、睡眠喚醒、時鐘與座標換算） | 完成，`swift build` 通過、無警告 |
| 單元測試（以實機擷取資料為 fixture） | 13 項通過（需用 `scripts/test.sh`，直接 `swift test` 會找不到 Testing 模組） |
| `MultiTouchKitC` C ABI（14 個匯出函式）＋ `Examples/c/basic.c` | 完成，實機驗證：抓到裝置、獨占兩介面、讀到最大觸點數 10、struct 大小與標頭一致 |
| `mtk-server`（UDP／WebSocket／TUIO）、`mtk-probe`、`mtk-viewer` | 完成；模擬觸控下 3 秒 376 frame、8.00 ms 間隔，三種輸出一致 |
| LaunchAgent 安裝／移除腳本 | 2026-10-28 以 `--simulate` 驗證安裝、launchd 執行中、UDP 收到資料、移除乾淨；實機觸控常駐待使用者確認「輸入監控」權限 |
| Python（UDP／WS／TUIO／ctypes）與網頁範例 | Python 四個範例 2026-10-28 驗證通過（UDP／WS／TUIO 搭配 `--simulate`；ctypes 開啟實機）；網頁範例未在瀏覽器驗證 |
| Unity 套件 `com.xdxd-lab.multitouchkit` 與 universal `.bundle`（arm64＋x86_64） | 已寫並建置；**本機尚未安裝 Unity，未在 Unity 內驗證** |
| Python ctypes 載入 `.bundle` 驗證 | 2026-10-28 通過：arm64 與 x86_64（Rosetta）都能載入、獨占 ILITEK、讀到最大觸點數 10。前次中斷原因：`build-unity-plugin.sh` 最後以 x86_64 建置，`.build/release` 被指向 x86_64，ctypes 預設載入失敗（已修正） |
| README／`docs/` 使用說明 | 2026-10-28 完成：README、`docs/swift-package.md`、`c-api.md`、`server-protocol.md`、`unity.md` |
| 觸控螢幕對應顯示器 | 2026-10-28 新增 `DisplaySelector`／`DisplayLocator`（auto 依面板實體尺寸、EDID、名稱＋解析度等），C API `mtk_set_display`、`--display`、Unity `displaySelector`；實機 auto 正確選到 MF156LR（EDID `6474:aa15`），未經實際觸碰確認位置 |
| 系統層手勢合成 | 未開始 |

## 6. 待辦與分工

- p1（專案管理）：GitHub 推送、命名（目錄與產品名 `MultiTouchKit`，repo `xdxd-lab/multi_touch_kit`）、派工。
- p3（核心開發）：補完第 5 節未完成項目與後續開發；技術決策、編譯與反組譯參考資料。
- p2（測試）：建置、單元測試、範例與輸出驗證。
- 使用者：實機觸控測試、安裝 Unity Hub＋LTS、授予「輸入監控」與「輔助使用」權限。
