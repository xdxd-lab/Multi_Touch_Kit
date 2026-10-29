import Foundation

/// 校正工具收集點擊的邏輯（mtk-viewer --calibrate）：9 個十字同時顯示，使用者任意點擊，
/// 靠近某個十字的觸碰就視為想按那個十字，持續累積；隨時可以取得目前的擬合結果。
///
/// - 一次點擊的位置：按住期間（略過落下後的頭 40 ms，手指剛接觸時位置還不穩）各 frame 位置的逐軸中位數。
/// - 歸屬：與十字的距離（以面板長寬比換算成同一單位）在 `captureRadius` 內，取最近的十字；否則記為忽略。
/// - 每個十字的量測值：所有點擊的逐軸中位數（不受單次誤觸影響）。
/// 使用校正前的座標（`Touch.uncalibratedX`，沒有時為 x），所以已套用舊校正時也能重新校正。
public struct TouchCalibrationCollector: Sendable {
    /// 3 × 3 的十字：10%、50%、90%
    public static let standardTargets: [TouchCalibration.Point] =
        [0.1, 0.5, 0.9].flatMap { y in [0.1, 0.5, 0.9].map { TouchCalibration.Point(x: $0, y: y) } }

    /// 一次點擊的結果（給畫面顯示）
    public struct Tap: Sendable, Equatable {
        public var position: TouchCalibration.Point
        /// 歸給的十字；nil = 離所有十字都太遠，不採用
        public var target: Int?
    }

    public let targets: [TouchCalibration.Point]
    /// 歸屬半徑（以面板寬度為 1 的距離）
    public var captureRadius: Double
    /// 面板實體尺寸（mm）；用來換算距離與誤差。未知時視為 16:9、寬 310 mm
    public let panelWidth: Double
    public let panelHeight: Double
    /// 每個十字收集到的點擊位置
    public private(set) var taps: [[TouchCalibration.Point]]
    /// 離所有十字都太遠而未採用的點擊數
    public private(set) var ignored = 0
    private var pressing: [UInt64: (start: UInt64, positions: [TouchCalibration.Point])] = [:]
    private static let settleNanoseconds: UInt64 = 40_000_000

    public init(targets: [TouchCalibration.Point] = TouchCalibrationCollector.standardTargets, captureRadius: Double = 0.08,
                panelWidthMillimeters: Double? = nil, panelHeightMillimeters: Double? = nil) {
        self.targets = targets
        self.captureRadius = captureRadius
        panelWidth = panelWidthMillimeters ?? 310
        panelHeight = panelHeightMillimeters ?? 310 * 9 / 16
        taps = Array(repeating: [], count: targets.count)
    }

    /// 處理一個 frame；回傳這個 frame 結束的點擊
    @discardableResult
    public mutating func process(_ frame: TouchFrame) -> [Tap] {
        var finished: [Tap] = []
        for touch in frame.touches {
            let position = TouchCalibration.Point(x: touch.uncalibratedX ?? touch.x, y: touch.uncalibratedY ?? touch.y)
            switch touch.phase {
            case .began:
                pressing[touch.id] = (frame.timestamp, [position])
            case .moved, .stationary:
                pressing[touch.id]?.positions.append(position)
            case .ended:
                guard var press = pressing.removeValue(forKey: touch.id) else { continue }
                press.positions.append(position)
                let tap = settle(press, end: frame.timestamp)
                finished.append(record(tap))
            case .cancelled:
                // 誤觸（stale）或裝置中斷：不是使用者刻意的點擊
                pressing[touch.id] = nil
            }
        }
        return finished
    }

    /// 按住期間的代表位置：略過頭 40 ms 後的逐軸中位數（按太短時用全部）
    private func settle(_ press: (start: UInt64, positions: [TouchCalibration.Point]), end: UInt64) -> TouchCalibration.Point {
        // frame 時間不在 positions 中：以均勻間隔估計各位置的時間
        let count = press.positions.count
        let duration = Double(end &- press.start)
        let skip = duration > 0 ? Int((Double(Self.settleNanoseconds) / duration * Double(count)).rounded(.up)) : 0
        let stable = skip < count ? Array(press.positions[skip...]) : press.positions
        return Self.median(stable)
    }

    private mutating func record(_ position: TouchCalibration.Point) -> Tap {
        guard let index = nearestTarget(to: position) else {
            ignored += 1
            return Tap(position: position, target: nil)
        }
        taps[index].append(position)
        return Tap(position: position, target: index)
    }

    /// 以面板寬度為 1 的距離（y 依長寬比換算），在歸屬半徑內的最近十字
    public func nearestTarget(to p: TouchCalibration.Point) -> Int? {
        let ratio = panelHeight / panelWidth
        let distances = targets.map { hypot($0.x - p.x, ($0.y - p.y) * ratio) }
        guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }), distances[best] <= captureRadius else { return nil }
        return best
    }

    /// 有點擊的十字：量測值為點擊的逐軸中位數（`TouchCalibration.Sample.count` 為點擊數）
    public var samples: [TouchCalibration.Sample] {
        targets.indices.compactMap { i in
            taps[i].isEmpty ? nil : TouchCalibration.Sample(target: targets[i], measured: Self.median(taps[i]), count: taps[i].count)
        }
    }

    /// 目前的擬合結果（至少 3 個十字有點擊）
    public var fit: TouchCalibration.Fit? { TouchCalibration.fit(samples) }

    /// 平均誤差（mm）：校正前（量測值與十字的距離）、校正後（擬合殘差）
    public func meanErrors(_ fit: TouchCalibration.Fit?) -> (before: Double, after: Double?) {
        let samples = samples
        guard !samples.isEmpty else { return (0, nil) }
        func mm(_ dx: Double, _ dy: Double) -> Double { hypot(dx * panelWidth, dy * panelHeight) }
        let before = samples.map { mm($0.measured.x - $0.target.x, $0.measured.y - $0.target.y) }.reduce(0, +) / Double(samples.count)
        guard let fit else { return (before, nil) }
        let after = samples.map { s -> Double in
            let p = fit.calibration.apply(x: s.measured.x, y: s.measured.y)
            return mm(p.x - s.target.x, p.y - s.target.y)
        }.reduce(0, +) / Double(samples.count)
        return (before, after)
    }

    /// 某個十字的殘差（mm）；沒有點擊或沒有擬合時為 nil
    public func residualMillimeters(target index: Int, fit: TouchCalibration.Fit?) -> Double? {
        guard let fit, !taps[index].isEmpty else { return nil }
        let m = Self.median(taps[index])
        let p = fit.calibration.apply(x: m.x, y: m.y)
        return hypot((p.x - targets[index].x) * panelWidth, (p.y - targets[index].y) * panelHeight)
    }

    /// 清除所有點擊（重來）
    public mutating func reset() {
        taps = Array(repeating: [], count: targets.count)
        ignored = 0
        pressing.removeAll()
    }

    static func median(_ points: [TouchCalibration.Point]) -> TouchCalibration.Point {
        func m(_ v: [Double]) -> Double {
            let s = v.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        return TouchCalibration.Point(x: m(points.map(\.x)), y: m(points.map(\.y)))
    }
}
