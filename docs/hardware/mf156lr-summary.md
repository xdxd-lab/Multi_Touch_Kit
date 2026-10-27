# MF156LR 硬體與原生驅動資訊摘要（T2）

環境：macOS 26.2（build 25C56），arm64（Apple M4）。
原始輸出：`docs/hardware/mf156lr-raw.txt`（ioreg 全文，約 713 行）。

## 觸控裝置（ILITEK-TP）
- VID/PID：`0x222A`（8746）/ `0x0001`（1），VersionNumber 2
- Manufacturer / Product：ILITEK / ILITEK-TP
- USB 速度：`Device Speed = 1`（Full Speed，12 Mbps）
- 供電：UsbPowerSinkAllocation 400 mA
- Serial Number：無（iSerialNumber = 0）
- HID：DeviceUsagePairs = Digitizer / Touch Screen（Page 13, Usage 4），PrimaryUsagePage 13，PrimaryUsage 4
- MaxInputReportSize：64；Transport：USB；LocationID：0x00100000
- 報告格式含 ReportID 4，含 Tip Switch、Contact Identifier、Contact Count、X/Y 等 Digitizer 元素

## 實際接管的驅動
- 裝置側：`AppleUserUSBHostHIDDevice`（`IOUserClass`，`CFBundleIdentifier` = `com.apple.AppleUserHIDDrivers`，DriverKit）
- 事件側：`AppleUserHIDEventDriver` / `AppleUserHIDEventService`（`CFBundleIdentifier` = `com.apple.AppleUserHIDDrivers`，`IOProviderClass` = `IOHIDInterface`，`IOUserServerName` = `com.apple.driverkit.AppleUserHIDDrivers`）
- 結論：觸控由 Apple 原生 DriverKit HID 驅動接管，未見第三方觸控驅動。
- hidutil 可見兩組 0x222A 節點（ILITEK-TP，AppleUserHIDEventService / AppleUserHIDDevice）。

## 第三方驅動 / 系統擴充
- `systemextensionsctl list`：0 extension(s)
- `kmutil showloaded`：無 hid/touch/ilitek 相關第三方 kext（僅 Apple 的 IOHIDFamily、IOHIDPowerSource、IOUSBHostHIDDevice）

## 顯示器（system_profiler SPDisplaysDataType）
- `SONY TV`：1920×1080 @ 60 Hz，Main Display，Television
- `Sculptor`：1920×2160 @ 100 Hz
- `Sculptor`：1920×1080 @ 60 Hz
- 注意：輸出中**沒有名為 MF156LR 的顯示器**，無法僅憑此輸出確認哪一個是 MF156LR；需人工對照（例如實體連接或顯示器設定）。
- 連接方式未在 SPDisplaysDataType 中明示。

## USB 樹（SPUSBDataType）
- `system_profiler SPUSBDataType` 本次輸出為空，改用 `ioreg -p IOUSB` 取得資料；ILITEK-TP 位於 USB 樹中，其上層 hub/端口的位置未另行確認。

## 待確認
- MF156LR 對應哪一個顯示器節點（見上）。
- 上層 hub 與端口位置（ILITEK-TP 的 parent 未完整追溯）。

## 顯示器對應（使用者確認，2026-10-28）

- MF156LR = 系統名稱「Sculptor」、1920×1080 @ 60Hz 的那台（非主螢幕）。
- 另一台「Sculptor」1920×2160 @ 100Hz 不是 MF156LR；系統中只有一個 ILITEK 觸控裝置。
- 主螢幕為 SONY TV 1920×1080 @ 60Hz。觸控座標必須對應到 MF156LR，不能預設用 `CGMainDisplayID()`。

## 實機驗證紀錄

- 2026-10-28 觸控落點（`mtk-viewer`，`--display` 未指定，auto 選到 id=2 Sculptor `6474:aa15`）：四角與中央落點準確，沒有圓點出現在其他螢幕，10 點同時顯示正常。使用者特別肯定 viewer 的觸控視覺特效，後續的 App／遊戲應沿用此效果。
- 2026-10-28 Unity 6000.3.27f1（測試專案 MultiTouchKitUnityTest，Touch Visualizer，編輯器內 Play Maximized）：10 點正常。D4 修正後重測：滑鼠線誤觸幾乎不再產生持續觸點；Unity 失焦（點主螢幕）不再凍結或殘留觸點；單指長按不會被誤取消。已知：編輯器 Game 視窗內水平位置與手指略有偏差（Game 視窗非全螢幕所致，待以獨立 App 全螢幕驗證）。
- 2026-10-28 Unity Latency Calibration（32 次樣本中位數）：建議判定偏移約 **+16.2 ms**（正值 = 點擊比節拍晚；含觸控延遲＋音訊輸出延遲＋個人習慣），連續 Perfect。遊戲的預設判定偏移以此為起點，並保留玩家自行校正。
