# 換機與還原（Migration）

把 MultiTouchKit 的開發與使用環境搬到另一台 Mac（例如 Mac Mini M4 → Mac Studio M4）的步驟。
原則：**能從 GitHub 重建的不備份，只備份 GitHub 上沒有、又無法重建的本機資料**；含私鑰或個人帳號的資料不放進公開 repo。

## 1. 資料分類

| 類別 | 內容 | 位置（舊機） | 換機處理 |
|---|---|---|---|
| 原始碼與文件 | 本 repo 全部內容 | GitHub `xdxd-lab/multi_touch_kit` | 新機 `git clone` |
| 建置產物 | `.build/`、Unity `.bundle` | repo 內／`.build/` | 新機重新建置，不備份 |
| 觸控校正 | `calibration.json`（9 點校正結果） | `~/Library/Application Support/MultiTouchKit/` | 備份；螢幕擺放或使用姿勢改變時建議重新校正 |
| 實機量測原始資料 | `ilitek-probe.csv` | `~/` | 備份（硬體分析的原始依據） |
| Unity 測試專案 | `Assets`、`Packages`、`ProjectSettings` | `~/Projects/MultiTouchKitUnityTest` | 備份；`Library/` 等快取不備份，Unity 開啟時重建 |
| 常駐服務 | `MultiTouchKit Server.app`、LaunchAgent plist | `~/Library/Application Support/MultiTouchKit/`、`~/Library/LaunchAgents/` | **不備份**，新機用腳本重新安裝 |
| 簽章身分 | 「MultiTouchKit Local Signing」憑證與私鑰 | login keychain | **不備份、不上傳**，新機重新建立 |
| 系統授權 | 「輔助使用」「輸入監控」 | macOS TCC | 無法搬移，新機重新授權 |
| 協作環境（個人） | Claude Code 記憶與設定、herdr 設定、Codex 設定 | `~/.claude/`、`~/.config/herdr/`、`~/.codex/` | 不屬於本 repo；建議放私人 repo 或用 Migration Assistant 搬 |

簽章身分不搬移的原因：它只用來讓本機常駐服務在重新安裝後保有授權，新機本來就要重新授權，重建即可；匯出私鑰反而增加外洩風險。

## 2. 舊機：備份

```zsh
scripts/backup-local-state.sh            # 產生 ~/MultiTouchKit-local-state-<日期>.zip
scripts/backup-local-state.sh --list     # 只列出會收錄的檔案
```

收錄第 1 節標為「備份」的項目，並附 `MANIFEST.txt`（來源路徑、大小、SHA-256、機器與 macOS 版本）。
zip 不進 repo；可存在外接硬碟，或上傳到 GitHub 的**草稿 Release**（只有 repo 擁有者登入後看得到）。

## 3. 新機：還原

1. **工具**：安裝 Command Line Tools（`xcode-select --install`），確認 `swift --version` 為 6.x。
2. **原始碼**：
   ```zsh
   mkdir -p ~/Projects && cd ~/Projects
   git clone https://github.com/xdxd-lab/multi_touch_kit.git MultiTouchKit
   cd MultiTouchKit
   swift build && scripts/test.sh
   ```
3. **本機資料**：`scripts/restore-local-state.sh <備份 zip>`。已存在的檔案不會被覆蓋（加 `--force` 才覆蓋）。
4. **常駐服務（需要時）**：
   ```zsh
   scripts/create-signing-identity.sh      # 建立簽章身分，只需一次
   scripts/install-server-agent.sh         # 安裝並啟動 MultiTouchKit Server.app
   ```
5. **系統授權**：系統設定 → 隱私權與安全性，對「MultiTouchKit Server」（以及從終端機或 Unity 直接使用時的終端機、Unity）開啟「輸入監控」與「輔助使用」。
6. **觸控校正**：新機螢幕配置不同時執行 `mtk-viewer --calibrate`，以平常遊玩的姿勢與視角校正。
7. **Unity**：安裝 Unity Hub 與 Editor **6000.3.27f1**，開啟還原後的 `~/Projects/MultiTouchKitUnityTest`。
8. **驗證**：依 `docs/hardware/mf156lr-summary.md` 的實機驗證項目抽測（10 點落點、拔插 USB、睡眠喚醒）。

## 4. GitHub 在換機時的角色

- **repo（公開）**：唯一的原始碼與文件來源。任何工作結束前都推送，換機時就不會有遺漏。
- **草稿 Release（不公開）**：存放不適合進 repo 的檔案，例如本機資料備份 zip、技術資料備存。
- **私人 repo（建議）**：協作環境設定，例如 Claude Code 記憶、herdr 設定、AI 代理的分工說明。內容可能含個人資訊，不放進本 repo。
- **Issues／Projects（選用）**：待辦與待實機測試項目放在這裡，換機或換代理（Claude、Codex）時都能直接接手。
