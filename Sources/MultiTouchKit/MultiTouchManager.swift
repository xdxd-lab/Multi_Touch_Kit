import Foundation
import IOKit
import IOKit.hid
import IOKit.pwr_mgt

public enum MultiTouchError: Error, Sendable {
    case notificationPortUnavailable
    case matchingFailed(kern_return_t)
}

/// 觸控螢幕管理器：自動偵測裝置（含插拔）、切到多點模式、獨占、解析並追蹤觸點。
///
/// 所有 handler 都在 `queue`（userInteractive 的序列佇列）上呼叫；請在 handler 中盡快返回，
/// 需要更新 UI 時再自行切換到主執行緒。
public final class MultiTouchManager: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// 只接受指定的 Vendor ID／Product ID；nil 代表不限（所有 HID 觸控螢幕）
        public var vendorID: Int?
        public var productID: Int?
        /// 獨占裝置：系統不再把觸控當成單點滑鼠。同一時間只有一個程式能獨占。
        public var exclusive = true
        /// 開啟後依 Windows 流程初始化多點模式（讀取最大觸點數、設定 Device Mode）
        public var initializeMultiTouchMode = true
        /// 一併獨占同一 USB 裝置的其他 HID 介面（例如滑鼠相容模式）
        public var seizeSiblingInterfaces = true
        /// 裝置被其他程式獨占時，每隔多久重試（秒）；0 代表不重試
        public var retryInterval: Double = 1.0

        public init() {}
    }

    public let configuration: Configuration
    /// HID 事件與所有 handler 執行的佇列
    public let queue: DispatchQueue

    private let lock = NSLock()
    private var _frameHandler: (@Sendable (TouchFrame) -> Void)?
    private var _deviceHandler: (@Sendable (DeviceEvent) -> Void)?
    private var _logHandler: (@Sendable (String) -> Void)?
    private var _devices: [MultiTouchDeviceInfo] = []
    private var _isRunning = false

    // 以下狀態只在 queue 上存取
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var devices: [Int: TouchDevice] = [:]
    private var pending: [UInt64: (service: io_service_t, info: HIDServiceInfo)] = [:]
    private var retryTimer: DispatchSourceTimer?
    private var power: PowerObserver?
    private var nextDeviceID = 1
    private var nextTouchID: UInt64 = 1
    private var exclusiveWarningShown: Set<UInt64> = []

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        queue = DispatchQueue(label: "MultiTouchKit.hid", qos: .userInteractive)
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        if notifyPort != nil { teardown() }
    }

    /// 每個 frame 呼叫一次（在 `queue` 上）
    public var frameHandler: (@Sendable (TouchFrame) -> Void)? {
        get { lock.withLock { _frameHandler } }
        set { lock.withLock { _frameHandler = newValue } }
    }

    /// 裝置加入、移除、重新初始化時呼叫（在 `queue` 上）
    public var deviceHandler: (@Sendable (DeviceEvent) -> Void)? {
        get { lock.withLock { _deviceHandler } }
        set { lock.withLock { _deviceHandler = newValue } }
    }

    /// 診斷訊息（在 `queue` 上）
    public var logHandler: (@Sendable (String) -> Void)? {
        get { lock.withLock { _logHandler } }
        set { lock.withLock { _logHandler = newValue } }
    }

    /// 目前已開啟的裝置（任何執行緒皆可讀取）
    public var connectedDevices: [MultiTouchDeviceInfo] { lock.withLock { _devices } }

    public var isRunning: Bool { lock.withLock { _isRunning } }

    public func start() throws {
        try onQueue {
            guard notifyPort == nil else { return }
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                throw MultiTouchError.notificationPortUnavailable
            }
            IONotificationPortSetDispatchQueue(port, queue)
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, kIOFirstMatchNotification, IOServiceMatching(kIOHIDDeviceKey),
                { refcon, iterator in
                    guard let refcon else { return }
                    Unmanaged<MultiTouchManager>.fromOpaque(refcon).takeUnretainedValue().servicesAppeared(iterator)
                },
                Unmanaged.passUnretained(self).toOpaque(), &iterator)
            guard result == KERN_SUCCESS else {
                IONotificationPortDestroy(port)
                throw MultiTouchError.matchingFailed(result)
            }
            notifyPort = port
            matchIterator = iterator
            lock.withLock { _isRunning = true }
            servicesAppeared(iterator)
            power = PowerObserver(queue: queue) { [weak self] in
                // 喚醒後裝置可能還沒準備好，稍等再初始化
                self?.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reinitializeAll(reason: "系統喚醒") }
            }
        }
    }

    /// 停止並釋放裝置。仍在螢幕上的觸點會先以 cancelled 送出。
    public func stop() {
        onQueue { teardown() }
    }

    // MARK: - 內部

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    private func emitLog(_ message: String) {
        logHandler?("[MultiTouchKit] " + message)
    }

    private func teardown() {
        for device in devices.values.sorted(by: { $0.id < $1.id }) {
            if let frame = device.cancelTouches() { frameHandler?(frame) }
            device.cancel()
            deviceHandler?(.removed(device.info))
        }
        devices.removeAll()
        pending.removeAll()
        retryTimer?.cancel()
        retryTimer = nil
        power?.invalidate()
        power = nil
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        lock.withLock {
            _devices = []
            _isRunning = false
        }
    }

    private func servicesAppeared(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            consider(service: service)
            IOObjectRelease(service)
        }
    }

    private func consider(service: io_service_t) {
        let info = HIDServiceInfo(service: service)
        if let vid = configuration.vendorID, vid != info.vendorID { return }
        if let pid = configuration.productID, pid != info.productID { return }

        if info.isTouchScreen {
            guard !devices.values.contains(where: { $0.service.registryID == info.registryID }) else { return }
            open(service: service, info: info)
        } else if configuration.exclusive && configuration.seizeSiblingInterfaces {
            // 觸控介面先出現、其他介面後出現的情況
            for device in devices.values where info.isSibling(of: device.service) && !device.hasSibling(info.registryID) {
                device.attachSibling(service: service, info: info)
            }
        }
    }

    private func open(service: io_service_t, info: HIDServiceInfo) {
        let device: TouchDevice
        do {
            guard let created = try TouchDevice(id: nextDeviceID, service: service, info: info, queue: queue) else {
                emitLog("\(info.product) 不是可解析的多點觸控螢幕，略過")
                return
            }
            device = created
        } catch {
            emitLog("\(info.product) 的報告描述元解析失敗：\(error)")
            return
        }

        let result = device.open(exclusive: configuration.exclusive)
        guard result == kIOReturnSuccess else {
            if result == ioReturnExclusiveAccess && configuration.retryInterval > 0 {
                if exclusiveWarningShown.insert(info.registryID).inserted {
                    emitLog("\(info.product) 已被其他程式獨占（例如 mtk-server），會持續重試")
                }
                IOObjectRetain(service)
                pending[info.registryID] = (service, info)
                scheduleRetry()
            } else {
                emitLog("無法開啟 \(info.product)：\(hexString(result))")
            }
            return
        }

        nextDeviceID += 1
        exclusiveWarningShown.remove(info.registryID)
        device.log = { [weak self] in self?.emitLog($0) }
        device.allocateTouchID = { [unowned self] in
            defer { nextTouchID += 1 }
            return nextTouchID
        }
        device.onFrame = { [weak self] frame in self?.frameHandler?(frame) }
        device.onRemoved = { [weak self, weak device] in
            guard let self, let device else { return }
            remove(device)
        }
        device.onFallbackDetected = { [weak self, weak device] in
            guard let self, let device else { return }
            emitLog("\(device.info.product) 的滑鼠介面有資料，重新初始化多點模式")
            reinitialize(device)
        }
        device.activate()
        devices[device.id] = device

        var notes = [configuration.exclusive ? "已獨占" : "共用開啟"]
        if configuration.initializeMultiTouchMode { notes.append(device.initializeMultiTouchMode()) }
        if configuration.exclusive && configuration.seizeSiblingInterfaces {
            enumerateHIDServices { sibling in
                let siblingInfo = HIDServiceInfo(service: sibling)
                if siblingInfo.isSibling(of: info) && !siblingInfo.isTouchScreen {
                    device.attachSibling(service: sibling, info: siblingInfo)
                }
            }
        }
        emitLog(String(format: "裝置 #%d %@ %@（VID 0x%04X PID 0x%04X）：", device.id, info.manufacturer, info.product,
                       info.vendorID, info.productID) + notes.joined(separator: "、"))
        publishDevices()
        deviceHandler?(.added(device.info))
    }

    private func remove(_ device: TouchDevice) {
        guard devices.removeValue(forKey: device.id) != nil else { return }
        if let frame = device.cancelTouches() { frameHandler?(frame) }
        device.cancel()
        emitLog("裝置 #\(device.id) \(device.info.product) 已移除")
        publishDevices()
        deviceHandler?(.removed(device.info))
    }

    private func reinitialize(_ device: TouchDevice) {
        guard configuration.initializeMultiTouchMode else { return }
        let note = device.initializeMultiTouchMode()
        emitLog("裝置 #\(device.id) 重新初始化：\(note)")
        publishDevices()
        deviceHandler?(.reinitialized(device.info))
    }

    private func reinitializeAll(reason: String) {
        guard notifyPort != nil else { return }
        if !devices.isEmpty { emitLog("\(reason)，重新初始化所有裝置") }
        for device in devices.values { reinitialize(device) }
    }

    private func publishDevices() {
        let list = devices.values.map(\.info).sorted { $0.id < $1.id }
        lock.withLock { _devices = list }
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = configuration.retryInterval
        timer.schedule(deadline: .now() + 0.1, repeating: interval)
        timer.setEventHandler { [weak self] in self?.retryPending() }
        retryTimer = timer
        timer.resume()
    }

    private func retryPending() {
        let items = pending
        pending.removeAll()
        for (_, item) in items {
            open(service: item.service, info: item.info)
            IOObjectRelease(item.service)
        }
        if pending.isEmpty {
            retryTimer?.cancel()
            retryTimer = nil
        }
    }
}

/// 系統睡眠／喚醒通知。睡眠相關訊息一定要回覆 IOAllowPowerChange，否則系統會等待逾時。
final class PowerObserver {
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private let onWake: () -> Void

    init?(queue: DispatchQueue, onWake: @escaping () -> Void) {
        self.onWake = onWake
        var notificationPort: IONotificationPortRef?
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notificationPort, { refcon, _, type, argument in
            guard let refcon else { return }
            Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, argument: argument)
        }, &notifier)
        guard rootPort != 0, let notificationPort else { return nil }
        port = notificationPort
        IONotificationPortSetDispatchQueue(notificationPort, queue)
    }

    private func handle(type: UInt32, argument: UnsafeMutableRawPointer?) {
        switch type {
        case Self.canSystemSleep, Self.systemWillSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }

    func invalidate() {
        guard rootPort != 0 else { return }
        IODeregisterForSystemPower(&notifier)
        IOServiceClose(rootPort)
        if let port { IONotificationPortDestroy(port) }
        rootPort = 0
        port = nil
    }
}
