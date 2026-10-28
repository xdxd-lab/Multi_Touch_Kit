// C API 實作（宣告見 Sources/CMultiTouchKit/include/multitouchkit.h）。
// 建置成 libMultiTouchKitC.dylib；Unity 外掛由 scripts/build-unity-plugin.sh 包成 MultiTouchKit.bundle。
import AppKit
import CMultiTouchKit
import Foundation
import MultiTouchKit

/// 整個程序共用一份的 C API 狀態
final class CRuntime: @unchecked Sendable {
    static let shared = CRuntime()

    /// 資料鎖：佇列、回呼指標、log。持有時間很短，frameHandler 也會取得
    private let lock = NSLock()
    /// 序列化 start／stop：兩個執行緒同時 mtk_start 時，不會留下沒被停止、仍獨占裝置的 manager
    private let lifecycleLock = NSLock()
    /// 呼叫回呼期間持有：`setCallback` 取得同一把鎖，所以返回後保證不會再以舊的 callback／user_data 呼叫。
    /// 可重入：回呼內呼叫 mtk_set_event_callback（同一執行緒）不會死結
    private let callbackLock = NSRecursiveLock()
    private var manager: MultiTouchManager?
    /// 溢位時以重新同步保證狀態一致的佇列（見 TouchEventQueue）
    private var queue = TouchEventQueue<MTKTouchEvent>(capacity: 4096)
    private var reportedResyncs: UInt64 = 0
    private var reportStationary = false
    private var callback: MTKEventCallback?
    private var callbackUserData: UnsafeMutableRawPointer?
    private var logs: [String] = []
    private static let maxLogs = 128

    var isRunning: Bool { lock.withLock { manager != nil } }
    var droppedCount: UInt64 { lock.withLock { queue.dropped } }
    var devices: [MultiTouchDeviceInfo] { lock.withLock { manager?.connectedDevices ?? [] } }
    /// 裝置清單每次改變（start、stop、加入、移除、重新初始化）就加 1：TouchDisplay 以它判斷快取是否過期，
    /// 不必每個觸點都複製並比較整份裝置清單
    var deviceGeneration: UInt64 { lock.withLock { _deviceGeneration } }
    private var _deviceGeneration: UInt64 = 0

    private func bumpDeviceGeneration() {
        lock.withLock { _deviceGeneration &+= 1 }
    }

