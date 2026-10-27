import CoreGraphics
import Foundation

/// 把觸控 frame 轉成抽象手勢事件的狀態機。純邏輯、不送任何系統事件，可直接單元測試。
///
/// 手勢（座標與距離單位都是點）：
/// - 一指點擊 → 左鍵點擊（連點會累加 clickCount，可雙擊／三擊）
/// - 一指移動 → 左鍵拖曳（移動超過 `tapSlop` 才按下，按下位置是手指起點）
/// - 一指長按不動 → 右鍵點擊（`longPressDuration`）
/// - 兩指點擊 → 右鍵點擊
/// - 兩指平移 → 捲動，放開後依速度產生慣性捲動
/// - 兩指開合／轉動 → 縮放／旋轉（可同時）
/// - 三指以上滑動 → swipe（左右切換桌面、上 Mission Control、下 App Exposé）
///
/// 手指不會同時落下：第一指落下後 `settleDuration` 內出現的手指都算同一個手勢；
/// 手勢一旦決定，之後新增的手指都忽略，直到所有手指離開。
public struct GestureRecognizer: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// 位移在此範圍內仍算點擊（點）
        public var tapSlop: Double = 14
        /// 等待其他手指落下的時間（秒）
        public var settleDuration: Double = 0.05
        public var longPressDuration: Double = 0.6
        public var twoFingerTapMaxDuration: Double = 0.35
        public var doubleClickInterval: Double = 0.45
        public var doubleClickDistance: Double = 24
        /// 兩指重心移動超過此距離開始捲動（點）
        public var scrollThreshold: Double = 12
        /// 兩指距離變化超過此值開始縮放（點）
        public var pinchThreshold: Double = 30
        /// 兩指角度變化超過此值開始旋轉（度）
        public var rotationThreshold: Double = 12
        /// 兩指間距小於此值時角度雜訊太大，不判斷也不送出旋轉（點）
        public var rotationMinimumDistance: Double = 60
        /// 兩指相對位移（指間向量的變化）小於重心位移的這個比例才算捲動；
        /// 以一指為軸旋轉或單指捏合時，相對位移約為重心位移的 2 倍，不會被當成捲動
        public var scrollMaximumRelativeMotion: Double = 0.8
        /// 縮放與旋轉先決定主要的一個；另一個要從決定當下再超過門檻的這個倍數才會一起送出
        public var secondaryTransformFactor: Double = 2
        /// 三指以上重心移動超過此距離開始 swipe（點）
        public var swipeThreshold: Double = 50
        /// swipe progress = 1 所需的手指位移（點）
        public var swipeDistance: Double = 450
        /// 放開時速度超過此值才產生慣性捲動（點／秒）
        public var momentumMinimumSpeed: Double = 150
        /// 慣性速度低於此值時停止（點／秒）
        public var momentumStopSpeed: Double = 20
        /// 慣性衰減率（每秒，速度 × e^(-friction·t)）
        public var momentumFriction: Double = 3.5
        /// 計算放開速度時取最近多久的位移（秒）
        public var velocityWindow: Double = 0.1

        public init() {}
    }

    private enum State: Sendable {
        case idle
        /// 手指已落下但手勢還沒決定
        case pending(start: Double, fingers: Int)
        case pointer(id: UInt64, clickCount: Int, last: CGPoint)
        case scroll(ids: [UInt64], last: CGPoint, samples: [Sample])
        case transform(a: UInt64, b: UInt64, commitDistance: Double, commitAngle: Double,
                       lastDistance: Double, lastAngle: Double, magnifying: Bool, rotating: Bool)
        case swipe(axis: SwipeAxis, ids: [UInt64], origin: CGPoint, lastProgress: Double, samples: [Sample])
        /// 手勢已結束（或被忽略），等所有手指離開
        case waitLift
    }

    struct Sample: Sendable {
        var time: Double
        var point: CGPoint
    }

    private struct Momentum: Sendable {
        var vx: Double
        var vy: Double
        var time: Double
    }

    public var configuration: Configuration
    private var state = State.idle
    /// 目前在螢幕上的手指
    private var down: [UInt64: CGPoint] = [:]
    /// 這次手勢中每根手指的起點與落下順序
    private var starts: [UInt64: CGPoint] = [:]
    private var order: [UInt64] = []
    /// 這次手勢中任一手指離起點的最大距離
    private var maxMovement = 0.0
    /// 手勢決定前每個 frame 的手指位置，決定後用來計算速度（快速甩動時手勢可能只持續幾個 frame）
    private var pendingHistory: [(time: Double, points: [UInt64: CGPoint])] = []
    private var momentum: Momentum?
    private var lastClick: (time: Double, point: CGPoint, count: Int)?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// 有長按計時或慣性捲動進行中，需要定期呼叫 `tick`
    public var needsTick: Bool {
        if momentum != nil { return true }
        if case .pending = state { return true }
        return false
    }

    /// 是否有手勢進行中（含等待手指離開與慣性）
    public var isIdle: Bool {
        if momentum != nil { return false }
        if case .idle = state { return true }
        return false
    }

    // MARK: - 輸入

    /// - Parameters:
    ///   - touches: 這個 frame 的所有手指（含剛離開的，`isDown == false`）
    ///   - time: frame 時間（秒，單調遞增）
    public mutating func process(_ touches: [GestureTouch], at time: Double) -> [GestureEvent] {
        var out: [GestureEvent] = []
        // 手指觸碰螢幕就停止慣性（與觸控板相同）
        if momentum != nil, touches.contains(where: { $0.isDown && down[$0.id] == nil }) {
            out.append(.momentum(dx: 0, dy: 0, phase: .ended))
            momentum = nil
        }
        // 先以最後位置更新所有手指（含這個 frame 離開的），再移除離開的
        var lifted: [UInt64: CGPoint] = [:]
        for t in touches {
            if t.isDown {
                if starts[t.id] == nil {
                    starts[t.id] = t.position
                    order.append(t.id)
                }
                down[t.id] = t.position
            } else if down[t.id] != nil {
                down[t.id] = t.position
                lifted[t.id] = t.position
            }
        }
        for (id, p) in down {
            if let s = starts[id] { maxMovement = max(maxMovement, distance(s, p)) }
        }
        if case .pending(_, let fingers) = state {
            pendingHistory.append((time, down))
            if pendingHistory.count > 64 { pendingHistory.removeFirst() }
            // 還在等待其他手指時就放開（快速甩動）：以放開前的狀態立刻決定手勢
            if !lifted.isEmpty, maxMovement > configuration.tapSlop {
                out += decide(fingers: max(fingers, down.count), elapsed: .infinity,
                              downIDs: order.filter { down[$0] != nil }, at: time)
            }
        }
        for id in lifted.keys { down[id] = nil }
        let downIDs = order.filter { down[$0] != nil }

        switch state {
        case .idle:
            if !downIDs.isEmpty { state = .pending(start: time, fingers: downIDs.count) }

        case .pending(let start, var fingers):
            fingers = max(fingers, downIDs.count)
            state = .pending(start: start, fingers: fingers)
            if downIDs.isEmpty {
                out += tap(fingers: fingers, duration: time - start, at: time)
            } else {
                out += decide(fingers: fingers, elapsed: time - start, downIDs: downIDs, at: time)
            }

        case .pointer(let id, let clickCount, let last):
            if let p = lifted[id] ?? (down[id] == nil ? last : nil) {
                out.append(.mouseUp(.left, p, clickCount: clickCount))
                lastClick = (time, p, clickCount)
                state = .waitLift
            } else if let p = down[id], p != last {
                out.append(.mouseDragged(.left, p))
                state = .pointer(id: id, clickCount: clickCount, last: p)
            }

        case .scroll(let ids, let last, var samples):
            if ids.contains(where: { down[$0] == nil }) {
                out.append(.scroll(dx: 0, dy: 0, phase: .ended))
                if let v = velocity(samples), hypot(v.dx, v.dy) >= configuration.momentumMinimumSpeed {
                    momentum = Momentum(vx: v.dx, vy: v.dy, time: time)
                    out.append(.momentum(dx: 0, dy: 0, phase: .began))
                }
                state = .waitLift
            } else {
                let c = centroid(ids.map { down[$0]! })
                samples = trimmed(samples + [Sample(time: time, point: c)], now: time)
                if c != last { out.append(.scroll(dx: c.x - last.x, dy: c.y - last.y, phase: .changed)) }
                state = .scroll(ids: ids, last: c, samples: samples)
            }

        case .transform(let a, let b, let commitDistance, let commitAngle, let lastDistance, let lastAngle,
                        var magnifying, var rotating):
            guard let pa = down[a], let pb = down[b] else {
                if magnifying { out.append(.magnify(0, phase: .ended)) }
                if rotating { out.append(.rotate(degrees: 0, phase: .ended)) }
                state = .waitLift
                break
            }
            let d = distance(pa, pb)
            // 指間距太小時角度不可靠：沿用上一個角度（不送旋轉）
            let angleUsable = d >= configuration.rotationMinimumDistance
            let angle = angleUsable ? self.angle(pa, pb) : lastAngle
            let factor = configuration.secondaryTransformFactor
            if lastDistance > 0 {
                let m = d / lastDistance - 1
                if magnifying {
                    if m != 0 { out.append(.magnify(m, phase: .changed)) }
                } else if abs(d - commitDistance) >= configuration.pinchThreshold * factor {
                    magnifying = true
                    out.append(.magnify(m, phase: .began))
                }
            }
            let turn = -normalizedDegrees(angle - lastAngle)
            if rotating {
                if turn != 0 { out.append(.rotate(degrees: turn, phase: .changed)) }
            } else if angleUsable, abs(normalizedDegrees(angle - commitAngle)) >= configuration.rotationThreshold * factor {
                rotating = true
                out.append(.rotate(degrees: turn, phase: .began))
            }
            state = .transform(a: a, b: b, commitDistance: commitDistance, commitAngle: commitAngle,
                               lastDistance: d, lastAngle: angle, magnifying: magnifying, rotating: rotating)

        case .swipe(let axis, let ids, let origin, let lastProgress, var samples):
            let positions = ids.compactMap { down[$0] ?? lifted[$0] }
            let c = centroid(positions)
            samples = trimmed(samples + [Sample(time: time, point: c)], now: time)
            let progress = swipeProgress(axis, from: origin, to: c)
            if ids.contains(where: { down[$0] == nil }) {
                let v = velocity(samples).map { (axis == .horizontal ? $0.dx : $0.dy) / configuration.swipeDistance } ?? 0
                out.append(.swipe(axis, progress: progress, velocity: v, fingers: ids.count, phase: .ended))
                state = .waitLift
            } else {
                if progress != lastProgress {
                    out.append(.swipe(axis, progress: progress, velocity: 0, fingers: ids.count, phase: .changed))
                }
                state = .swipe(axis: axis, ids: ids, origin: origin, lastProgress: progress, samples: samples)
            }

        case .waitLift:
            break
        }

        if down.isEmpty, case .waitLift = state { endSequence() }
        if down.isEmpty, case .pending = state { endSequence() }
        return out
    }

    /// 長按與慣性捲動需要的計時（建議 60–125 Hz 呼叫，`needsTick` 為 true 時）
    public mutating func tick(at time: Double) -> [GestureEvent] {
        var out: [GestureEvent] = []
        if case .pending(let start, let fingers) = state, fingers == 1, down.count == 1,
           time - start >= configuration.longPressDuration, maxMovement <= configuration.tapSlop,
           let p = down.values.first {
            out.append(.mouseDown(.right, p, clickCount: 1))
            out.append(.mouseUp(.right, p, clickCount: 1))
            state = .waitLift
        }
        if var m = momentum {
            let dt = time - m.time
            if dt > 0 {
                let decay = exp(-configuration.momentumFriction * dt)
                // 這段時間的位移 = 速度對時間積分
                let factor = (1 - decay) / configuration.momentumFriction
                let dx = m.vx * factor
                let dy = m.vy * factor
                m.vx *= decay
                m.vy *= decay
                m.time = time
                if hypot(m.vx, m.vy) < configuration.momentumStopSpeed {
                    out.append(.momentum(dx: dx, dy: dy, phase: .ended))
                    momentum = nil
                } else {
                    out.append(.momentum(dx: dx, dy: dy, phase: .changed))
                    momentum = m
                }
            }
        }
        return out
    }

    /// 取消進行中的手勢（例如裝置移除、前景 App 被排除）：按住的滑鼠鍵會放開、連續手勢以 cancelled／ended 結束
    public mutating func reset() -> [GestureEvent] {
        var out: [GestureEvent] = []
        switch state {
        case .pointer(_, let clickCount, let last):
            out.append(.mouseUp(.left, last, clickCount: clickCount))
        case .scroll:
            out.append(.scroll(dx: 0, dy: 0, phase: .cancelled))
        case .transform(_, _, _, _, _, _, let magnifying, let rotating):
            if magnifying { out.append(.magnify(0, phase: .cancelled)) }
            if rotating { out.append(.rotate(degrees: 0, phase: .cancelled)) }
        case .swipe(let axis, let ids, _, let progress, _):
            out.append(.swipe(axis, progress: progress, velocity: 0, fingers: ids.count, phase: .cancelled))
        case .idle, .pending, .waitLift:
            break
        }
        if momentum != nil {
            out.append(.momentum(dx: 0, dy: 0, phase: .ended))
            momentum = nil
        }
        down.removeAll()
        endSequence()
        return out
    }

    // MARK: - 決定手勢

    private mutating func tap(fingers: Int, duration: Double, at time: Double) -> [GestureEvent] {
        let points = order.compactMap { starts[$0] }
        guard maxMovement <= configuration.tapSlop, let first = points.first else { return [] }
        switch fingers {
        case 1:
            let n = clickCount(at: first, time: time)
            lastClick = (time, first, n)
            return [.mouseDown(.left, first, clickCount: n), .mouseUp(.left, first, clickCount: n)]
        case 2 where duration <= configuration.twoFingerTapMaxDuration:
            let c = centroid(Array(points.prefix(2)))
            return [.mouseDown(.right, c, clickCount: 1), .mouseUp(.right, c, clickCount: 1)]
        default:
            return []
        }
    }

    private mutating func decide(fingers: Int, elapsed: Double, downIDs: [UInt64], at time: Double) -> [GestureEvent] {
        guard elapsed >= configuration.settleDuration else { return [] }
        if fingers == 1 {
            guard let id = downIDs.first, let start = starts[id], let p = down[id],
                  distance(start, p) > configuration.tapSlop else { return [] }
            let n = clickCount(at: start, time: time)
            state = .pointer(id: id, clickCount: n, last: p)
            return [.mouseDown(.left, start, clickCount: n), .mouseDragged(.left, p)]
        }
        if fingers == 2 {
            guard downIDs.count >= 2 else { return [] }
            let (a, b) = (downIDs[0], downIDs[1])
            let (sa, sb, pa, pb) = (starts[a]!, starts[b]!, down[a]!, down[b]!)
            let c0 = centroid([sa, sb])
            let c1 = centroid([pa, pb])
            // 兩指運動拆成：重心平移（捲動）與指間向量的變化（縮放＋旋轉）
            let move = distance(c0, c1)
            let relative = hypot((pb.x - pa.x) - (sb.x - sa.x), (pb.y - pa.y) - (sb.y - sa.y))
            if move >= configuration.scrollThreshold && relative < move * configuration.scrollMaximumRelativeMotion {
                state = .scroll(ids: [a, b], last: c1, samples: history(of: [a, b], now: time))
                return [.pointer(c0), .scroll(dx: c1.x - c0.x, dy: c1.y - c0.y, phase: .began)]
            }
            let (d0, d1) = (distance(sa, sb), distance(pa, pb))
            let stretch = abs(d1 - d0)
            let angleUsable = min(d0, d1) >= configuration.rotationMinimumDistance
            let turnDegrees = angleUsable ? normalizedDegrees(angle(pa, pb) - angle(sa, sb)) : 0
            // 旋轉造成的切向位移，與開合的徑向位移比較誰是主要動作
            let arc = min(d0, d1) * abs(turnDegrees) * .pi / 180
            let magnifying = stretch >= configuration.pinchThreshold && stretch >= arc
            let rotating = !magnifying && abs(turnDegrees) >= configuration.rotationThreshold
            guard magnifying || rotating else { return [] }
            var out: [GestureEvent] = [.pointer(c0)]
            if magnifying { out.append(.magnify(d1 / d0 - 1, phase: .began)) }
            if rotating { out.append(.rotate(degrees: -turnDegrees, phase: .began)) }
            state = .transform(a: a, b: b, commitDistance: d1, commitAngle: angle(pa, pb),
                               lastDistance: d1, lastAngle: angle(pa, pb), magnifying: magnifying, rotating: rotating)
            return out
        }
        // 三指以上
        guard downIDs.count >= 3 else { return [] }
        let ids = downIDs
        let c0 = centroid(ids.map { starts[$0]! })
        let c1 = centroid(ids.map { down[$0]! })
        guard distance(c0, c1) >= configuration.swipeThreshold else { return [] }
        let axis: SwipeAxis = abs(c1.x - c0.x) >= abs(c1.y - c0.y) ? .horizontal : .vertical
        let progress = swipeProgress(axis, from: c0, to: c1)
        state = .swipe(axis: axis, ids: ids, origin: c0, lastProgress: progress, samples: history(of: ids, now: time))
        return [.swipe(axis, progress: progress, velocity: 0, fingers: ids.count, phase: .began)]
    }

    private func clickCount(at point: CGPoint, time: Double) -> Int {
        guard let last = lastClick, time - last.time <= configuration.doubleClickInterval,
              distance(last.point, point) <= configuration.doubleClickDistance else { return 1 }
        return min(last.count + 1, 3)
    }

    private mutating func endSequence() {
        state = .idle
        starts.removeAll()
        order.removeAll()
        maxMovement = 0
        pendingHistory.removeAll()
    }

    /// 手勢決定前這些手指的重心軌跡（計算速度用）
    private func history(of ids: [UInt64], now: Double) -> [Sample] {
        let samples = pendingHistory.compactMap { entry -> Sample? in
            let points = ids.compactMap { entry.points[$0] }
            return points.count == ids.count ? Sample(time: entry.time, point: centroid(points)) : nil
        }
        return trimmed(samples, now: now)
    }

    // MARK: - 幾何

    private func swipeProgress(_ axis: SwipeAxis, from a: CGPoint, to b: CGPoint) -> Double {
        (axis == .horizontal ? b.x - a.x : b.y - a.y) / configuration.swipeDistance
    }

    private func trimmed(_ samples: [Sample], now: Double) -> [Sample] {
        // 保留視窗內的樣本，再多留一個視窗外的當作起點
        guard let firstInside = samples.firstIndex(where: { now - $0.time <= configuration.velocityWindow }) else { return samples }
        return Array(samples[max(0, firstInside - 1)...])
    }

    private func velocity(_ samples: [Sample]) -> (dx: Double, dy: Double)? {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return nil }
        let dt = last.time - first.time
        return ((last.point.x - first.point.x) / dt, (last.point.y - first.point.y) / dt)
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let n = Double(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(b.x - a.x, b.y - a.y) }

    /// Quartz 座標（y 向下）中 a→b 的角度（度）
    private func angle(_ a: CGPoint, _ b: CGPoint) -> Double { atan2(b.y - a.y, b.x - a.x) * 180 / .pi }

    private func normalizedDegrees(_ d: Double) -> Double {
        var v = d.truncatingRemainder(dividingBy: 360)
        if v > 180 { v -= 360 }
        if v < -180 { v += 360 }
        return v
    }
}
