import Foundation
import IOKit
import IOKit.hid

enum TouchDeviceError: Error {
    /// IOHIDDeviceCreate 失敗：service 已終止（通常是裝置已拔除）
    case unavailable
}

/// 一個實體觸控螢幕：數位板介面，加上同一 USB 裝置上被一併獨占的其他 HID 介面。
/// 除了 init 以外，所有方法都必須在 MultiTouchManager.queue 上呼叫。
final class TouchDevice: @unchecked Sendable {
    let id: Int
    let service: HIDServiceInfo
    let hidDevice: IOHIDDevice
    let descriptor: HIDReportDescriptor
    let layout: DigitizerLayout
    private(set) var info: MultiTouchDeviceInfo

    var onFrame: ((TouchFrame) -> Void)?
    var onRemoved: (() -> Void)?
    /// 同裝置的滑鼠介面送出資料：控制器可能退回了相容模式
    var onFallbackDetected: (() -> Void)?
    var allocateTouchID: () -> UInt64 = { 0 }
    var log: (String) -> Void = { _ in }

    private let queue: DispatchQueue
    private var assembler = FrameAssembler()
    private var tracker = ContactTracker()
    private var sequence: UInt64 = 0
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private let reportBufferSize: Int
    private var siblings: [UInt64: Sibling] = [:]
    private var opened = false
    private var activated = false
    private var lastReinit: UInt64 = 0
    /// 有觸點時超過這麼久（秒）沒有任何報告就全部取消（USB 異常、控制器卡住）；0 = 關閉
    var reportTimeout: Double {
        get { reportMonitor.timeout }
        set { reportMonitor.timeout = newValue }
    }
    private var reportMonitor = ReportTimeoutMonitor(timeout: 0.5)
    private var reportWatchdog: DispatchSourceTimer?

    /// 觸控校正（nil = 不校正）；在觸點追蹤之前套用，所以所有出口（含 stale 判斷）都用校正後的座標
    var calibration: TouchCalibration? {
        didSet { info.isCalibrated = calibration != nil }
    }

    /// 長時間完全不動的觸點視為誤觸並取消（見 MultiTouchManager.Configuration.staleTouchTimeout）
    var stalePolicy: ContactTracker.StalePolicy {
        get { tracker.stalePolicy }
        set { tracker.stalePolicy = newValue }
    }

    /// 描述元不是可解析的觸控螢幕時回傳 nil；service 已失效時丟出 `TouchDeviceError.unavailable`
    init?(id: Int, service: io_service_t, info: HIDServiceInfo, queue: DispatchQueue) throws {
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { throw TouchDeviceError.unavailable }
        let descriptor = try HIDReportDescriptor(bytes: info.reportDescriptor)
        guard let layout = DigitizerLayout(descriptor: descriptor) else { return nil }
        self.id = id
        self.service = info
        self.hidDevice = device
        self.descriptor = descriptor
        self.layout = layout
        self.queue = queue
        reportBufferSize = max(info.maxInputReportSize, layout.reportLength + 1)
        reportBuffer = .allocate(capacity: reportBufferSize)
        self.info = MultiTouchDeviceInfo(
            id: id, vendorID: info.vendorID, productID: info.productID,
            manufacturer: info.manufacturer, product: info.product, serialNumber: info.serialNumber,
            locationID: info.locationID,
            // 先以槽位數為準，讀到 Contact Count Maximum feature 後再更新
            maxContacts: layout.slots.count,
            slotsPerReport: layout.slots.count,
            physicalWidthMillimeters: layout.slots.first?.x.physicalLengthMillimeters,
            physicalHeightMillimeters: layout.slots.first?.y.physicalLengthMillimeters,
            hasScanTime: layout.scanTime != nil,
            exclusive: false)
    }

    deinit {
        reportBuffer.deallocate()
    }

    func open(exclusive: Bool) -> IOReturn {
        let options = exclusive ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone
        let result = IOHIDDeviceOpen(hidDevice, IOOptionBits(options))
        if result == kIOReturnSuccess {
            opened = true
            info.exclusive = exclusive
        }
        return result
    }

