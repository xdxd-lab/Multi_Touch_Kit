import ApplicationServices
import Foundation
import IOKit.hid

/// mtk-server 需要的兩項系統授權：
/// - 輸入監控（ListenEvent）：讀取 HID 報告。實測 ILITEK 的觸控介面沒有這項授權也能開啟，但一併獨占的滑鼠相容介面需要它。
/// - 輔助使用：`--gestures` 合成滑鼠、捲動、鍵盤事件。
///
/// 授權的對象是「責任程序」：由 LaunchAgent（launchd）啟動時是 mtk-server 本身（安裝為 MultiTouchKit Server.app，
/// 清單中顯示這個名稱）；從終端機啟動時是終端機 App。
///
/// 授權在同一個程序內不會生效（2026-10 實機確認）：使用者打開開關後，原本的程序中 IOHIDCheckAccess 仍回報未授權，
/// 滑鼠介面也仍無法獨占；重新啟動的程序則立即正常。所以改由新的子程序檢查（`--check-permissions`），
/// 發現新授權時由 LaunchAgent 重新啟動整個程序（見 ServerRuntime）。
enum Permissions {
    /// 子程序檢查授權用的隱藏選項（不列在 --help）
    static let checkOption = "--check-permissions"

    static var hasInputMonitoring: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    /// 尚未授權時請求：系統把程式加入「輸入監控」清單（開關預設關閉），第一次會跳出詢問。回傳目前是否已授權
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        hasInputMonitoring || IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// `--check-permissions` 的輸出（子程序）
    static var report: String { "input-monitoring=\(hasInputMonitoring ? 1 : 0) accessibility=\(hasAccessibility ? 1 : 0)" }

    /// 以新的子程序（同一個執行檔、同一個責任程序）檢查目前的授權；失敗時回傳 nil
    static func checkInFreshProcess() -> (inputMonitoring: Bool, accessibility: Bool)? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = [checkOption]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // 不可繼承 XPC_SERVICE_NAME：launchd 只為 job 本身設定它，子程序帶著它啟動時，系統框架會認定自己是 XPC 服務而中止（SIGTRAP）
        var environment = ProcessInfo.processInfo.environment
        environment["XPC_SERVICE_NAME"] = nil
        process.environment = environment
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, output.contains("input-monitoring=") else { return nil }
        return (output.contains("input-monitoring=1"), output.contains("accessibility=1"))
    }

    /// 由 launchd（LaunchAgent）啟動：launchd 會設定 XPC_SERVICE_NAME 為 job 的 label
    static var launchedByLaunchd: Bool {
        guard let name = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] else { return false }
        return !name.isEmpty && name != "0"
    }
}

/// 啟動時缺少授權的話，每 3 秒以子程序檢查；使用者打開開關後通知（`onGranted`）。
/// 在自己的佇列上執行：子程序需要數十毫秒，不能阻塞觸控的佇列。
final class PermissionWatcher: @unchecked Sendable {
    struct Granted: Sendable {
        var inputMonitoring: Bool
        var accessibility: Bool
    }

    private let queue = DispatchQueue(label: "MultiTouchKit.permissions", qos: .utility)
    private let needsAccessibility: Bool
    private let onGranted: @Sendable (Granted) -> Void
    private var timer: DispatchSourceTimer?
    /// 只供測試：環境變數 MTK_TEST_SIMULATE_GRANT 讓啟動時的狀態視為未授權，且第一次子程序檢查成功就視為「使用者打開了開關」。
    /// 用來驗證子程序檢查、launchd 偵測、收尾與 KeepAlive 重新啟動的流程（不需要切換系統授權，也可搭配 --simulate）
    static let simulateGrant = ProcessInfo.processInfo.environment["MTK_TEST_SIMULATE_GRANT"] != nil
    private let inputMonitoring = !simulateGrant && Permissions.hasInputMonitoring
    private let accessibility = !simulateGrant && Permissions.hasAccessibility

    /// - Parameters:
    ///   - needsAccessibility: 使用 `--gestures`（不是 dry-run）時為 true
    ///   - onGranted: 缺少的授權之中有新取得的（在 watcher 的佇列上呼叫；只呼叫一次）
    init(needsAccessibility: Bool, onGranted: @escaping @Sendable (Granted) -> Void) {
        self.needsAccessibility = needsAccessibility
        self.onGranted = onGranted
    }

    private var isComplete: Bool { inputMonitoring && (accessibility || !needsAccessibility) }

    /// 印出目前狀態；有缺少的授權時開始檢查
    func start() {
        if !inputMonitoring {
            print("授權：尚未取得「輸入監控」（觸控螢幕的滑鼠相容介面無法一併獨占）。請到 系統設定 → 隱私權與安全性 → 輸入監控，打開「\(Self.clientName)」的開關")
        }
        if needsAccessibility && !accessibility {
            print("授權：尚未取得「輔助使用」，合成的事件會被系統丟棄。請到 系統設定 → 隱私權與安全性 → 輔助使用，打開「\(Self.clientName)」的開關")
        }
        guard !isComplete else { return }
        print(Permissions.launchedByLaunchd
              ? "授權：打開開關後幾秒內會自動重新啟動 mtk-server 以套用授權"
              : "授權：打開開關後請重新啟動 mtk-server（從終端機執行時授權對象是終端機 App）")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.check() }
        self.timer = timer
        timer.resume()
    }

    private func check() {
        guard var fresh = Permissions.checkInFreshProcess() else { return }
        if Self.simulateGrant { fresh = (true, true) }
        let granted = Granted(inputMonitoring: !inputMonitoring && fresh.inputMonitoring,
                              accessibility: needsAccessibility && !accessibility && fresh.accessibility)
        guard granted.inputMonitoring || granted.accessibility else { return }
        timer?.cancel()
        timer = nil
        onGranted(granted)
    }

    /// 清單中顯示的名稱：LaunchAgent 安裝版是 app 名稱，從終端機啟動時是終端機
    private static var clientName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String { return name }
        return ProcessInfo.processInfo.environment["TERM_PROGRAM"].map { "\($0)（從終端機啟動時授權對象是終端機）" } ?? "執行 mtk-server 的 App"
    }
}
