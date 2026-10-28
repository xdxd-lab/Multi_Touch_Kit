import Foundation
import IOKit
import IOKit.hid
import IOKit.pwr_mgt

/// `MultiTouchManager.start()` 的錯誤（IOKit 無法建立裝置通知；正常的 macOS 上不會發生）
public enum MultiTouchError: Error, Sendable {
    /// IONotificationPortCreate 失敗
    case notificationPortUnavailable
    /// IOServiceAddMatchingNotification 失敗（附 kern_return_t）
    case matchingFailed(kern_return_t)
}

/// 觸控螢幕管理器：自動偵測裝置（含插拔）、切到多點模式、獨占、解析並追蹤觸點。
///
/// 所有 handler 都在 `queue`（userInteractive 的序列佇列）上呼叫；請在 handler 中盡快返回，
/// 需要更新 UI 時再自行切換到主執行緒。
public final class MultiTouchManager: @unchecked Sendable {
    /// 建立 manager 時的設定；manager 建立後不能修改（要改請 stop 後以新設定建立新的 manager）
    public struct Configuration: Sendable {
        /// 只接受指定的 Vendor ID／Product ID；nil 代表不限（所有 HID 觸控螢幕）
        public var vendorID: Int?
        /// 見 `vendorID`
        public var productID: Int?
        /// 獨占裝置：系統不再把觸控當成單點滑鼠。同一時間只有一個程式能獨占。
        public var exclusive = true
        /// 開啟後依 Windows 流程初始化多點模式（讀取最大觸點數、設定 Device Mode）
        public var initializeMultiTouchMode = true
        /// 一併獨占同一 USB 裝置的其他 HID 介面（例如滑鼠相容模式）
        public var seizeSiblingInterfaces = true
        /// 裝置被其他程式獨占時，每隔多久重試（秒）；0 代表不重試
        public var retryInterval: Double = 1.0
        /// 觸點偏離錨點不超過 `staleTouchTolerance`、持續超過這麼久（秒）就視為誤觸並以 cancelled 取消
        /// （線材、物體碰到電容面板造成的幽靈觸點）。之後忽略該觸點直到它離開，或明顯移動後以新的觸碰重新開始。
        /// 真人手指按住不動時 ILITEK 的座標可完全不變達 10 秒以上，所以預設 30 秒；0 = 關閉
        public var staleTouchTimeout: Double = 30
        /// 正規化座標（0...1）；0.003 ≈ MF156LR 的 0.9 mm
        public var staleTouchTolerance: Double = 0.003
        /// 有觸點時超過這麼久（秒）沒有任何報告就全部取消（USB 異常）；控制器按住時以 125 Hz 回報。0 = 關閉
        public var reportTimeout: Double = 0.5
        /// 觸控校正的來源（預設讀取 calibration.json；見 `TouchCalibration`）
        public var calibration: TouchCalibrationSource = .stored
        /// `.stored` 使用的校正檔（測試時可改）
        public var calibrationStoreURL: URL = TouchCalibrationStore.defaultURL

        /// 預設值：所有 HID 觸控螢幕、獨占、初始化多點模式、一併獨占滑鼠相容介面
        public init() {}
    }

    /// 建立時的設定
    public let configuration: Configuration
    /// HID 事件與所有 handler 執行的佇列
    public let queue: DispatchQueue

    private let _frameHandler = Locked<(@Sendable (TouchFrame) -> Void)?>(nil)
    private let _deviceHandler = Locked<(@Sendable (DeviceEvent) -> Void)?>(nil)
    private let _logHandler = Locked<(@Sendable (String) -> Void)?>(nil)
    /// 裝置清單與執行狀態一起更新
    private let published = Locked((devices: [MultiTouchDeviceInfo](), isRunning: false))

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
    private var calibrationTimer: DispatchSourceTimer?
    private var calibrationFileDate: Date?
    private let _calibrationEnabled = Locked(true)

