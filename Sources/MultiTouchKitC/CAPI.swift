// C API 實作（宣告見 Sources/CMultiTouchKit/include/multitouchkit.h）。
// 建置成 libMultiTouchKitC.dylib；Unity 外掛由 scripts/build-unity-plugin.sh 包成 MultiTouchKit.bundle。
import AppKit
import CMultiTouchKit
import Foundation
import MultiTouchKit

/// 整個程序共用一份的 C API 狀態
final class CRuntime: @unchecked Sendable {
    static let shared = CRuntime()

    private let lock = NSLock()
    private var manager: MultiTouchManager?
    private var ring: [MTKTouchEvent] = []
    private var head = 0
    private var count = 0
    private var dropped: UInt64 = 0
    private var reportStationary = false
    private var callback: MTKEventCallback?
    private var callbackUserData: UnsafeMutableRawPointer?
    private var logs: [String] = []
    private static let maxLogs = 128

    var isRunning: Bool { lock.withLock { manager != nil } }
    var droppedCount: UInt64 { lock.withLock { dropped } }
    var devices: [MultiTouchDeviceInfo] { lock.withLock { manager?.connectedDevices ?? [] } }

    func start(_ config: MTKConfig) -> Int32 {
        stop()
        var configuration = MultiTouchManager.Configuration()
        configuration.vendorID = config.vendor_id != 0 ? Int(config.vendor_id) : nil
        configuration.productID = config.product_id != 0 ? Int(config.product_id) : nil
        configuration.exclusive = config.exclusive != 0
        configuration.initializeMultiTouchMode = config.init_multitouch != 0
        let capacity = config.queue_capacity > 0 ? Int(config.queue_capacity) : 4096
        lock.withLock {
            ring = Array(repeating: MTKTouchEvent(), count: capacity)
            head = 0
            count = 0
            dropped = 0
            reportStationary = config.report_stationary != 0
        }
        let manager = MultiTouchManager(configuration: configuration)
        manager.logHandler = { [weak self] in self?.appendLog($0) }
        manager.frameHandler = { [weak self] in self?.enqueue($0) }
        do {
            try manager.start()
        } catch {
            appendLog("[MultiTouchKit] 啟動失敗：\(error)")
            return MTK_ERR_START_FAILED
        }
        lock.withLock { self.manager = manager }
        return MTK_OK
    }

    func stop() {
        let current = lock.withLock { () -> MultiTouchManager? in
            defer { manager = nil }
            return manager
        }
        current?.stop()
    }

    func setCallback(_ callback: MTKEventCallback?, _ userData: UnsafeMutableRawPointer?) {
        lock.withLock {
            self.callback = callback
            callbackUserData = userData
        }
    }

    func poll(into buffer: UnsafeMutablePointer<MTKTouchEvent>, capacity: Int) -> Int {
        lock.withLock {
            let n = min(capacity, count)
            for i in 0..<n { buffer[i] = ring[(head + i) % ring.count] }
            if n > 0 { head = (head + n) % ring.count }
            count -= n
            return n
        }
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

    private func enqueue(_ frame: TouchFrame) {
        let includeStationary = lock.withLock { reportStationary }
        var events: [MTKTouchEvent] = []
        events.reserveCapacity(frame.touches.count)
        for t in frame.touches where includeStationary || t.phase != .stationary {
            var flags: UInt32 = 0
            if t.pressure != nil { flags |= MTK_FLAG_HAS_PRESSURE }
            if t.width != nil || t.height != nil { flags |= MTK_FLAG_HAS_SIZE }
            if let confident = t.confidence {
                flags |= MTK_FLAG_HAS_CONFIDENCE
                if !confident { flags |= MTK_FLAG_LOW_CONFIDENCE }
            }
            events.append(MTKTouchEvent(
                touch_id: t.id, timestamp_ns: frame.timestamp,
                device_id: Int32(frame.deviceID), contact_id: Int32(truncatingIfNeeded: t.contactID),
                phase: Int32(t.phase.rawValue), x: Float(t.x), y: Float(t.y),
                pressure: t.pressure.map { Float($0) } ?? -1,
                width: t.width.map { Float($0) } ?? -1,
                height: t.height.map { Float($0) } ?? -1,
                frame_seq: UInt32(truncatingIfNeeded: frame.sequence), flags: flags))
        }
        guard !events.isEmpty else { return }
        let (callback, userData) = lock.withLock { () -> (MTKEventCallback?, UnsafeMutableRawPointer?) in
            for e in events { push(e) }
            return (self.callback, callbackUserData)
        }
        if let callback {
            events.withUnsafeBufferPointer { callback($0.baseAddress, Int32($0.count), userData) }
        }
    }

    /// 需持有 lock
    private func push(_ event: MTKTouchEvent) {
        let capacity = ring.count
        guard capacity > 0 else { return }
        if count == capacity {
            head = (head + 1) % capacity
            count -= 1
            dropped += 1
        }
        ring[(head + count) % capacity] = event
        count += 1
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
                               exclusive: 1, init_multitouch: 1, report_stationary: 0, queue_capacity: 0, reserved: 0)
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

@_cdecl("mtk_map_to_window")
public func mtkMapToWindow(_ x: Float, _ y: Float, _ displayID: UInt32,
                           _ outX: UnsafeMutablePointer<Float>?, _ outY: UnsafeMutablePointer<Float>?) -> Int32 {
    guard let outX, let outY, Thread.isMainThread else { return MTK_ERR_INVALID_ARGUMENT }
    let point: CGPoint? = MainActor.assumeIsolated {
        guard let app = NSApp,
              let window = app.keyWindow ?? app.mainWindow ?? app.windows.first(where: { $0.isVisible }),
              let view = window.contentView else { return nil }
        let mapping = ScreenMapping(displayID: displayID == 0 ? CGMainDisplayID() : displayID)
        let inWindow = window.convertPoint(fromScreen: mapping.cocoaPoint(x: Double(x), y: Double(y)))
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
        let bytes = Array(String(scalar).utf8)
        guard length + bytes.count < buffer.count else { break }
        for b in bytes {
            buffer[length] = b
            length += 1
        }
    }
    buffer[length] = 0
    return length
}
