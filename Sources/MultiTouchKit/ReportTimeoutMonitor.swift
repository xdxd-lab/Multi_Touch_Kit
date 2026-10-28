import Foundation

/// 報告中斷偵測：ILITEK 在手指全部離開時只送最後一筆 tip=0 就停止回報；那筆遺失（USB 異常、睡眠）時，
/// 觸點會永遠停在「按下」。有觸點時超過 `timeout` 沒有任何報告就應全部取消。
struct ReportTimeoutMonitor: Sendable {
    /// 秒；0 = 關閉
    var timeout: Double
    private(set) var lastReport: UInt64 = 0

    init(timeout: Double) {
        self.timeout = timeout
    }

    mutating func reportReceived(at time: UInt64) { lastReport = time }

    /// 已超過時間沒有報告（只在仍有觸點時有意義）
    func isExpired(at now: UInt64, hasActiveTouches: Bool) -> Bool {
        timeout > 0 && hasActiveTouches && Double(now &- lastReport) / 1e9 > timeout
    }

    func silence(at now: UInt64) -> Double { Double(now &- lastReport) / 1e9 }
}
