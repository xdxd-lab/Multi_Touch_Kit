import Foundation

/// 把一或多份報告組成完整 frame（處理 Microsoft 規範的 hybrid mode）。
///
/// 控制器每份報告的槽位比最大觸點數少時（例如 5 槽、10 點），一次掃描會分成多份報告送出：
/// 第一份的 Contact Count 是整個 frame 的觸點總數，後續報告的 Contact Count 為 0、只帶剩下的觸點。
/// 收齊 Contact Count 個觸點才算一個 frame；後續報告遺失時，下一份 Contact Count > 0 的報告會重新開始，
/// 不會把兩次掃描混在一起。ILITEK（10 槽、10 點）每份報告就是一個完整 frame。
struct FrameAssembler: Sendable {
    private var remaining = 0
    private var pending: [RawContact] = []
    private var frameStart: UInt64 = 0

    /// 回傳完成的 frame（觸點清單與第一份報告的時間）；frame 尚未收齊時回傳 nil
    mutating func add(_ report: ParsedTouchReport, timestamp: UInt64) -> (contacts: [RawContact], timestamp: UInt64)? {
        guard let count = report.contactCount else {
            // 沒有 Contact Count 欄位：每份報告就是一個 frame，略過空槽位
            let used = report.slots.filter { $0.tip }
            return (used, timestamp)
        }
        if count > 0 {
            frameStart = timestamp
            let take = min(count, report.slots.count)
            pending = Array(report.slots.prefix(take))
            remaining = count - take
        } else if remaining > 0 {
            let take = min(remaining, report.slots.count)
            pending += report.slots.prefix(take)
            remaining -= take
        } else {
            // Contact Count = 0 且沒有待補資料：所有手指都已離開
            pending = []
            frameStart = timestamp
        }
        guard remaining == 0 else { return nil }
        defer { pending = [] }
        return (pending, frameStart)
    }
}
