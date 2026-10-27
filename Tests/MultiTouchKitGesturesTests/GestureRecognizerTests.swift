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

/// 2026-10-28 實機 dry-run 回報的問題（雙指旋轉被當成捲動、捏合時誤送旋轉）
@Suite struct TwoFingerDisambiguationTests {
    func run(_ path: [(CGPoint, CGPoint)]) -> [GestureEvent] {
        var d = Driver()
        for (p, q) in path { d.frame([(1, p.x, p.y, true), (2, q.x, q.y, true)]) }
        d.frame([(1, path.last!.0.x, path.last!.0.y, false), (2, path.last!.1.x, path.last!.1.y, false)])
        return d.take()
    }

    func has(_ events: [GestureEvent], _ match: (GestureEvent) -> Bool) -> Bool { events.contains(where: match) }
    func isScroll(_ e: GestureEvent) -> Bool { if case .scroll = e { true } else { false } }
    func isRotate(_ e: GestureEvent) -> Bool { if case .rotate = e { true } else { false } }
    func isMagnify(_ e: GestureEvent) -> Bool { if case .magnify = e { true } else { false } }
    func totalRotation(_ events: [GestureEvent]) -> Double {
        events.reduce(0) { if case .rotate(let deg, _) = $1 { $0 + deg } else { $0 } }
    }

    @Test func pivotRotationAroundOneFingerIsRotation() {
        // 一指固定、另一指以 150 點半徑繞它轉 45°（質心也會移動約 57 點）
        let pivot = CGPoint(x: 500, y: 500)
        let path = (0...30).map { i -> (CGPoint, CGPoint) in
            let a = -Double(i) * 1.5 * .pi / 180
            return (pivot, CGPoint(x: pivot.x + 150 * cos(a), y: pivot.y + 150 * sin(a)))
        }
        let events = run(path)
        #expect(!has(events, isScroll))
        #expect(!has(events, isMagnify))
        #expect(abs(totalRotation(events) - 45) < 0.5)
    }

    @Test func rotationWithDriftingCenterIsRotation() {
        // 兩指轉 40° 的同時整體往右漂移 30 點
        let path = (0...20).map { i -> (CGPoint, CGPoint) in
            let a = -Double(i) * 2 * .pi / 180
            let c = CGPoint(x: 500 + 1.5 * Double(i), y: 500)
            return (CGPoint(x: c.x - 90 * cos(a), y: c.y - 90 * sin(a)), CGPoint(x: c.x + 90 * cos(a), y: c.y + 90 * sin(a)))
        }
        let events = run(path)
        #expect(!has(events, isScroll))
        #expect(abs(totalRotation(events) - 40) < 0.5)
    }

    @Test func pinchWithNaturalTwistDoesNotRotate() {
        // 張開 100 → 300 點，過程中手指自然歪 8°（低於次要門檻 24°）
        let path = (0...20).map { i -> (CGPoint, CGPoint) in
            let k = Double(i) / 20
            let r = 50 + 100 * k
            let a = -k * 8 * .pi / 180
            return (CGPoint(x: 500 - r * cos(a), y: 500 - r * sin(a)), CGPoint(x: 500 + r * cos(a), y: 500 + r * sin(a)))
        }
        let events = run(path)
        #expect(has(events, isMagnify))
        #expect(!has(events, isRotate))
        #expect(!has(events, isScroll))
    }

    @Test func pinchInToTouchingFingersIgnoresAngleNoise() {
        // 捏合到兩指幾乎碰在一起，最後幾個 frame 角度亂跳
        var path = (0...15).map { i -> (CGPoint, CGPoint) in
            let r = 120 - 7 * Double(i)
            return (CGPoint(x: 500 - r, y: 500), CGPoint(x: 500 + r, y: 500))
        }
        path += [(CGPoint(x: 490, y: 505), CGPoint(x: 505, y: 492)), (CGPoint(x: 500, y: 490), CGPoint(x: 497, y: 506)),
                 (CGPoint(x: 505, y: 498), CGPoint(x: 492, y: 500))]
        let events = run(path)
        #expect(has(events) { if case .magnify(let m, .began) = $0 { m < 0 } else { false } })
        #expect(!has(events, isRotate))
    }

    @Test func largeRotationDuringPinchAlsoRotates() {
        // 縮放為主，但同時轉了 60°（超過次要門檻）→ 兩者都送
        let path = (0...30).map { i -> (CGPoint, CGPoint) in
            let k = Double(i) / 30
            let r = 60 + 120 * k
            let a = -k * 60 * .pi / 180
            return (CGPoint(x: 500 - r * cos(a), y: 500 - r * sin(a)), CGPoint(x: 500 + r * cos(a), y: 500 + r * sin(a)))
        }
        let events = run(path)
        #expect(has(events, isMagnify))
        #expect(has(events, isRotate))
        #expect(totalRotation(events) > 20)
    }

    @Test func slightlyDivergingFingersStillScroll() {
        // 兩指往下 150 點，指間距同時變寬 20 點（相對位移小於重心位移）
        let path = (0...20).map { i -> (CGPoint, CGPoint) in
            let k = Double(i) / 20
            return (CGPoint(x: 400 - 10 * k, y: 300 + 150 * k), CGPoint(x: 500 + 10 * k, y: 300 + 150 * k))
        }
        let events = run(path)
        #expect(has(events, isScroll))
        #expect(!has(events, isMagnify))
        #expect(!has(events, isRotate))
    }
}

@Suite struct DryRunLogTests {
    @Test func logsTotalsAtEnd() {
        nonisolated(unsafe) var lines: [String] = []
        nonisolated(unsafe) var now = 0.0
        let output = LoggingGestureOutput(clock: { now }) { lines.append($0) }
        output.send([.scroll(dx: 1, dy: 10, phase: .began), .scroll(dx: 1, dy: 20, phase: .changed)])
        now = 0.25
        output.send([.scroll(dx: 0, dy: 0, phase: .ended), .momentum(dx: 0, dy: 0, phase: .began),
                     .momentum(dx: 0, dy: 30, phase: .changed)])
        now = 0.75
        output.send([.momentum(dx: 0, dy: 5, phase: .ended),
                     .magnify(0.1, phase: .began), .magnify(0.1, phase: .changed), .magnify(0, phase: .ended),
                     .rotate(degrees: 5, phase: .began), .rotate(degrees: 10, phase: .changed), .rotate(degrees: 0, phase: .ended)])
        #expect(lines.contains("[手勢 dry-run] scroll ended：共 dx=2.0 dy=30.0 點、3 筆、250 ms"))
        #expect(lines.contains("[手勢 dry-run] momentum ended：慣性共 dx=0.0 dy=35.0 點、3 筆、500 ms"))
        #expect(lines.contains("[手勢 dry-run] magnify ended：總倍率 ×1.210、0 ms"))
        #expect(lines.contains("[手勢 dry-run] rotate ended：共 15.0°（逆時針為正）、0 ms"))
    }
}
