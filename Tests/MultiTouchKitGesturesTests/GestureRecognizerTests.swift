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
        for i in 0...20 { d.frame([(1, 100 + Double(i) * 5, 100, true)]) }
        _ = d.take()
        #expect(d.recognizer.reset() == [.mouseUp(.left, CGPoint(x: 200, y: 100), clickCount: 1)])
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
        // 每步相對變化量連乘 = 總放大倍率：指距 100 → 300（×3），增益 0.6 → ×3^0.6
        let scale = events.reduce(1.0) { if case .magnify(let m, _) = $1 { $0 * (1 + m) } else { $0 } }
        #expect(abs(scale - pow(3, 0.6)) < 0.001)

        var linear = Driver()
        linear.recognizer.configuration.magnifyExponent = 1
        linear.twoFingers(from: CGPoint(x: 400, y: 300), CGPoint(x: 500, y: 300),
                          to: CGPoint(x: 300, y: 300), CGPoint(x: 600, y: 300), steps: 20)
        let linearScale = linear.take().reduce(1.0) { if case .magnify(let m, _) = $1 { $0 * (1 + m) } else { $0 } }
        #expect(abs(linearScale - 3) < 0.001)
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
        // 決定縮放為主後再轉超過 24° 才送旋轉，所以只送出後段的角度
        #expect(totalRotation(events) > 10)
    }

    // 第 2 輪實機 dry-run

    @Test func rotationWithShrinkingDistanceDoesNotMagnify() {
        // 轉 80°，指距同時從 300 縮到 255（×0.85）→ 不送縮放
        let path = (0...25).map { i -> (CGPoint, CGPoint) in
            let k = Double(i) / 25
            let r = 150 - 22.5 * k
            let a = k * 80 * .pi / 180
            return (CGPoint(x: 500 - r * cos(a), y: 500 - r * sin(a)), CGPoint(x: 500 + r * cos(a), y: 500 + r * sin(a)))
        }
        let events = run(path)
        #expect(abs(totalRotation(events) + 80) < 0.5)
        #expect(!has(events, isMagnify))
    }

    @Test func briefTwoFingerTwistIsIgnored() {
        // 兩指只碰 40 ms、轉了 16°
        let path = (0...4).map { i -> (CGPoint, CGPoint) in
            let a = -Double(i) * 4 * .pi / 180
            return (CGPoint(x: 500 - 80 * cos(a), y: 500 - 80 * sin(a)), CGPoint(x: 500 + 80 * cos(a), y: 500 + 80 * sin(a)))
        }
        let events = run(path)
        #expect(!has(events, isRotate))
    }

    @Test func pivotStartWithHandDriftWaitsBeforeScrolling() {
        // 一指為軸旋轉，但一開始整隻手往右下漂移 15 點（方向不明確），之後才明顯轉動
        let pivot = CGPoint(x: 500, y: 500)
        var path: [(CGPoint, CGPoint)] = []
        for i in 0...5 {
            let k = Double(i) / 5
            path.append((CGPoint(x: pivot.x + 10 * k, y: pivot.y + 5 * k), CGPoint(x: pivot.x + 150 + 18 * k, y: pivot.y + 12 * k)))
        }
        let shifted = CGPoint(x: pivot.x + 10, y: pivot.y + 5)
        for i in 1...25 {
            let a = (5 + Double(i) * 2) * .pi / 180
            path.append((shifted, CGPoint(x: shifted.x + 160 * cos(a), y: shifted.y + 160 * sin(a))))
        }
        let events = run(path)
        #expect(!has(events, isScroll))
        #expect(has(events, isRotate))
    }

    @Test func secondFingerLandingAfterFirstMovesIsNotDrag() {
        // 第一指落下後就移動 30 點，第二指 90 ms 後才落下，兩指再一起轉
        var d = Driver()
        for i in 0..<11 { d.frame([(1, 500 + Double(i) * 3, 500, true)]) }
        for i in 1...25 {
            let a = -Double(i) * 2 * .pi / 180
            d.frame([(1, 530, 500, true), (2, 530 + 150 * cos(a), 500 + 150 * sin(a), true)])
        }
        d.frame([(1, 530, 500, false), (2, 530, 350, false)])
        let events = d.take()
        #expect(!events.contains { if case .mouseDown = $0 { true } else { false } })
        #expect(has(events, isRotate))
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
        output.send([.mouseDown(.left, .zero, clickCount: 1), .mouseDragged(.left, CGPoint(x: 30, y: 40)),
                     .mouseUp(.left, CGPoint(x: 30, y: 40), clickCount: 1)])
        #expect(lines.last == "[手勢 dry-run] mouseUp left (30,40) clicks=1（拖曳 50.0 點、1 筆、0 ms）")
    }
}

