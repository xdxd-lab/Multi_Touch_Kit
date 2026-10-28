import Foundation

/// 單一觸點槽位解析出的原始資料
struct RawContact: Sendable, Equatable {
    var contactID: Int
    var tip: Bool
    var x: Double
    var y: Double
    var rawX: Int
    var rawY: Int
    var pressure: Double?
    var width: Double?
    var height: Double?
    var confidence: Bool?
}

/// 一份觸控報告的解析結果
struct ParsedTouchReport: Sendable {
    var contactCount: Int?
    var scanTime: UInt32?
    /// 所有槽位（含未使用的），由 FrameAssembler 依 contactCount 取用
    var slots: [RawContact]
}

/// Windows 相容多點觸控螢幕（HID Digitizer / Touch Screen）的報告格式
struct DigitizerLayout: Sendable {
    struct Slot: Sendable {
        var tip: HIDField?
        var inRange: HIDField?
        var contactID: HIDField?
        var x: HIDField
        var y: HIDField
        var pressure: HIDField?
        var width: HIDField?
        var height: HIDField?
        var confidence: HIDField?
    }

    var reportID: UInt8
    /// 報告資料長度（位元組，不含 report ID）
    var reportLength: Int
    var slots: [Slot]
    var contactCount: HIDField?
    var scanTime: HIDField?
    /// Feature：最大觸點數。Windows 會在列舉時讀取它，部分控制器（例如 ILITEK）讀過才會開始送多點報告
    var maxContactsFeature: HIDField?
    /// Feature：Device Mode（0 滑鼠、1 單點、2 多點）
    var deviceModeFeature: HIDField?

    init?(descriptor: HIDReportDescriptor) {
        let touchFields = descriptor.inputFields.filter { field in
            !field.isConstant && field.collectionPath.contains {
                $0.usagePage == HIDUsage.digitizerPage && $0.usage == HIDUsage.touchScreen
            }
        }
        // 依 report ID 與 Finger collection 分組
        var fingers: [UInt8: [Int: [HIDField]]] = [:]
        for field in touchFields {
            guard let finger = field.collectionPath.last(where: {
                $0.usagePage == HIDUsage.digitizerPage && $0.usage == HIDUsage.finger
            }) else { continue }
            fingers[field.reportID, default: [:]][finger.index, default: []].append(field)
        }
        guard let (reportID, groups) = fingers.max(by: { $0.value.count < $1.value.count }) else { return nil }

        var slots: [Slot] = []
        for (_, fields) in groups.sorted(by: { $0.key < $1.key }) {
            func find(_ page: UInt16, _ usage: UInt16) -> HIDField? { fields.first { $0.isUsage(page, usage) } }
            guard let x = find(HIDUsage.genericDesktopPage, HIDUsage.x),
                  let y = find(HIDUsage.genericDesktopPage, HIDUsage.y) else { continue }
            slots.append(Slot(
                tip: find(HIDUsage.digitizerPage, HIDUsage.tipSwitch),
                inRange: find(HIDUsage.digitizerPage, HIDUsage.inRange),
                contactID: find(HIDUsage.digitizerPage, HIDUsage.contactIdentifier),
                x: x, y: y,
                pressure: find(HIDUsage.digitizerPage, HIDUsage.tipPressure),
                width: find(HIDUsage.digitizerPage, HIDUsage.width),
                height: find(HIDUsage.digitizerPage, HIDUsage.height),
                confidence: find(HIDUsage.digitizerPage, HIDUsage.confidence)))
        }
        guard !slots.isEmpty else { return nil }

        self.reportID = reportID
        self.reportLength = descriptor.reportByteCount(.input, id: reportID)
        self.slots = slots
        let sameReport = touchFields.filter { $0.reportID == reportID }
        self.contactCount = sameReport.first { $0.isUsage(HIDUsage.digitizerPage, HIDUsage.contactCount) }
        self.scanTime = sameReport.first { $0.isUsage(HIDUsage.digitizerPage, HIDUsage.scanTime) }
        let features = descriptor.featureFields.filter { !$0.isConstant }
        self.maxContactsFeature = features.first { $0.isUsage(HIDUsage.digitizerPage, HIDUsage.contactCountMaximum) }
        self.deviceModeFeature = features.first { $0.isUsage(HIDUsage.digitizerPage, HIDUsage.deviceMode) }
    }

    /// `payload` 不含 report ID
    func parse(_ payload: UnsafeBufferPointer<UInt8>) -> ParsedTouchReport {
        var contacts: [RawContact] = []
        contacts.reserveCapacity(slots.count)
        for (index, slot) in slots.enumerated() {
            let rawX = slot.x.value(in: payload)
            let rawY = slot.y.value(in: payload)
            let inRange = slot.inRange.map { $0.value(in: payload) != 0 }
            let tip = slot.tip.map { $0.value(in: payload) != 0 } ?? inRange ?? true
            contacts.append(RawContact(
                contactID: slot.contactID.map { Int($0.value(in: payload)) } ?? index,
                tip: tip,
                x: slot.x.normalized(rawX),
                y: slot.y.normalized(rawY),
                rawX: Int(rawX),
                rawY: Int(rawY),
                pressure: slot.pressure.map { $0.normalized($0.value(in: payload)) },
                width: slot.width.map { $0.normalized($0.value(in: payload)) },
                height: slot.height.map { $0.normalized($0.value(in: payload)) },
                confidence: slot.confidence.map { $0.value(in: payload) != 0 }))
        }
        return ParsedTouchReport(
            contactCount: contactCount.map { Int($0.value(in: payload)) },
            scanTime: scanTime.map { UInt32(truncatingIfNeeded: $0.value(in: payload)) },
            slots: contacts)
    }
}
