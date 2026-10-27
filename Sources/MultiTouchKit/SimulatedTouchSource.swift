import Foundation

/// 產生模擬觸控 frame，用於沒有觸控螢幕時開發與測試（mtk-server --simulate、mtk-viewer --simulate）。
///
/// 模式：一指持續畫圓、一指每 2 秒滑動 1 秒、下方四個「鼓面」位置每 0.25 秒輪流點擊一次（每次按 40 ms）。
public final class SimulatedTouchSource: @unchecked Sendable {
    public static let deviceID = 0

    public let rate: Double
    public let queue: DispatchQueue
    /// 在 `queue` 上呼叫
    public var frameHandler: (@Sendable (TouchFrame) -> Void)?

    private var timer: DispatchSourceTimer?
    private var tracker = ContactTracker()
    private var nextTouchID: UInt64 = 1
    private var sequence: UInt64 = 0
    private var startTime: UInt64 = 0
    private let queueKey = DispatchSpecificKey<UInt8>()

    public init(rate: Double = 125, queue: DispatchQueue = DispatchQueue(label: "MultiTouchKit.simulated", qos: .userInteractive)) {
        self.rate = rate
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
        contact(0, 0.3 + 0.15 * cos(t * .pi / 2), 0.4 + 0.15 * sin(t * .pi / 2))
        if t.truncatingRemainder(dividingBy: 2) < 1 {
            contact(1, 0.6 + 0.2 * t.truncatingRemainder(dividingBy: 1), 0.3)
        }
        let beat = Int(t / 0.25)
        if t - Double(beat) * 0.25 < 0.04 {
            let lane = beat % 4
            contact(2 + lane, 0.2 + 0.2 * Double(lane), 0.8)
        }
        emit(tracker.update(contacts) {
            defer { nextTouchID += 1 }
            return nextTouchID
        }, at: now)
    }

    private func emit(_ touches: [Touch], at timestamp: UInt64) {
        guard !touches.isEmpty else { return }
        sequence += 1
        frameHandler?(TouchFrame(deviceID: Self.deviceID, sequence: sequence, timestamp: timestamp,
                                 scanTime: nil, touches: touches))
    }
}
