import Foundation

/// 產生模擬觸控 frame，用於沒有觸控螢幕時開發與測試（mtk-server --simulate、mtk-viewer --simulate）。
///
/// 模式（`Pattern`）：
/// - `.drums`（預設）：一指持續畫圓、一指每 2 秒滑動 1 秒、下方四個「鼓面」位置每 0.25 秒輪流點擊一次（每次按 40 ms）。
/// - `.gestures`：每 12 秒依序做出點擊、雙擊、長按、兩指點擊、兩指甩動捲動、捏合、旋轉、三指左滑、四指上滑、一指拖曳，
///   用來驗證手勢辨識（mtk-server --simulate-pattern gestures）。
public final class SimulatedTouchSource: @unchecked Sendable {
    /// 模擬來源的 `TouchFrame.deviceID`（實體裝置從 1 開始，不會衝突）
    public static let deviceID = 0

    /// rawValue 即 mtk-server --simulate-pattern 的值
    public enum Pattern: String, Sendable, CaseIterable {
        case drums
        case gestures
    }

    /// 每秒產生的 frame 數（預設 125，與 ILITEK 相同）
    public let rate: Double
    /// 模擬的動作
    public let pattern: Pattern
    /// `frameHandler` 執行的序列佇列
    public let queue: DispatchQueue
    /// 在 `queue` 上呼叫；任何執行緒皆可設定
    public var frameHandler: (@Sendable (TouchFrame) -> Void)? {
        get { _frameHandler.wrapped }
        set { _frameHandler.wrapped = newValue }
    }

    private let _frameHandler = Locked<(@Sendable (TouchFrame) -> Void)?>(nil)

    private var timer: DispatchSourceTimer?
    private var tracker = ContactTracker()
    private var nextTouchID: UInt64 = 1
    private var sequence: UInt64 = 0
    private var startTime: UInt64 = 0
    private let queueKey = DispatchSpecificKey<UInt8>()

    /// - Parameters:
    ///   - rate: 每秒 frame 數
    ///   - pattern: 模擬的動作
    ///   - queue: `frameHandler` 執行的序列佇列；預設建立新的 userInteractive 佇列
    public init(rate: Double = 125, pattern: Pattern = .drums,
                queue: DispatchQueue = DispatchQueue(label: "MultiTouchKit.simulated", qos: .userInteractive)) {
        self.rate = rate
        self.pattern = pattern
        self.queue = queue
        queue.setSpecific(key: queueKey, value: 1)
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() } else { queue.sync(execute: body) }
    }

    /// 面板實體尺寸沿用 ILITEK（MF156LR）HID 描述子的值，讓 DisplaySelector 的 auto 在模擬時也選到同一台顯示器
    public static var deviceInfo: MultiTouchDeviceInfo {
        MultiTouchDeviceInfo(id: deviceID, vendorID: 0, productID: 0, manufacturer: "MultiTouchKit",
                             product: "Simulated Touch Screen", serialNumber: "", locationID: 0,
                             maxContacts: 10, slotsPerReport: 10, physicalWidthMillimeters: 309.3,
                             physicalHeightMillimeters: 173.9, hasScanTime: false, exclusive: false)
    }

    /// 開始產生 frame（已在執行時不做任何事）；任何執行緒皆可呼叫
    public func start() {
        onQueue {
            guard timer == nil else { return }
            startTime = MultiTouchClock.now()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: 1 / rate, leeway: .microseconds(200))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    /// 停止；仍在「螢幕上」的模擬觸點以 cancelled 送出
    public func stop() {
        onQueue {
            timer?.cancel()
            timer = nil
            emit(tracker.cancelAll(), at: MultiTouchClock.now())
        }
    }

    private func tick() {
        let now = MultiTouchClock.now()
        let t = Double(now - startTime) / 1e9
        var contacts: [RawContact] = []
        func contact(_ id: Int, _ x: Double, _ y: Double) {
            contacts.append(RawContact(contactID: id, tip: true, x: x, y: y,
                                       rawX: Int(x * 9600), rawY: Int(y * 9600)))
        }
        switch pattern {
        case .drums:
            contact(0, 0.3 + 0.15 * cos(t * .pi / 2), 0.4 + 0.15 * sin(t * .pi / 2))
            if t.truncatingRemainder(dividingBy: 2) < 1 {
                contact(1, 0.6 + 0.2 * t.truncatingRemainder(dividingBy: 1), 0.3)
            }
            let beat = Int(t / 0.25)
            if t - Double(beat) * 0.25 < 0.04 {
                let lane = beat % 4
                contact(2 + lane, 0.2 + 0.2 * Double(lane), 0.8)
            }
        case .gestures:
            for c in Self.gestureScript(at: t.truncatingRemainder(dividingBy: 12)) { contact(c.id, c.x, c.y) }
        }
        emit(tracker.update(contacts) {
            defer { nextTouchID += 1 }
            return nextTouchID
        }, at: now)
    }

    /// `.gestures` 模式在週期內時間 t（秒）的觸點
    static func gestureScript(at t: Double) -> [(id: Int, x: Double, y: Double)] {
        func during(_ a: Double, _ b: Double) -> Double? { t >= a && t < b ? (t - a) / (b - a) : nil }
        if during(0.0, 0.08) != nil { return [(0, 0.2, 0.3)] }                                  // 點擊
        if during(0.5, 0.56) != nil || during(0.7, 0.76) != nil { return [(0, 0.3, 0.3)] }     // 雙擊
        if during(1.2, 2.0) != nil { return [(0, 0.4, 0.3)] }                                   // 長按（右鍵）
        if during(2.5, 2.6) != nil { return [(0, 0.5, 0.5), (1, 0.6, 0.5)] }                    // 兩指點擊（右鍵）
        if let k = during(3.0, 3.1) { return [(0, 0.45, 0.3 + 0.2 * k), (1, 0.55, 0.3 + 0.2 * k)] } // 兩指往下甩（捲動＋慣性）
        if let k = during(4.5, 5.3) { let r = 0.05 + 0.1 * k; return [(0, 0.5 - r, 0.5), (1, 0.5 + r, 0.5)] } // 捏合放大
        if let k = during(6.0, 6.8) {                                                           // 逆時針旋轉 60°
            let a = -k * .pi / 3, r = 0.08
            return [(0, 0.5 - r * cos(a), 0.5 - r * sin(a) * 16 / 9), (1, 0.5 + r * cos(a), 0.5 + r * sin(a) * 16 / 9)]
        }
        if let k = during(7.5, 8.0) { return (0..<3).map { ($0, 0.5 + 0.06 * Double($0) - 0.3 * k, 0.5) } } // 三指左滑
        if let k = during(9.0, 9.6) { return (0..<4).map { ($0, 0.4 + 0.06 * Double($0), 0.7 - 0.4 * k) } }  // 四指上滑
        if let k = during(10.0, 10.6) { return [(0, 0.2 + 0.3 * k, 0.7)] }                      // 一指拖曳
        return []
    }

    private func emit(_ touches: [Touch], at timestamp: UInt64) {
        guard !touches.isEmpty else { return }
        sequence += 1
        frameHandler?(TouchFrame(deviceID: Self.deviceID, sequence: sequence, timestamp: timestamp,
                                 scanTime: nil, touches: touches))
    }
}
