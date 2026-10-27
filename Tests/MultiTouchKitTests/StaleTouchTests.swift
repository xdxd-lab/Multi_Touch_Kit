import Foundation
import Testing
@testable import MultiTouchKit

/// 幽靈觸點與放開遺失（2026-10-28：滑鼠線碰到 MF156LR 後偶爾留下一個不會消失的觸點）
@Suite struct StaleTouchTests {
    static let ms: UInt64 = 1_000_000

    func raw(_ id: Int, _ x: Int, _ y: Int, tip: Bool = true) -> RawContact {
        RawContact(contactID: id, tip: tip, x: Double(x) / 9600, y: Double(y) / 9600, rawX: x, rawY: y)
    }

    struct Replay {
        var tracker = ContactTracker()
        var next: UInt64 = 1
        mutating func frame(_ contacts: [RawContact], at time: UInt64) -> [Touch] {
            tracker.update(contacts, at: time) {
                defer { next += 1 }
                return next
            }
        }
    }

    /// 一段觸碰中某個 contact 不再出現（沒有 tip=0）→ 視為放開
    @Test func vanishingContactEndsWithoutTipZero() {
        var r = Replay()
        _ = r.frame([raw(0, 1000, 1000), raw(1, 5000, 5000)], at: 8 * Self.ms)
        let out = r.frame([raw(0, 1000, 1000)], at: 16 * Self.ms)
        #expect(out.first { $0.contactID == 1 }?.phase == .ended)
        #expect(r.tracker.active.keys.sorted() == [0])
    }

    /// ~/ilitek-probe.csv 第一段（一指輕點 58 ms）去掉最後一筆 tip=0：觸點會停在按下，
    /// 直到 reportTimeout（0.5 秒）沒有報告才取消
    @Test func lostFinalReleaseIsCancelledByReportTimeout() {
        let times: [Double] = [0, 8.026, 16.006, 23.017, 35.024, 43.012, 49.978]   // 58.005 的 tip=0 遺失
        var r = Replay()
        var monitor = ReportTimeoutMonitor(timeout: 0.5)
        for t in times {
            let ns = UInt64(t * 1e6) + 1
            _ = r.frame([raw(0, 4408, 3158)], at: ns)
            monitor.reportReceived(at: ns)
        }
        let last = UInt64(49.978 * 1e6) + 1
        #expect(r.tracker.hasActiveTouches)
        #expect(!monitor.isExpired(at: last + 400 * Self.ms, hasActiveTouches: r.tracker.hasActiveTouches))
        #expect(monitor.isExpired(at: last + 600 * Self.ms, hasActiveTouches: r.tracker.hasActiveTouches))
        let cancelled = r.tracker.cancelAll()
        #expect(cancelled.map(\.phase) == [.cancelled])
        #expect(!r.tracker.hasActiveTouches)
        // 沒有觸點時不會觸發；timeout 0 = 關閉
        #expect(!monitor.isExpired(at: last + 10_000 * Self.ms, hasActiveTouches: false))
        #expect(!ReportTimeoutMonitor(timeout: 0).isExpired(at: .max, hasActiveTouches: true))
    }

    @Test func motionlessContactIsCancelledAfterTimeout() {
        var r = Replay()
        r.tracker.stalePolicy = .init(timeout: 30, tolerance: 0.003)
        var cancelledAt: Double?
        var t: UInt64 = 0
        while t < 35_000 * Self.ms {
            t += 8 * Self.ms
            // 線材：座標在 ±10 raw（±0.001）內抖動
            let jitter = Int(t / Self.ms) % 3 * 10 - 10
            for touch in r.frame([raw(0, 4000 + jitter, 3000)], at: t) where touch.phase == .cancelled {
                cancelledAt = Double(t) / 1e9
            }
        }
        #expect(cancelledAt.map { abs($0 - 30) < 0.02 } == true)
        #expect(!r.tracker.hasActiveTouches)           // 取消後不再回報
        #expect(r.tracker.suppressed[0] != nil)
        // 線材被移動（> 0.02）→ 視為新的觸碰
        let revived = r.frame([raw(0, 4400, 3000)], at: t + 8 * Self.ms)
        #expect(revived.map(\.phase) == [.began])
        #expect(revived[0].id == 2)
        // 控制器回報離開 → 正常結束
        #expect(r.frame([raw(0, 4400, 3000, tip: false)], at: t + 16 * Self.ms).map(\.phase) == [.ended])
    }

    @Test func suppressedContactClearsWhenLifted() {
        var r = Replay()
        r.tracker.stalePolicy = .init(timeout: 1, tolerance: 0.003)
        for i in 1...150 { _ = r.frame([raw(0, 4000, 3000)], at: UInt64(i) * 8 * Self.ms) }
        #expect(r.tracker.suppressed[0] != nil)
        _ = r.frame([], at: 1300 * Self.ms)                 // 線材移開：contact 消失
        #expect(r.tracker.suppressed.isEmpty)
        // 之後同一個 contact ID 的真實觸碰正常開始
        #expect(r.frame([raw(0, 4000, 3000)], at: 1400 * Self.ms).map(\.phase) == [.began])
    }

    @Test func movementResetsTimer() {
        var r = Replay()
        r.tracker.stalePolicy = .init(timeout: 30, tolerance: 0.003)
        var phases: [TouchPhase] = []
        var t: UInt64 = 0
        for step in 0..<(50_000 / 8) {
            t += 8 * Self.ms
            let x = step < 25_000 / 8 ? 4000 : 4060          // 25 秒時移動 60 raw（> 容許值）
            phases += r.frame([raw(0, x, 3000)], at: t).map(\.phase)
        }
        #expect(!phases.contains(.cancelled))
        #expect(r.tracker.hasActiveTouches)
    }

    /// 實測：真人 10 指按住 15 秒，座標完全不變可達 10.7 秒 → 預設 30 秒不會誤取消
    @Test func longHumanHoldIsNotCancelled() {
        var r = Replay()
        r.tracker.stalePolicy = .init(timeout: 30, tolerance: 0.003)
        let fingers = (0..<10).map { raw($0, 1000 + $0 * 800, 3000) }
        var t: UInt64 = 0
        var phases: [TouchPhase] = []
        while t < 15_000 * Self.ms {
            t += 8 * Self.ms
            phases += r.frame(fingers, at: t).map(\.phase)
        }
        #expect(!phases.contains(.cancelled))
        #expect(r.tracker.active.count == 10)
    }

    @Test func disabledByDefaultInTracker() {
        var r = Replay()   // StalePolicy 預設 timeout 0（MultiTouchManager 預設 30 秒）
        for i in 1...5000 { _ = r.frame([raw(0, 4000, 3000)], at: UInt64(i) * 8 * Self.ms) }
        #expect(r.tracker.hasActiveTouches)
        #expect(MultiTouchManager.Configuration().staleTouchTimeout == 30)
        #expect(MultiTouchManager.Configuration().reportTimeout == 0.5)
    }
}