    /// 開始接收報告。
    ///
    /// 擁有權：IOKit 的回呼只拿到裸指標，所以這裡以 `passRetained` 讓 IOHIDDevice「持有」self 一次，
    /// 回呼期間 self 不會被釋放（manager 可能已經從 devices 移除它）。這個參照只在 cancel handler 中
    /// 以 `takeRetainedValue` 釋放：IOKit 保證 cancel handler 是最後一個回呼，之後不會再有報告寫進
    /// `reportBuffer`，所以 deinit 才釋放 buffer 是安全的。只呼叫 `IOHIDDeviceClose` 而不 cancel 會洩漏 self。
    func activate() {
        IOHIDDeviceSetDispatchQueue(hidDevice, queue)
        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            hidDevice, reportBuffer, reportBufferSize,
            { context, result, _, _, reportID, report, length, timeStamp in
                guard result == kIOReturnSuccess, let context else { return }
                Unmanaged<TouchDevice>.fromOpaque(context).takeUnretainedValue()
                    .handleReport(reportID: UInt8(truncatingIfNeeded: reportID), report: report,
                                  length: length, hostTime: timeStamp)
            }, context)
        IOHIDDeviceRegisterRemovalCallback(hidDevice, { context, _, _ in
            guard let context else { return }
            Unmanaged<TouchDevice>.fromOpaque(context).takeUnretainedValue().onRemoved?()
        }, context)
        let bits = UInt(bitPattern: context)
        IOHIDDeviceSetCancelHandler(hidDevice) {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let device = Unmanaged<TouchDevice>.fromOpaque(pointer).takeRetainedValue()
            IOHIDDeviceClose(device.hidDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDDeviceActivate(hidDevice)
        activated = true
    }

    /// 停止接收並釋放所有介面（非同步完成）
    func cancel() {
        reportWatchdog?.cancel()
        reportWatchdog = nil
        for sibling in siblings.values { IOHIDDeviceCancel(sibling.device) }
        siblings.removeAll()
        if activated {
            IOHIDDeviceCancel(hidDevice)
            activated = false
        } else if opened {
            IOHIDDeviceClose(hidDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        opened = false
    }

    /// 把仍在螢幕上的觸點全部標成 cancelled
    func cancelTouches() -> TouchFrame? {
        let touches = tracker.cancelAll()
        guard !touches.isEmpty else { return nil }
        sequence += 1
        return TouchFrame(deviceID: id, sequence: sequence, timestamp: MultiTouchClock.now(), scanTime: nil, touches: touches)
    }

    // MARK: - 報告處理

    private func handleReport(reportID: UInt8, report: UnsafeMutablePointer<UInt8>, length: CFIndex, hostTime: UInt64) {
        guard reportID == layout.reportID else { return }
        let skip = descriptor.usesReportIDs ? 1 : 0
        guard length - skip >= layout.reportLength else { return }
        let parsed = layout.parse(UnsafeBufferPointer(start: report + skip, count: length - skip))
        guard let frame = assembler.add(parsed, timestamp: MultiTouchClock.nanoseconds(fromHostTime: hostTime)) else { return }
        reportMonitor.reportReceived(at: MultiTouchClock.now())
        var contacts = frame.contacts
        if let calibration {
            for i in contacts.indices {
                let raw = (x: contacts[i].x, y: contacts[i].y)
                (contacts[i].x, contacts[i].y) = calibration.apply(x: raw.x, y: raw.y)
                contacts[i].uncalibratedX = raw.x
                contacts[i].uncalibratedY = raw.y
            }
        }
        let touches = tracker.update(contacts, at: frame.timestamp, allocateID: allocateTouchID)
        for t in touches where t.phase == .cancelled {
            log(String(format: "觸點 #%llu（contact %d）已 %.0f 秒幾乎不動，視為誤觸並取消（可能是線材或物體碰到面板）",
                       t.id, t.contactID, tracker.stalePolicy.timeout))
        }
        updateReportWatchdog()
        // 閒置時的空報告不轉發
        guard !touches.isEmpty else { return }
        sequence += 1
        onFrame?(TouchFrame(deviceID: id, sequence: sequence, timestamp: frame.timestamp,
                            scanTime: parsed.scanTime, touches: touches))
    }

    /// 有觸點時每 0.25 秒檢查一次是否還有報告進來
    private func updateReportWatchdog() {
        if tracker.hasActiveTouches && reportTimeout > 0 {
            guard reportWatchdog == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.checkReportTimeout() }
            reportWatchdog = timer
            timer.resume()
        } else if let reportWatchdog {
            reportWatchdog.cancel()
            self.reportWatchdog = nil
        }
    }

    private func checkReportTimeout() {
        let now = MultiTouchClock.now()
        guard reportMonitor.isExpired(at: now, hasActiveTouches: tracker.hasActiveTouches) else { return }
        let silence = reportMonitor.silence(at: now)
        if let frame = cancelTouches() {
            log(String(format: "%@ 已 %.1f 秒沒有觸控報告，取消仍在螢幕上的 %d 個觸點", info.product, silence, frame.touches.count))
            onFrame?(frame)
        }
        updateReportWatchdog()
    }

    // MARK: - 多點模式初始化

    /// 依 Windows 的列舉流程：讀取最大觸點數，若有 Device Mode 就設為 2（多點）。回傳給人看的結果說明。
    @discardableResult
    func initializeMultiTouchMode() -> String {
        lastReinit = MultiTouchClock.now()
        var notes: [String] = []
        if let field = layout.maxContactsFeature {
            if let payload = getFeature(id: field.reportID) {
                let value = Int(field.value(in: payload))
                if value > 0 { info.maxContacts = value }
                notes.append("最大觸點數 \(value)")
            } else {
                notes.append("讀取最大觸點數失敗")
            }
        }
        if let field = layout.deviceModeFeature {
            var payload = getFeature(id: field.reportID)
                ?? [UInt8](repeating: 0, count: descriptor.reportByteCount(.feature, id: field.reportID))
            field.write(2, into: &payload)
            let result = setFeature(id: field.reportID, payload: payload)
            notes.append(result == kIOReturnSuccess ? "已切換到多點模式" : "切換多點模式失敗 \(hexString(result))")
        }
        return notes.isEmpty ? "裝置沒有需要初始化的 feature report" : notes.joined(separator: "、")
    }

    /// 回傳不含 report ID 的 feature report 內容
    private func getFeature(id: UInt8) -> [UInt8]? {
        let withID = descriptor.usesReportIDs ? 1 : 0
        let size = descriptor.reportByteCount(.feature, id: id) + withID
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        var length = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(hidDevice, kIOHIDReportTypeFeature, CFIndex(id), &buffer, &length)
        guard result == kIOReturnSuccess else { return nil }
        let skip = withID == 1 && length >= size ? 1 : 0
        return Array(buffer[skip..<max(skip, min(length, buffer.count))])
    }

    private func setFeature(id: UInt8, payload: [UInt8]) -> IOReturn {
        let report = (descriptor.usesReportIDs ? [id] : []) + payload
        return IOHIDDeviceSetReport(hidDevice, kIOHIDReportTypeFeature, CFIndex(id), report, report.count)
    }

    // MARK: - 同裝置的其他介面

    private final class Sibling: @unchecked Sendable {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let size: Int
        let pointerReportIDs: Set<UInt8>
        weak var owner: TouchDevice?

        init(device: IOHIDDevice, size: Int, pointerReportIDs: Set<UInt8>, owner: TouchDevice) {
            self.device = device
            self.size = size
            self.pointerReportIDs = pointerReportIDs
            self.owner = owner
            buffer = .allocate(capacity: size)
        }

        deinit {
            buffer.deallocate()
        }
    }

    func hasSibling(_ registryID: UInt64) -> Bool { siblings[registryID] != nil }

    /// 獨占同裝置的其他介面（例如滑鼠相容模式），避免系統把觸控當成單點滑鼠
    func attachSibling(service: io_service_t, info sibling: HIDServiceInfo) {
        guard siblings[sibling.registryID] == nil,
              let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            log("無法獨占 \(sibling.product) 的其他介面：\(hexString(result))")
            return
        }
        let pointerIDs: Set<UInt8> = (try? HIDReportDescriptor(bytes: sibling.reportDescriptor)).map { d in
            Set(d.inputFields.filter { field in
                !field.isConstant && field.collectionPath.contains {
                    $0.usagePage == HIDUsage.genericDesktopPage && ($0.usage == HIDUsage.mouse || $0.usage == HIDUsage.pointer)
                }
            }.map(\.reportID))
        } ?? []
        let entry = Sibling(device: device, size: max(sibling.maxInputReportSize, 1), pointerReportIDs: pointerIDs, owner: self)
        siblings[sibling.registryID] = entry
        IOHIDDeviceSetDispatchQueue(device, queue)
        // 與 activate() 相同的擁有權規則：cancel handler 釋放這個參照
        let context = Unmanaged.passRetained(entry).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, entry.buffer, entry.size, { context, result, _, _, reportID, _, _ in
            guard result == kIOReturnSuccess, let context else { return }
            let entry = Unmanaged<Sibling>.fromOpaque(context).takeUnretainedValue()
            if entry.pointerReportIDs.contains(UInt8(truncatingIfNeeded: reportID)) {
                entry.owner?.siblingPointerActivity()
            }
        }, context)
        let bits = UInt(bitPattern: context)
        IOHIDDeviceSetCancelHandler(device) {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            let entry = Unmanaged<Sibling>.fromOpaque(pointer).takeRetainedValue()
            IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDDeviceActivate(device)
        let usages = sibling.usagePairs.map { String(format: "0x%x/0x%x", $0.page, $0.usage) }.joined(separator: ",")
        log("已一併獨占同裝置的其他介面（usage \(usages)）")
    }

    private func siblingPointerActivity() {
        let now = MultiTouchClock.now()
        guard now &- lastReinit > 1_000_000_000 else { return }
        lastReinit = now
        onFallbackDetected?()
    }
}
