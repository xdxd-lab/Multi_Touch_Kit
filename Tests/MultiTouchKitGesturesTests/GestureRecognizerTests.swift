import CoreGraphics
import Foundation
import Testing
@testable import MultiTouchKitGestures

/// 以 125 Hz（8 ms）餵 frame 的測試輔助
struct Driver {
    var recognizer = GestureRecognizer()
    var time = 0.0
    var events: [GestureEvent] = []

    /// 每根手指：(id, x, y, 是否仍在螢幕上)
    mutating func frame(_ touches: [(UInt64, Double, Double, Bool)], dt: Double = 0.008) {
        time += dt
        events += recognizer.process(touches.map { GestureTouch(id: $0.0, position: CGPoint(x: $0.1, y: $0.2), isDown: $0.3) }, at: time)
    }

    mutating func tick(for duration: Double, step: Double = 0.008) {
        let end = time + duration
        while time < end {
            time += step
            events += recognizer.tick(at: time)
        }
    }

    /// 兩指從 (a, b) 線性移動到 (a2, b2)
    mutating func twoFingers(from a: CGPoint, _ b: CGPoint, to a2: CGPoint, _ b2: CGPoint, steps: Int, lift: Bool = true) {
        for i in 0...steps {
            let k = Double(i) / Double(steps)
            frame([(1, a.x + (a2.x - a.x) * k, a.y + (a2.y - a.y) * k, true),
                   (2, b.x + (b2.x - b.x) * k, b.y + (b2.y - b.y) * k, true)])
        }
        if lift { frame([(1, a2.x, a2.y, false), (2, b2.x, b2.y, false)]) }
    }

    mutating func take() -> [GestureEvent] {
        defer { events = [] }
        return events
    }
}

@Suite struct PointerGestureTests {
    @Test func tapIsLeftClickAtStart() {
        var d = Driver()
        d.frame([(1, 100, 100, true)])
        d.frame([(1, 103, 101, true)])
        d.frame([(1, 103, 101, false)])
        #expect(d.take() == [.mouseDown(.left, CGPoint(x: 100, y: 100), clickCount: 1),
                             .mouseUp(.left, CGPoint(x: 100, y: 100), clickCount: 1)])
        #expect(d.recognizer.isIdle)
    }

    @Test func doubleAndTripleTap() {
        var d = Driver()
        for _ in 0..<3 {
            d.frame([(1, 100, 100, true)], dt: 0.1)
            d.frame([(1, 100, 100, false)])
        }
        let downs = d.take().compactMap { e -> Int? in
            if case .mouseDown(_, _, let n) = e { return n }
            return nil
        }
        #expect(downs == [1, 2, 3])
    }

    @Test func slowSecondTapIsNewClick() {
        var d = Driver()
        d.frame([(1, 100, 100, true)])
        d.frame([(1, 100, 100, false)])
        d.frame([(2, 100, 100, true)], dt: 0.6)
        d.frame([(2, 100, 100, false)])
        #expect(d.take().last == .mouseUp(.left, CGPoint(x: 100, y: 100), clickCount: 1))
    }

    @Test func dragPressesAtStartPoint() {
        var d = Driver()
        for i in 0...10 { d.frame([(1, 100 + Double(i) * 10, 200, true)]) }
        d.frame([(1, 200, 200, false)])
        let events = d.take()
        #expect(events.first == .mouseDown(.left, CGPoint(x: 100, y: 200), clickCount: 1))
        #expect(events.contains(.mouseDragged(.left, CGPoint(x: 200, y: 200))))
        #expect(events.last == .mouseUp(.left, CGPoint(x: 200, y: 200), clickCount: 1))
        #expect(!events.contains { if case .mouseDown(.right, _, _) = $0 { true } else { false } })
    }

    @Test func longPressIsRightClick() {
        var d = Driver()
        d.frame([(1, 300, 300, true)])
        d.tick(for: 0.5)
        #expect(d.take().isEmpty)
        d.tick(for: 0.2)
        #expect(d.take() == [.mouseDown(.right, CGPoint(x: 300, y: 300), clickCount: 1),
                             .mouseUp(.right, CGPoint(x: 300, y: 300), clickCount: 1)])
        // 長按後移動與放開都不再產生事件
        d.frame([(1, 400, 300, true)])
        d.frame([(1, 400, 300, false)])
        #expect(d.take().isEmpty)
        #expect(d.recognizer.isIdle)
    }

    @Test func twoFingerTapIsRightClickAtCentroid() {
        var d = Driver()
        d.frame([(1, 100, 100, true)])
        d.frame([(1, 100, 100, true), (2, 200, 100, true)], dt: 0.02)
        d.frame([(1, 100, 100, false), (2, 200, 100, true)], dt: 0.08)
        d.frame([(2, 200, 100, false)])
        #expect(d.take() == [.mouseDown(.right, CGPoint(x: 150, y: 100), clickCount: 1),
                             .mouseUp(.right, CGPoint(x: 150, y: 100), clickCount: 1)])
    }

    @Test func resetReleasesHeldButton() {
        var d = Driver()
        for i in 0...10 { d.frame([(1, 100 + Double(i) * 5, 100, true)]) }
        _ = d.take()
        #expect(d.recognizer.reset() == [.mouseUp(.left, CGPoint(x: 150, y: 100), clickCount: 1)])
        #expect(d.recognizer.isIdle)
    }
}