/// 單指停留後再放第二指、誤觸
@Suite struct HoldThenSecondFingerTests {
    @Test func driftingHeldFingerThenSecondFingerRotates() {
        // 軸心手指先放、停 0.4 秒期間慢慢漂移 30 點（75 點／秒），再放第二指以它為軸旋轉 50°
        var d = Driver()
        for i in 0...50 { d.frame([(1, 500 + Double(i) * 0.6, 500, true)]) }
        let pivot = CGPoint(x: 530, y: 500)
        for i in 0...25 {
            let a = -Double(i) * 2 * .pi / 180
            d.frame([(1, pivot.x, pivot.y, true), (2, pivot.x + 150 * cos(a), pivot.y + 150 * sin(a), true)])
        }
        d.frame([(1, pivot.x, pivot.y, false), (2, pivot.x, pivot.y - 150, false)])
        let events = d.take()
        #expect(!events.contains { if case .mouseDown = $0 { true } else { false } })
        #expect(!events.contains { if case .scroll = $0 { true } else { false } })
        let total = events.reduce(0.0) { if case .rotate(let deg, _) = $1 { $0 + deg } else { $0 } }
        #expect(abs(total - 50) < 0.5)
    }

    @Test func driftBeforeSecondFingerDoesNotBiasScrollDecision() {
        // 第一指先漂移 30 點，第二指落下後兩指一起往下捲 150 點 → 捲動，且只算兩指一起移動的部分
        var d = Driver()
        for i in 0...40 { d.frame([(1, 400 + Double(i) * 0.75, 300, true)]) }
        for i in 0...20 {
            let y = 300 + 7.5 * Double(i)
            d.frame([(1, 430, y, true), (2, 530, y, true)])
        }
        d.frame([(1, 430, 450, false), (2, 530, 450, false)])
        let events = d.take()
        #expect(!events.contains { if case .mouseDown = $0 { true } else { false } })
        let dx = events.reduce(0.0) { if case .scroll(let x, _, _) = $1 { $0 + x } else { $0 } }
        let dy = events.reduce(0.0) { if case .scroll(_, let y, _) = $1 { $0 + y } else { $0 } }
        #expect(abs(dx) < 0.001)
        #expect(abs(dy - 150) < 0.001)
    }

    @Test func slowDeliberateDragStillDrags() {
        // 慢慢拖 80 點（100 點／秒）：超過 40 點後才按下，按下位置仍是起點
        var d = Driver()
        for i in 0...100 { d.frame([(1, 200 + Double(i) * 0.8, 200, true)]) }
        d.frame([(1, 280, 200, false)])
        let events = d.take()
        #expect(events.first == .mouseDown(.left, CGPoint(x: 200, y: 200), clickCount: 1))
        #expect(events.last == .mouseUp(.left, CGPoint(x: 280, y: 200), clickCount: 1))
    }

    @Test func quickDragStartsAfterSettle() {
        // 正常速度拖曳（1250 點／秒）：0.12 秒後就按下
        var d = Driver()
        var downTime: Double?
        for i in 0...30 {
            d.frame([(1, 200 + Double(i) * 10, 200, true)])
            if downTime == nil, d.events.contains(where: { if case .mouseDown = $0 { true } else { false } }) { downTime = d.time }
        }
        #expect((downTime ?? 1) <= 0.13)
    }

    @Test func tooManyContactsCancelsGesture() {
        // 兩指捲動中手掌碰到（一次多出 4 點）→ 捲動以 cancelled 結束，之後忽略到全部離開
        var d = Driver()
        for i in 0...10 { d.frame([(1, 400, 300 + Double(i) * 5, true), (2, 500, 300 + Double(i) * 5, true)]) }
        let palm: [(UInt64, Double, Double, Bool)] = (3...6).map { ($0, 800 + Double($0) * 20, 900, true) }
        d.frame([(1, 400, 360, true), (2, 500, 360, true)] + palm)
        d.frame([(1, 400, 400, true), (2, 500, 400, true)] + palm)
        d.frame(([(1, 400, 400, false), (2, 500, 400, false)] as [(UInt64, Double, Double, Bool)]) + palm.map { ($0.0, $0.1, $0.2, false) })
        let events = d.take()
        #expect(events.contains(.scroll(dx: 0, dy: 0, phase: .cancelled)))
        #expect(events.last == .scroll(dx: 0, dy: 0, phase: .cancelled))
        #expect(d.recognizer.isIdle)
    }

    @Test func brushingContactIsNotAFlick() {
        // 兩點只碰 16 ms、移動 15 點就離開（手的其他部位擦過）→ 不送捲動
        var d = Driver()
        d.frame([(1, 400, 300, true), (2, 500, 300, true)])
        d.frame([(1, 412, 308, true), (2, 512, 308, true)])
        d.frame([(1, 412, 308, false), (2, 512, 308, false)])
        #expect(!d.take().contains { if case .scroll = $0 { true } else { false } })
    }
}
