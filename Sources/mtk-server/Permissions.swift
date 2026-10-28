import ApplicationServices
import Foundation
import IOKit.hid

/// mtk-server 需要的兩項系統授權：
/// - 輸入監控（ListenEvent）：讀取觸控螢幕的 HID 報告。
/// - 輔助使用：`--gestures` 合成滑鼠、捲動、鍵盤事件。
///
/// 授權的對象是「責任程序」：由 LaunchAgent（launchd）啟動時是 mtk-server 本身（安裝為 MultiTouchKit Server.app，
/// 清單中顯示這個名稱）；從終端機啟動時是終端機 App。
enum Permissions {
    static var hasInputMonitoring: Bool { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }

    /// 尚未授權時請求：系統把程式加入「輸入監控」清單（開關預設關閉），第一次會跳出詢問。回傳目前是否已授權
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        hasInputMonitoring || IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }
}

/// 啟動時缺少授權的話，定期檢查：使用者在系統設定打開開關後立即生效，不必重新啟動 mtk-server。
final class PermissionWatcher {
    private let queue: DispatchQueue
    private let needsAccessibility: Bool
    private let onInputMonitoringGranted: () -> Void
    private var timer: DispatchSourceTimer?
    private var inputMonitoring = Permissions.hasInputMonitoring
    private var accessibility = Permissions.hasAccessibility

    /// - Parameters:
    ///   - needsAccessibility: 使用 `--gestures`（不是 dry-run）時為 true
    ///   - onInputMonitoringGranted: 在 `queue` 上呼叫；應重新開啟觸控裝置（授權前的開啟已失敗）
    init(queue: DispatchQueue, needsAccessibility: Bool, onInputMonitoringGranted: @escaping () -> Void) {
        self.queue = queue
        self.needsAccessibility = needsAccessibility
        self.onInputMonitoringGranted = onInputMonitoringGranted
    }

    var isComplete: Bool { inputMonitoring && (accessibility || !needsAccessibility) }

    /// 印出目前狀態；有缺少的授權時開始每 2 秒檢查
    func start() {
        if !inputMonitoring {
            print("授權：尚未取得「輸入監控」。請到 系統設定 → 隱私權與安全性 → 輸入監控，打開「\(Self.clientName)」的開關（打開後自動生效）")
        }
        if needsAccessibility && !accessibility {
            print("授權：尚未取得「輔助使用」，合成的事件會被系統丟棄。請到 系統設定 → 隱私權與安全性 → 輔助使用，打開「\(Self.clientName)」的開關（打開後自動生效）")
        }
        guard !isComplete else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.check() }
        self.timer = timer
        timer.resume()
    }

    private func check() {
        if !inputMonitoring && Permissions.hasInputMonitoring {
            inputMonitoring = true
            print("授權：已取得「輸入監控」")
            onInputMonitoringGranted()
        }
        if needsAccessibility && !accessibility && Permissions.hasAccessibility {
            accessibility = true
            print("授權：已取得「輔助使用」")
        }
        if isComplete {
            timer?.cancel()
            timer = nil
        }
    }

    /// 清單中顯示的名稱：LaunchAgent 安裝版是 app 名稱，從終端機啟動時是終端機
    private static var clientName: String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String { return name }
        return ProcessInfo.processInfo.environment["TERM_PROGRAM"].map { "\($0)（從終端機啟動時授權對象是終端機）" } ?? "執行 mtk-server 的 App"
    }
}