@Suite struct TwoFingerGestureTests {
    @Test func scrollFollowsFingersWithMomentum() {
        var d = Driver()
        // 兩指往下 200 點，40 ms 內完成（快速甩動）
        d.twoFingers(from: CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100),
                     to: CGPoint(x: 100, y: 300), CGPoint(x: 200, y: 300), steps: 5)
        let events = d.take()
        guard case .pointer(let at) = events.first else { Issue.record("沒有先移動游標"); return }
        #expect(at == CGPoint(x: 150, y: 100))
        guard case .scroll(_, let dy0, .began) = events[1] else { Issue.record("沒有 scroll began：\(events)"); return }
        #expect(dy0 > 0)
        let totalDY = events.reduce(0.0) { if case .scroll(_, let dy, _) = $1 { $0 + dy } else { $0 } }
        #expect(abs(totalDY - 200) < 0.001)
        #expect(events.suffix(2) == [.scroll(dx: 0, dy: 0, phase: .ended), .momentum(dx: 0, dy: 0, phase: .began)])
        #expect(d.recognizer.needsTick)

        d.tick(for: 3)
        let momentum = d.take()
        #expect(momentum.count > 10)
        #expect(momentum.last.map { if case .momentum(_, _, .ended) = $0 { true } else { false } } == true)
        let glide = momentum.reduce(0.0) { if case .momentum(_, let dy, _) = $1 { $0 + dy } else { $0 } }
        #expect(glide > 50)
        #expect(!d.recognizer.needsTick)
    }

    @Test func slowScrollHasNoMomentum() {
        var d = Driver()
        d.twoFingers(from: CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100),
                     to: CGPoint(x: 100, y: 140), CGPoint(x: 200, y: 140), steps: 60)
        #expect(d.take().last == .scroll(dx: 0, dy: 0, phase: .ended))
        #expect(!d.recognizer.needsTick)
    }

    @Test func touchStopsMomentum() {
        var d = Driver()
        d.twoFingers(from: CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100),
                     to: CGPoint(x: 100, y: 300), CGPoint(x: 200, y: 300), steps: 5)
        d.tick(for: 0.1)
        _ = d.take()
        d.frame([(5, 500, 500, true)])
        #expect(d.take() == [.momentum(dx: 0, dy: 0, phase: .ended)])
        #expect(!d.recognizer.isIdle)
    }

    @Test func staggeredSecondFingerStillScrolls() {
        var d = Driver()
        d.frame([(1, 100, 100, true)])
        d.frame([(1, 100, 100, true), (2, 200, 100, true)], dt: 0.03)
        for i in 1...10 { d.frame([(1, 100 + Double(i) * 5, 100, true), (2, 200 + Double(i) * 5, 100, true)]) }
        let events = d.take()
        #expect(!events.contains { if case .mouseDown = $0 { true } else { false } })
        #expect(events.contains { if case .scroll(let dx, _, .began) = $0 { dx > 0 } else { false } })
    }

    @Test func pinchOutMagnifies() {
        var d = Driver()
        d.twoFingers(from: CGPoint(x: 400, y: 300), CGPoint(x: 500, y: 300),
                     to: CGPoint(x: 300, y: 300), CGPoint(x: 600, y: 300), steps: 20)
        let events = d.take()
        #expect(events.contains { if case .magnify(let m, .began) = $0 { m > 0 } else { false } })
        #expect(!events.contains { if case .scroll = $0 { true } else { false } })
        #expect(!events.contains { if case .rotate = $0 { true } else { false } })
        #expect(events.last == .magnify(0, phase: .ended))
        // 每步相對變化量連乘 = 總放大倍率（距離 100 → 300）
        let scale = events.reduce(1.0) { if case .magnify(let m, _) = $1 { $0 * (1 + m) } else { $0 } }
        #expect(abs(scale - 3) < 0.001)
    }

    @Test func counterClockwiseRotationIsPositive() {
        var d = Driver()
        let center = CGPoint(x: 400, y: 400)
        let r = 80.0
        var points: [(CGPoint, CGPoint)] = []
        for i in 0...20 {
            // 畫面上逆時針：Quartz y 向下，所以角度遞減
            let a = -Double(i) * 2 * .pi / 180
            points.append((CGPoint(x: center.x - r * cos(a), y: center.y - r * sin(a)),
                           CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))))
        }
        for (p, q) in points { d.frame([(1, p.x, p.y, true), (2, q.x, q.y, true)]) }
        d.frame([(1, points.last!.0.x, points.last!.0.y, false), (2, points.last!.1.x, points.last!.1.y, false)])
        let events = d.take()
        let total = events.reduce(0.0) { if case .rotate(let deg, _) = $1 { $0 + deg } else { $0 } }
        #expect(abs(total - 40) < 0.5)
        #expect(events.last == .rotate(degrees: 0, phase: .ended))
        #expect(!events.contains { if case .scroll = $0 { true } else { false } })
    }
}