    func start(_ config: MTKConfig) -> Int32 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopLocked()
        var configuration = MultiTouchManager.Configuration()
        configuration.vendorID = config.vendor_id != 0 ? Int(config.vendor_id) : nil
        configuration.productID = config.product_id != 0 ? Int(config.product_id) : nil
        configuration.exclusive = config.exclusive != 0
        configuration.initializeMultiTouchMode = config.init_multitouch != 0
        // 0 = 預設（MultiTouchManager.Configuration 的 30 秒）、< 0 = 關閉
        if config.stale_timeout_ms < 0 {
            configuration.staleTouchTimeout = 0
        } else if config.stale_timeout_ms > 0 {
            configuration.staleTouchTimeout = Double(config.stale_timeout_ms) / 1000
        }
        let capacity = config.queue_capacity > 0 ? Int(config.queue_capacity) : 4096
        lock.withLock {
            queue = TouchEventQueue(capacity: capacity)
            reportedResyncs = 0
            reportStationary = config.report_stationary != 0
        }
        let manager = MultiTouchManager(configuration: configuration)
        manager.logHandler = { [weak self] in self?.appendLog($0) }
        manager.deviceHandler = { [weak self] _ in self?.bumpDeviceGeneration() }
        let includeStationary = config.report_stationary != 0
        manager.frameHandler = { [weak self] in self?.enqueue($0, includeStationary: includeStationary) }
        do {
            try manager.start()
        } catch {
            appendLog("[MultiTouchKit] 啟動失敗：\(error)")
            return MTK_ERR_START_FAILED
        }
        lock.withLock { self.manager = manager }
        bumpDeviceGeneration()
        return MTK_OK
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        let current = lock.withLock { () -> MultiTouchManager? in
            defer { manager = nil }
            return manager
        }
        current?.stop()
        bumpDeviceGeneration()
    }

    /// 進行中的回呼結束後才返回（在回呼內呼叫時直接生效）
    func setCallback(_ callback: MTKEventCallback?, _ userData: UnsafeMutableRawPointer?) {
        callbackLock.withLock {
            lock.withLock {
                self.callback = callback
                callbackUserData = userData
            }
        }
    }

    func poll(into buffer: UnsafeMutablePointer<MTKTouchEvent>, capacity: Int) -> Int {
        let (count, note) = lock.withLock { () -> (Int, String?) in
            // 在鎖內直接寫入呼叫者的 buffer，不配置中介陣列
            let count = queue.pop(into: UnsafeMutableBufferPointer(start: buffer, count: capacity))
            var note: String?
            if queue.resyncs != reportedResyncs {
                reportedResyncs = queue.resyncs
                note = "[MultiTouchKit] 事件佇列已重新同步（累計丟棄 \(queue.dropped) 筆過時事件；"
                    + "通常是程式暫停輪詢，例如 Unity 失去焦點），已依目前觸點狀態補送 began／moved／cancelled"
            }
            return (count, note)
        }
        if let note { appendLog(note) }
        return count
    }

    func requestResync() {
        lock.withLock { queue.requestResync() }
    }

    func appendLog(_ message: String) {
        lock.withLock {
            if logs.count >= Self.maxLogs { logs.removeFirst() }
            logs.append(message)
        }
    }

    func popLog() -> String? {
        lock.withLock { logs.isEmpty ? nil : logs.removeFirst() }
    }

    /// 測試用：清空佇列並設定容量（不啟動裝置）
    func resetForTesting(capacity: Int = 4096, reportStationary: Bool = false) {
        lock.withLock {
            queue = TouchEventQueue(capacity: capacity)
            reportedResyncs = 0
            self.reportStationary = reportStationary
            logs.removeAll()
        }
    }

    /// MultiTouchManager 的 frameHandler（在 HID 佇列上）；測試也直接呼叫。
    /// - Parameter includeStationary: start 時決定並由 frameHandler 帶入，省去每 frame 一次加鎖；nil 時讀目前設定（測試）
    func enqueue(_ frame: TouchFrame, includeStationary: Bool? = nil) {
        let includeStationary = includeStationary ?? lock.withLock { reportStationary }
        // 事件先寫進堆疊上的暫存空間（最多約 10 個），不配置陣列
        withUnsafeTemporaryAllocation(of: MTKTouchEvent.self, capacity: max(frame.touches.count, 1)) { storage in
            var count = 0
            for t in frame.touches where includeStationary || t.phase != .stationary {
                storage[count] = Self.event(t, in: frame)
                count += 1
            }
            guard count > 0 else { return }
            dispatch(UnsafeBufferPointer(rebasing: storage[..<count]))
        }
    }

    private static func event(_ t: Touch, in frame: TouchFrame) -> MTKTouchEvent {
        var flags: UInt32 = 0
        if t.pressure != nil { flags |= MTK_FLAG_HAS_PRESSURE }
        if t.width != nil || t.height != nil { flags |= MTK_FLAG_HAS_SIZE }
        if let confident = t.confidence {
            flags |= MTK_FLAG_HAS_CONFIDENCE
            if !confident { flags |= MTK_FLAG_LOW_CONFIDENCE }
        }
        return MTKTouchEvent(
            touch_id: t.id, timestamp_ns: frame.timestamp,
            device_id: Int32(frame.deviceID), contact_id: Int32(truncatingIfNeeded: t.contactID),
            phase: Int32(t.phase.rawValue), x: Float(t.x), y: Float(t.y),
            pressure: t.pressure.map { Float($0) } ?? -1,
            width: t.width.map { Float($0) } ?? -1,
            height: t.height.map { Float($0) } ?? -1,
            frame_seq: UInt32(truncatingIfNeeded: frame.sequence), flags: flags)
    }

    private func dispatch(_ events: UnsafeBufferPointer<MTKTouchEvent>) {
        // 先取得回呼鎖再讀回呼指標，並持有到回呼返回：setCallback 因此會等待進行中的回呼
        callbackLock.lock()
        defer { callbackLock.unlock() }
        let (callback, userData) = lock.withLock { () -> (MTKEventCallback?, UnsafeMutableRawPointer?) in
            for e in events { queue.push(e) }
            return (self.callback, callbackUserData)
        }
        callback?(events.baseAddress, Int32(events.count), userData)
    }

}

nonisolated(unsafe) private let versionCString: UnsafeMutablePointer<CChar> = strdup(MultiTouchKitVersion.string)!

@_cdecl("mtk_api_version")
public func mtkAPIVersion() -> Int32 { MTK_API_VERSION }

@_cdecl("mtk_version")
public func mtkVersion() -> UnsafePointer<CChar> { UnsafePointer(versionCString) }