    /// 建立後呼叫 `start()` 才會開始偵測
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        queue = DispatchQueue(label: "MultiTouchKit.hid", qos: .userInteractive)
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        // 沒有呼叫 stop() 就被釋放：teardown 必須在 queue 上執行，否則會與正在處理的 HID 報告競爭。
        // 最後一個參照在 handler 內（queue 上）被釋放時直接執行，避免 queue.sync 死結。
        guard notifyPort != nil else { return }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            teardown()
        } else {
            queue.sync { teardown() }
        }
    }

    /// 每個 frame 呼叫一次（在 `queue` 上）
    public var frameHandler: (@Sendable (TouchFrame) -> Void)? {
        get { _frameHandler.wrapped }
        set { _frameHandler.wrapped = newValue }
    }

    /// 裝置加入、移除、重新初始化時呼叫（在 `queue` 上）
    public var deviceHandler: (@Sendable (DeviceEvent) -> Void)? {
        get { _deviceHandler.wrapped }
        set { _deviceHandler.wrapped = newValue }
    }

    /// 診斷訊息（在 `queue` 上）
    public var logHandler: (@Sendable (String) -> Void)? {
        get { _logHandler.wrapped }
        set { _logHandler.wrapped = newValue }
    }

    /// 目前已開啟的裝置（任何執行緒皆可讀取）
    public var connectedDevices: [MultiTouchDeviceInfo] { published.wrapped.devices }

    /// `start()` 之後、`stop()` 之前為 true；不代表已有裝置（見 `connectedDevices`）
    public var isRunning: Bool { published.wrapped.isRunning }

    /// 執行期間切換觸控校正（C API mtk_set_calibration_enabled、Unity applyCalibration）；任何執行緒皆可設定，立即套用到所有裝置
    public var isCalibrationEnabled: Bool {
        get { _calibrationEnabled.wrapped }
        set {
            _calibrationEnabled.wrapped = newValue
            queue.async { [weak self] in self?.applyCalibration(reason: newValue ? "啟用" : "停用") }
        }
    }

    /// 開始偵測觸控螢幕（包含之後才接上的）並讀取觸控。已在執行時不做任何事；沒有觸控螢幕時也會成功，接上後自動開始。
    /// 可從任何執行緒呼叫，包含 handler 內（在 `queue` 上同步執行）。
    /// - Throws: `MultiTouchError`（IOKit 無法建立裝置通知）
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
            published.withLock { $0.isRunning = true }
            servicesAppeared(iterator)
            startCalibrationWatcher()
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

    // MARK: - 觸控校正

    /// 環境變數 MTK_CALIBRATION=off 時，`.stored` 視為停用（所有使用 MultiTouchKit 的程式一併停用）
    private static let calibrationDisabledByEnvironment =
        ["off", "0", "false", "no"].contains(ProcessInfo.processInfo.environment["MTK_CALIBRATION"]?.lowercased() ?? "")

    private func calibration(for info: MultiTouchDeviceInfo) -> (TouchCalibration, String)? {
        guard _calibrationEnabled.wrapped else { return nil }
        switch configuration.calibration {
        case .disabled:
            return nil
        case .custom(let calibration):
            return (calibration, "指定的校正")
        case .stored:
            guard !Self.calibrationDisabledByEnvironment,
                  let entry = TouchCalibrationStore(url: configuration.calibrationStoreURL).entry(for: info) else { return nil }
            let date = DateFormatter.localizedString(from: entry.date, dateStyle: .short, timeStyle: .short)
            return (entry.calibration, String(format: "%@，%d 點，平均誤差 %.1f → %.1f mm", date, entry.samples.count,
                                              entry.errorBefore, entry.errorAfter))
        }
    }

    /// 依目前設定為所有裝置重新套用校正（在 queue 上）
    private func applyCalibration(reason: String) {
        var changed = false
        for device in devices.values.sorted(by: { $0.id < $1.id }) {
            let resolved = calibration(for: device.info)
            guard resolved?.0 != device.calibration else { continue }
            device.calibration = resolved?.0
            changed = true
            if let (_, note) = resolved {
                emitLog("裝置 #\(device.id) 套用觸控校正（\(reason)；\(note)）")
            } else {
                emitLog("裝置 #\(device.id) 不套用觸控校正（\(reason)）")
            }
        }
        if changed {
            publishDevices()
            for device in devices.values { deviceHandler?(.reinitialized(device.info)) }
        }
    }

    /// `.stored` 時每 2 秒檢查校正檔的修改時間：校正工具存檔後，執行中的程式（mtk-server、Unity）立即套用
    private func startCalibrationWatcher() {
        guard case .stored = configuration.calibration, !Self.calibrationDisabledByEnvironment else { return }
        let store = TouchCalibrationStore(url: configuration.calibrationStoreURL)
        calibrationFileDate = store.modificationDate
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let date = store.modificationDate
            guard date != calibrationFileDate else { return }
            calibrationFileDate = date
            applyCalibration(reason: "校正檔已更新")
        }
        calibrationTimer = timer
        timer.resume()
    }

    private func teardown() {
        calibrationTimer?.cancel()
        calibrationTimer = nil
        for device in devices.values.sorted(by: { $0.id < $1.id }) {
            if let frame = device.cancelTouches() { frameHandler?(frame) }
            device.cancel()
            deviceHandler?(.removed(device.info))
        }
        devices.removeAll()
        // open() 重試時 IOObjectRetain 過
        for item in pending.values { IOObjectRelease(item.service) }
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
        published.wrapped = ([], false)
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
        } catch TouchDeviceError.unavailable {
            emitLog("\(info.product) 已無法開啟（可能已拔除），停止重試")
            return
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
        device.stalePolicy = ContactTracker.StalePolicy(timeout: max(0, configuration.staleTouchTimeout),
                                                        tolerance: configuration.staleTouchTolerance)
        device.reportTimeout = max(0, configuration.reportTimeout)
        let resolvedCalibration = calibration(for: device.info)
        device.calibration = resolvedCalibration?.0
        // weak：manager 釋放期間仍可能有一筆已排入 queue 的報告
        device.allocateTouchID = { [weak self] in
            guard let self else { return 0 }
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
        if let (_, note) = resolvedCalibration { notes.append("套用觸控校正（\(note)）") }
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
        published.withLock { $0.devices = list }
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
        guard rootPort != 0 else { return nil }
        guard let notificationPort else {
            IODeregisterForSystemPower(&notifier)
            IOServiceClose(rootPort)
            return nil
        }
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