@Suite struct SwipeGestureTests {
    func swipe(fingers: Int, dx: Double, dy: Double, steps: Int = 15) -> [GestureEvent] {
        var d = Driver()
        let ids = (1...UInt64(fingers)).map { $0 }
        for i in 0...steps {
            let k = Double(i) / Double(steps)
            d.frame(ids.map { ($0, 300 + Double($0) * 60 + dx * k, 500 + dy * k, true) })
        }
        d.frame(ids.map { ($0, 300 + Double($0) * 60 + dx, 500 + dy, false) })
        return d.take()
    }

    @Test func threeFingerSwipeLeftGoesToNextSpace() {
        let events = swipe(fingers: 3, dx: -300, dy: 10)
        guard case .swipe(.horizontal, let p0, _, 3, .began) = events.first else { Issue.record("\(events)"); return }
        #expect(p0 < 0)
        guard case .swipe(.horizontal, let progress, let velocity, 3, .ended) = events.last else { Issue.record("\(events)"); return }
        #expect(abs(progress - (-300.0 / 450)) < 0.001)
        #expect(velocity < 0)
        #expect(SwipeShortcut.resolve(axis: .horizontal, progress: progress, velocity: velocity) == .nextSpace)
        #expect(!events.contains { if case .mouseDown = $0 { true } else { false } })
    }

    @Test func fourFingerSwipeUpIsMissionControl() {
        let events = swipe(fingers: 4, dx: 5, dy: -250)
        guard case .swipe(.vertical, let progress, let velocity, 4, .ended) = events.last else { Issue.record("\(events)"); return }
        #expect(SwipeShortcut.resolve(axis: .vertical, progress: progress, velocity: velocity) == .missionControl)
    }

    @Test func shortcutThresholds() {
        #expect(SwipeShortcut.resolve(axis: .horizontal, progress: 0.3, velocity: 0) == .previousSpace)
        #expect(SwipeShortcut.resolve(axis: .vertical, progress: 0.3, velocity: 0) == .appExpose)
        #expect(SwipeShortcut.resolve(axis: .horizontal, progress: 0.1, velocity: 0.2) == nil)
        // 位移不夠但快速甩動
        #expect(SwipeShortcut.resolve(axis: .horizontal, progress: -0.12, velocity: -2) == .nextSpace)
    }

    @Test func smallThreeFingerMovementDoesNothing() {
        #expect(swipe(fingers: 3, dx: 20, dy: 0).isEmpty)
    }
}
