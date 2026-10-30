# MultiTouchKit 程式碼審查 Q3（2026-10-30，main 71c9883 → 第 6 批）

上傳新版本前的全面整理，也為了把開發機從 Mac Mini M4 換成 Mac Studio M4：換機後要能直接 clone 建置。
範圍涵蓋整個 repo（約 1.33 萬行）：Sources（MultiTouchKit、MultiTouchKitC／CMultiTouchKit、MultiTouchKitGestures、MultiTouchKitArt、
mtk-server／mtk-viewer／mtk-probe／mtk-art）、Unity 套件的 C#、scripts、Examples、Tests。

限制（與 Q1、Q2 相同）：不改對外行為與 C ABI（結構、`MTK_API_VERSION` 不變），不新增公開名稱。不執行 install／uninstall／signing 腳本，
不動常駐 LaunchAgent、keychain、Unity Editor，不建立使用者的 calibration.json，也不對裝置送出 ILITEK 指令（只讀取被動資訊）。

分 6 批進行，每批都在獨立的 worktree 實作，由 p2 驗證，p1 審核後合併。凡是 bug 修正，都先寫出在舊程式碼上會失敗的測試，再修正。

| 批 | 分支 | commit | 內容 |
|---|---|---|---|
| 1 | q3/portable | 28c22e8 | 換機可攜性 |
| 2 | q3/core | 4e3d1e4 | Sources/MultiTouchKit |
| 3 | q3/capi-gestures | 4b4bfcc、3b4fbb7 | C API、手勢 |
| 4 | q3/tools | 9b31efb | mtk-server／viewer／probe／art |
| 5 | q3/unity | 75d9dc7 | Unity C# |
| 6 | q3/examples-tests | （本批） | 範例、本文件 |

## 發現與修正

| # | 位置 | 問題 | 修正 | 風險 |
|---|---|---|---|---|
| P1 | `MultiTouchKit.bundle`（Unity 外掛，已提交的二進位檔） | 除錯符號（N_OSO）記錄了建置機器上 .o 的絕對路徑 `/Users/<名稱>/Projects/MultiTouchKit-wt/…`：洩漏本機路徑，換機重建也會產生無意義的差異 | `build-unity-plugin.sh` 在 lipo 後 `strip -S -x`，並重建 bundle。兩種架構的匯出符號（nm）都與修正前一致，大小從 1.9 MB 降為 1.16 MB | 無（匯出符號相同、兩種架構都能載入） |
| P2 | — | 沒有防止「本機路徑、個人檔案」再次進入 repo 的檢查 | 新增 `scripts/check-portability.sh`，`test.sh` 會先執行它。檢查項目：已追蹤的檔案（`grep -a`，含二進位檔）中沒有 `/Users/<名稱>/` 與 `/home/<名稱>/`；沒有提交 xcuserdata、.DS_Store、.swiftpm、.vscode、.idea；外掛是 universal | 無 |
| P3 | `scripts/backup-local-state.sh` | `-o` 給相對路徑時，zip 會寫進暫存目錄，結束時被一起刪除（顯示「已建立」，實際上沒有檔案） | 解析選項後轉成絕對路徑（`${out:a}`） | 行為（bug 修正） |
| P4 | `scripts/restore-local-state.sh` | 還原的是 zip 中所有的檔案，不限於 MANIFEST 驗證過的那些；路徑也沒有限制在 `$HOME` 之下 | 只還原 MANIFEST 列出的檔案；路徑不在 `home/` 之下或含 `..` 時停止還原 | 行為（加強檢查） |
| C1 | `DigitizerLayout.init` | 多份 input report 的 Finger collection 數量相同時，以 `Dictionary.max` 選擇觸控報告：選到哪一份取決於每個行程隨機的雜湊種子，每次執行可能不同 | 數量相同時取 report ID 最小的。測試 `equalCandidateReportsPickLowestID` 使用 8 份候選，舊程式碼約 7/8 次會失敗 | 行為（只影響有歧義的描述元；ILITEK 只有一份） |
| C2 | `MultiTouchManager` | 重新初始化與 `reinitialized` 事件依 Dictionary 列舉順序；`stop()` 後「已被其他程式獨占」的提示不會再出現 | 依裝置編號排序；teardown 時清除提示紀錄 | 只影響 log 與事件順序 |
| G1 | `GestureController.handle` | 拖曳中觸控螢幕所在的顯示器消失時，mtk-server 會把 `displayID` 設為 nil，`handle` 直接 return，手指放開時的 mouseUp 永遠不會送出，系統一直認為左鍵按住（與 2026-10-28 的事故同類） | 手勢進行中遇到 `displayID == nil` 時，取消手勢並放開按鍵。測試 `losingDisplayReleasesButton` 在舊程式碼上每次都失敗 | 行為（bug 修正） |
| T1 | `WebSocketHub`（mtk-server） | 連線進入 `.failed` 時只從清單移除，沒有 cancel；Network.framework 不會釋放失敗的 NWConnection | `.failed` 時 cancel | 無 |
| T2 | `ServerTouchSource`（mtk-viewer `--server`） | WebSocket task 和 session 由 URLSession 的接收回呼讀取，同時主執行緒的 `stop()` 會清除它們（資料競爭） | 以 `Locked` 保護 | 無 |
| U1 | `MultiTouchKitManager.StopTransport` | 停止時剩下觸點的 Cancelled 依 Dictionary 列舉順序送出 | 依 Id 排序（與 `GetActiveTouches` 相同） | 只影響事件順序 |
| E1 | `Examples/python/ws_client.py` | 網址沒寫埠時，Host 標頭會寫成 `host:None` | 連線與 Host 使用同一個預設埠 80 | 行為（bug 修正） |
| E2 | `Examples/python/udp_receiver.py` | Ctrl+C 時印出 traceback | 攔截 KeyboardInterrupt，正常結束 | 無 |