@_cdecl("mtk_default_config")
public func mtkDefaultConfig(_ config: UnsafeMutablePointer<MTKConfig>?) {
    guard let config else { return }
    config.pointee = MTKConfig(struct_size: Int32(MemoryLayout<MTKConfig>.size), vendor_id: 0, product_id: 0,
                               exclusive: 1, init_multitouch: 1, report_stationary: 0, queue_capacity: 0, stale_timeout_ms: 0)
}

@_cdecl("mtk_start")
public func mtkStart(_ config: UnsafePointer<MTKConfig>?) -> Int32 {
    var resolved = MTKConfig()
    mtkDefaultConfig(&resolved)
    if let config {
        guard config.pointee.struct_size >= Int32(MemoryLayout<MTKConfig>.size) else { return MTK_ERR_INVALID_ARGUMENT }
        resolved = config.pointee
    }
    return CRuntime.shared.start(resolved)
}

@_cdecl("mtk_stop")
public func mtkStop() { CRuntime.shared.stop() }

@_cdecl("mtk_is_running")
public func mtkIsRunning() -> Int32 { CRuntime.shared.isRunning ? 1 : 0 }

@_cdecl("mtk_poll_events")
public func mtkPollEvents(_ buffer: UnsafeMutablePointer<MTKTouchEvent>?, _ capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return 0 }
    return Int32(CRuntime.shared.poll(into: buffer, capacity: Int(capacity)))
}

@_cdecl("mtk_request_resync")
public func mtkRequestResync() { CRuntime.shared.requestResync() }

@_cdecl("mtk_dropped_event_count")
public func mtkDroppedEventCount() -> UInt64 { CRuntime.shared.droppedCount }

@_cdecl("mtk_set_event_callback")
public func mtkSetEventCallback(_ callback: MTKEventCallback?, _ userData: UnsafeMutableRawPointer?) {
    CRuntime.shared.setCallback(callback, userData)
}

@_cdecl("mtk_device_count")
public func mtkDeviceCount() -> Int32 { Int32(CRuntime.shared.devices.count) }

@_cdecl("mtk_get_device_info")
public func mtkGetDeviceInfo(_ index: Int32, _ info: UnsafeMutablePointer<MTKDeviceInfo>?) -> Int32 {
    guard let info else { return MTK_ERR_INVALID_ARGUMENT }
    let devices = CRuntime.shared.devices
    guard index >= 0, Int(index) < devices.count else { return MTK_ERR_OUT_OF_RANGE }
    let d = devices[Int(index)]
    var out = MTKDeviceInfo()
    out.device_id = Int32(d.id)
    out.vendor_id = Int32(d.vendorID)
    out.product_id = Int32(d.productID)
    out.max_contacts = Int32(d.maxContacts)
    out.slots_per_report = Int32(d.slotsPerReport)
    out.exclusive = d.exclusive ? 1 : 0
    out.physical_width_mm = Float(d.physicalWidthMillimeters ?? 0)
    out.physical_height_mm = Float(d.physicalHeightMillimeters ?? 0)
    _ = withUnsafeMutableBytes(of: &out.manufacturer) { copyCString(d.manufacturer, into: $0) }
    _ = withUnsafeMutableBytes(of: &out.product) { copyCString(d.product, into: $0) }
    info.pointee = out
    return MTK_OK
}

@_cdecl("mtk_poll_log")
public func mtkPollLog(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0, let message = CRuntime.shared.popLog() else { return 0 }
    return Int32(copyCString(message, into: UnsafeMutableRawBufferPointer(start: buffer, count: Int(capacity))))
}

@_cdecl("mtk_now_ns")
public func mtkNowNs() -> UInt64 { MultiTouchClock.now() }

/// mtk_set_display 選擇的顯示器；結果快取到顯示器設定或觸控裝置改變為止。只在主執行緒存取。
@MainActor
enum TouchDisplay {
    static var selector = DisplaySelector.environment ?? .automatic
    private static var cached: (id: CGDirectDisplayID, generation: UInt64)?
    /// 選到的顯示器與主螢幕的 bounds（mtk_map_to_window 每個觸點都會用到；顯示器重新設定時清除）
    private static var bounds: (display: CGRect, main: CGRect, id: CGDirectDisplayID)?
    private static var observing = false

    static func invalidate() {
        cached = nil
        bounds = nil
    }

