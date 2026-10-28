import Foundation

/// 把每個 frame 的觸點轉成帶有 began／moved／ended／cancelled 的 Touch：以 Contact Identifier 對應前一個 frame，
/// 指派跨裝置唯一的 Touch.id，並處理長時間不動的幽靈觸點（StalePolicy）。
struct ContactTracker: Sendable {
    /// 長時間完全不動的觸點（線材、物體碰到電容面板造成的幽靈觸點）的處理
    struct StalePolicy: Sendable, Equatable {
        /// 秒；0 = 關閉
        var timeout: Double = 0
        /// 正規化座標；偏離錨點不超過此值都算「不動」
        var tolerance: Double = 0.003
        /// 被取消的觸點再移動超過此距離（正規化）就視為新的觸碰
        var reviveDistance: Double = 0.02
    }

    var stalePolicy = StalePolicy()
    private(set) var active: [Int: Touch] = [:]
    /// 錨點：最後一次「明顯移動」的位置與時間（奈秒）
    private var anchors: [Int: (x: Double, y: Double, time: UInt64)] = [:]
    /// 已因長時間不動而取消、但控制器仍回報按下的 contact（記錄取消時的位置）
    private(set) var suppressed: [Int: (x: Double, y: Double)] = [:]

    /// 這個 frame 出現過的 contact（每次呼叫重複使用，避免每 frame 配置；最多約 10 筆，線性搜尋比 Set 快）
    private var seen: [Int] = []

    var hasActiveTouches: Bool { !active.isEmpty }

    /// - Parameter time: frame 時間（奈秒）；0 時不做長時間不動的判斷
    mutating func update(_ contacts: [RawContact], at time: UInt64 = 0, allocateID: () -> UInt64) -> [Touch] {
        var out: [Touch] = []
        out.reserveCapacity(max(contacts.count, active.count))
        seen.removeAll(keepingCapacity: true)
        let checkStale = stalePolicy.timeout > 0 && time > 0
        for c in contacts {
            guard !seen.contains(c.contactID) else { continue }
            seen.append(c.contactID)
            if c.tip {
                if let s = suppressed[c.contactID] {
                    // 幽靈觸點：明顯移動才當成新的觸碰，否則忽略
                    guard hypot(c.x - s.x, c.y - s.y) > stalePolicy.reviveDistance else { continue }
                    suppressed[c.contactID] = nil
                }
                if var t = active[c.contactID] {
                    t.phase = (t.rawX != c.rawX || t.rawY != c.rawY) ? .moved : .stationary
                    t.apply(c)
                    // 錨點只在「明顯移動」（超出 tolerance）時才更新，而不是每個 frame 都更新：
                    // 否則以極慢速度漂移的幽靈觸點每次都會重設計時，永遠不會被判定為不動
                    if checkStale, let a = anchors[c.contactID] {
                        if abs(c.x - a.x) > stalePolicy.tolerance || abs(c.y - a.y) > stalePolicy.tolerance {
                            anchors[c.contactID] = (c.x, c.y, time)
                        } else if Double(time &- a.time) / 1e9 >= stalePolicy.timeout {
                            t.phase = .cancelled
                            active[c.contactID] = nil
                            anchors[c.contactID] = nil
                            suppressed[c.contactID] = (c.x, c.y)
                            out.append(t)
                            continue
                        }
                    }
                    active[c.contactID] = t
                    out.append(t)
                } else {
                    var t = Touch(id: allocateID(), contactID: c.contactID, phase: .began,
                                  x: c.x, y: c.y, rawX: c.rawX, rawY: c.rawY)
                    t.apply(c)
                    active[c.contactID] = t
                    if checkStale { anchors[c.contactID] = (c.x, c.y, time) }
                    out.append(t)
                }
            } else {
                suppressed[c.contactID] = nil
                anchors[c.contactID] = nil
                if var t = active.removeValue(forKey: c.contactID) {
                    // 放開時部分控制器會回報 0,0，保留最後的有效位置
                    t.phase = .ended
                    out.append(t)
                }
            }
        }
        // 沒出現在這個 frame 的觸點視為已放開（依觸點 id 排序；先檢查，平常沒有就不必排序）
        if active.keys.contains(where: { !seen.contains($0) }) {
            for (cid, t) in active.sorted(by: { $0.value.id < $1.value.id }) where !seen.contains(cid) {
                var ended = t
                ended.phase = .ended
                active[cid] = nil
                anchors[cid] = nil
                out.append(ended)
            }
        }
        if suppressed.keys.contains(where: { !seen.contains($0) }) {
            for cid in Array(suppressed.keys) where !seen.contains(cid) { suppressed[cid] = nil }
        }
        return out
    }

    /// 裝置移除或停止時，把仍在螢幕上的觸點全部取消
    mutating func cancelAll() -> [Touch] {
        let out = active.values.sorted { $0.id < $1.id }.map { t -> Touch in
            var c = t
            c.phase = .cancelled
            return c
        }
        active.removeAll()
        anchors.removeAll()
        return out
    }
}

private extension Touch {
    mutating func apply(_ c: RawContact) {
        x = c.x
        y = c.y
        rawX = c.rawX
        rawY = c.rawY
        pressure = c.pressure
        width = c.width
        height = c.height
        confidence = c.confidence
        uncalibratedX = c.uncalibratedX
        uncalibratedY = c.uncalibratedY
    }
}