### 註解與文件

- 補齊 `Sources/MultiTouchKit` 中缺少文件的公開 API：`TouchCalibration`（Model、係數、Sample、Point、Fit）、`TouchCalibrationStore`（Entry、Device、defaultURL）、
  `TouchCalibrationCollector`、`Touch.uncalibratedY`、`DisplaySelector.Criterion`、`DisplayLocator.resolve`；手勢的 `GestureOutput.send` 與 `GestureEvent` 各 case。
- 修正過時或錯誤的註解：
  - `multitouchkit.h`（只改註解，去除註解後與修改前完全相同）與 `MultiTouchKitNative.Config.queueCapacity`：原本寫「滿了會丟棄最舊的事件」，實際上會丟棄過時事件並重新同步。
  - `GestureRecognizer.isIdle`：註解把意思寫反了。
  - `TouchFrameJsonParser.ParsePhase`：註解引用已刪除的舊程式碼。
- `multitouchkit.h` 補上幾個函式的邊界行為：`mtk_default_config(NULL)`、`mtk_poll_log` 的截斷規則與 128 則上限、只能在主執行緒呼叫的函式在其他執行緒的回傳值。`docs/c-api.md` 已同步。
- `mtk-server --help`：`--simulate-pattern` 補上 calibration。

### 檢視後不改的部分

| 項目 | 理由 |
|---|---|
| `GestureRecognizer`（581 行）拆成 extension | 已經是每個狀態一個方法，拆開只會增加改動量與回歸風險，可讀性沒有實質改善 |
| `HIDField.value(in:)` 改成以位元組為單位讀取 | 每份報告約 1000 次位元運作（125 Hz），量不到效益 |
| `CommandLineArguments.fail` 改印到 stderr | 會改變對外行為（腳本可能依賴 stdout） |
| IOKit 回呼的 retain/release、cancel handler、Locked、佇列限定 | 逐一檢查過，擁有權與執行緒規則都已正確，也有註解說明 |
| MultiTouchKitArt | 輸出必須逐位元組重現；`generate-art.sh` 重新產生後工作區沒有變動 |
| 範例 C 程式、`native_ctypes.py`、網頁範例 | 檢查過，沒有問題 |

## 換機（Mac Mini M4 → Mac Studio M4）

- 原始碼與腳本中沒有寫死的使用者路徑。
  - 腳本一律以 `cd "$(dirname "$0")/.."` 定位 repo，使用者資料一律用 `$HOME`。
  - Unity 路徑可用 `UNITY_EDITOR` 指定，預設取 Hub 中最新的版本。
- 唯一含本機路徑的是已提交的外掛 bundle，P1 已修正；P2 可防止再次發生。
- 搬移步驟見 [docs/migration.md](../migration.md)，備份與還原腳本已修正 P3、P4。新機 clone 後執行 `scripts/test.sh`，第一步就會跑可攜性檢查。

## 量測

方法與 Q2 相同（`/usr/bin/time -l -p perl -e 'alarm 15; exec @ARGV' .build/release/mtk-server --simulate …`，每項 15 秒）。

| 設定 | user (s) | sys (s) | 合計占單核 | maxRSS |
|---|---|---|---|---|
| 輸出全開（UDP／WS／TUIO） | 0.08 | 0.13 | 1.4% | 18.9 MB |
| 輸出全關 | 0.06 | 0.06 | 0.8% | 17.9 MB |

- 與 Q2（1.1%／0.6%）相比都在量測誤差範圍內；本輪沒有效能改動。
- 這次在非互動的 shell 中執行 `leaks --atExit`，測試程序在結束時停在暫停狀態（STAT `TN`），沒有產出報告，所以沒有採用結果（已以 SIGKILL 清理）。本輪沒有改到配置或擁有權相關的程式碼，Q2 的 0 leaks 結論仍可參考；如需重新確認，請在互動式終端機執行。

## 測試

- `scripts/test.sh`：134 tests（Q3 新增 2 項：`equalCandidateReportsPickLowestID`、`losingDisplayReleasesButton`），全數通過；開頭會先執行 `check-portability.sh`。
- `scripts/test-unity-offline.sh`（Runtime 三組 define 含 `MTK_INPUT_SYSTEM`，以及 Samples~）、`scripts/test-web-example.sh`、`scripts/check-signals.sh`、
  `scripts/build-c-example.sh`（`-Werror`）：全數通過。
- 範例的實際連線：ws_client、tuio_receiver、udp_receiver 都對模擬的 mtk-server 測試過。測試時改用 17777／17778／13333 埠，不與常駐的 mtk-server 衝突。