    /// 與 `ScreenMapping(displayID:).cocoaPoint` 相同的換算，但 bounds 只在快取過期時查詢
    static func cocoaPoint(x: Double, y: Double, displayID: CGDirectDisplayID) -> CGPoint {
        observeReconfiguration()
        if bounds?.id != displayID {
            bounds = (CGDisplayBounds(displayID), CGDisplayBounds(CGMainDisplayID()), displayID)
        }
        let b = bounds!
        return CGPoint(x: b.display.origin.x + x * b.display.width, y: b.main.height - (b.display.origin.y + y * b.display.height))
    }

    /// 顯示器重新設定（接線、解析度、排列）時清除快取
    private static func observeReconfiguration() {
        guard !observing else { return }
        observing = true
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { TouchDisplay.invalidate() } }
        }, nil)
    }

    static func resolve() -> CGDirectDisplayID {
        observeReconfiguration()
        let generation = CRuntime.shared.deviceGeneration
        if let cached, cached.generation == generation { return cached.id }
        let match = DisplayLocator.resolve(selector, panel: CRuntime.shared.devices.first)
        let id = match?.display.id ?? 0
        cached = (id, generation)
        if let match {
            CRuntime.shared.appendLog("[MultiTouchKit] 觸控對應顯示器 \(match.display)：\(match.note)")
        } else {
            CRuntime.shared.appendLog("[MultiTouchKit] 找不到符合 \(selector) 的顯示器")
        }
        return id
    }
}

@_cdecl("mtk_set_display")
public func mtkSetDisplay(_ selector: UnsafePointer<CChar>?) -> Int32 {
    let text = selector.map { String(cString: $0) } ?? ""
    let parsed: DisplaySelector?
    if text.isEmpty {
        parsed = DisplaySelector.environment ?? .automatic
    } else {
        parsed = DisplaySelector(text)
    }
    guard let parsed else { return MTK_ERR_INVALID_ARGUMENT }
    let apply: @Sendable () -> Void = {
        MainActor.assumeIsolated {
            TouchDisplay.selector = parsed
            TouchDisplay.invalidate()
        }
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    return MTK_OK
}

@_cdecl("mtk_touch_display_id")
public func mtkTouchDisplayID() -> UInt32 {
    guard Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated { TouchDisplay.resolve() }
}

@_cdecl("mtk_map_to_window")
public func mtkMapToWindow(_ x: Float, _ y: Float, _ displayID: UInt32,
                           _ outX: UnsafeMutablePointer<Float>?, _ outY: UnsafeMutablePointer<Float>?) -> Int32 {
    guard let outX, let outY, Thread.isMainThread else { return MTK_ERR_INVALID_ARGUMENT }
    let point: CGPoint? = MainActor.assumeIsolated {
        guard let app = NSApp,
              let window = app.keyWindow ?? app.mainWindow ?? app.windows.first(where: { $0.isVisible }),
              let view = window.contentView else { return nil }
        let resolved = displayID != 0 ? displayID : TouchDisplay.resolve()
        let screenPoint = TouchDisplay.cocoaPoint(x: Double(x), y: Double(y), displayID: resolved != 0 ? resolved : CGMainDisplayID())
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        var inView = view.convert(inWindow, from: nil)
        if view.isFlipped { inView.y = view.bounds.height - inView.y }
        let scale = window.backingScaleFactor
        return CGPoint(x: inView.x * scale, y: inView.y * scale)
    }
    guard let point else { return MTK_ERR_NO_WINDOW }
    outX.pointee = Float(point.x)
    outY.pointee = Float(point.y)
    return MTK_OK
}

/// 以 UTF-8 寫入並保證結尾為 0；不會切斷多位元組字元。回傳寫入的位元組數（不含結尾 0）。
@discardableResult
private func copyCString(_ string: String, into buffer: UnsafeMutableRawBufferPointer) -> Int {
    guard buffer.count > 0 else { return 0 }
    var length = 0
    for scalar in string.unicodeScalars {
        // 整個字元放得下（含結尾 0）才寫入
        guard length + UTF8.width(scalar) < buffer.count else { break }
        for b in UTF8.encode(scalar)! {
            buffer[length] = b
            length += 1
        }
    }
    buffer[length] = 0
    return length
}

extension MTKTouchEvent: QueuedTouchEvent {
    public var queuedTouchID: UInt64 { touch_id }
    public var queuedPhase: TouchPhase { TouchPhase(rawValue: UInt8(truncatingIfNeeded: phase)) ?? .cancelled }
    public func withQueuedPhase(_ phase: TouchPhase) -> MTKTouchEvent {
        var e = self
        e.phase = Int32(phase.rawValue)
        return e
    }
}
