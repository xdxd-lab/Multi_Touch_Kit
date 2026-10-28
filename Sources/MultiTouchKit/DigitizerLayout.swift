import Foundation

/// HID Usage 常數（只列出用到的）
enum HIDUsage {
    static let genericDesktopPage: UInt16 = 0x01
    static let x: UInt16 = 0x30
    static let y: UInt16 = 0x31
    static let mouse: UInt16 = 0x02
    static let pointer: UInt16 = 0x01

    static let digitizerPage: UInt16 = 0x0D
    static let touchScreen: UInt16 = 0x04
    static let finger: UInt16 = 0x22
    static let tipPressure: UInt16 = 0x30
    static let inRange: UInt16 = 0x32
    static let tipSwitch: UInt16 = 0x42
    static let confidence: UInt16 = 0x47
    static let width: UInt16 = 0x48
    static let height: UInt16 = 0x49
    static let contactIdentifier: UInt16 = 0x51
    static let deviceMode: UInt16 = 0x52
    static let contactCount: UInt16 = 0x54
    static let contactCountMaximum: UInt16 = 0x55
    static let scanTime: UInt16 = 0x56
}

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

/// 把一或多份報告組成完整 frame（處理 Microsoft 規範的 hybrid mode）
struct FrameAssembler: Sendable {
    private var remaining = 0
    private var pending: [RawContact] = []
    private var frameStart: UInt64 = 0

    /// 回傳完成的 frame（觸點清單與第一份報告的時間）；frame 尚未收齊時回傳 nil
    mutating func add(_ report: ParsedTouchReport, timestamp: UInt64) -> (contacts: [RawContact], timestamp: UInt64)? {
        guard let count = report.contactCount else {
            // 沒有 Contact Count 欄位：每份報告就是一個 frame，略過空槽位
            let used = report.slots.filter { $0.tip }
            return (used, timestamp)
        }
        if count > 0 {
            frameStart = timestamp
            let take = min(count, report.slots.count)
            pending = Array(report.slots.prefix(take))
            remaining = count - take
        } else if remaining > 0 {
            let take = min(remaining, report.slots.count)
            pending += report.slots.prefix(take)
            remaining -= take
        } else {
            // Contact Count = 0 且沒有待補資料：所有手指都已離開
            pending = []
            frameStart = timestamp
        }
        guard remaining == 0 else { return nil }
        defer { pending = [] }
        return (pending, frameStart)
    }
}

/// 把每個 frame 的觸點轉成帶有 began／moved／ended 的 Touch
/// 報告中斷偵測：ILITEK 在手指全部離開時只送最後一筆 tip=0 就停止回報；那筆遺失（USB 異常、睡眠）時，
/// 觸點會永遠停在「按下」。有觸點時超過 `timeout` 沒有任何報告就應全部取消。
struct ReportTimeoutMonitor: Sendable {
    /// 秒；0 = 關閉
    var timeout: Double
    private(set) var lastReport: UInt64 = 0

    init(timeout: Double) {
        self.timeout = timeout
    }

    mutating func reportReceived(at time: UInt64) { lastReport = time }

    /// 已超過時間沒有報告（只在仍有觸點時有意義）
    func isExpired(at now: UInt64, hasActiveTouches: Bool) -> Bool {
        timeout > 0 && hasActiveTouches && Double(now &- lastReport) / 1e9 > timeout
    }

    func silence(at now: UInt64) -> Double { Double(now &- lastReport) / 1e9 }
}

struct ContactTracker: Sendable {
    /// 長時間完全不動的觸點（線材、物體碰到電容面板造成的幽靈觸點）的處理
    struct StalePolicy: Sendable, Equatable {
        /// 秒；0 = 關閉
        var timeout: Double = 0
        /// 正規化座標；偏離錨點不超過此值都算「不動」
        var tolerance: Double = 0.003
        /// 被取消的觸點再移動超過此距離（正規化）就視為新的觸碰
        var reviveDistance: Double = 0.02
    }

    var stalePolicy = StalePolicy()
    private(set) var active: [Int: Touch] = [:]
    /// 錨點：最後一次「明顯移動」的位置與時間（奈秒）
    private var anchors: [Int: (x: Double, y: Double, time: UInt64)] = [:]
    /// 已因長時間不動而取消、但控制器仍回報按下的 contact（記錄取消時的位置）
    private(set) var suppressed: [Int: (x: Double, y: Double)] = [:]

    /// 這個 frame 出現過的 contact（每次呼叫重複使用，避免每 frame 配置；最多約 10 筆，線性搜尋比 Set 快）
    private var seen: [Int] = []

    var hasActiveTouches: Bool { !active.isEmpty }

    /// - Parameter time: frame 時間（奈秒）；0 時不做長時間不動的判斷
    mutating func update(_ contacts: [RawContact], at time: UInt64 = 0, allocateID: () -> UInt64) -> [Touch] {
        var out: [Touch] = []
        out.reserveCapacity(max(contacts.count, active.count))
        seen.removeAll(keepingCapacity: true)
        let checkStale = stalePolicy.timeout > 0 && time > 0
        for c in contacts {
            guard !seen.contains(c.contactID) else { continue }
            seen.append(c.contactID)
            if c.tip {
                if let s = suppressed[c.contactID] {
                    // 幽靈觸點：明顯移動才當成新的觸碰，否則忽略
                    guard hypot(c.x - s.x, c.y - s.y) > stalePolicy.reviveDistance else { continue }
                    suppressed[c.contactID] = nil
                }
                if var t = active[c.contactID] {
                    t.phase = (t.rawX != c.rawX || t.rawY != c.rawY) ? .moved : .stationary
                    t.apply(c)
                    if checkStale, let a = anchors[c.contactID] {
                        if abs(c.x - a.x) > stalePolicy.tolerance || abs(c.y - a.y) > stalePolicy.tolerance {
                            anchors[c.contactID] = (c.x, c.y, time)
                        } else if Double(time &- a.time) / 1e9 >= stalePolicy.timeout {
                            t.phase = .cancelled
                            active[c.contactID] = nil
                            anchors[c.contactID] = nil
                            suppressed[c.contactID] = (c.x, c.y)
                            out.append(t)
                            continue
                        }
                    }
                    active[c.contactID] = t
                    out.append(t)
                } else {
                    var t = Touch(id: allocateID(), contactID: c.contactID, phase: .began,
                                  x: c.x, y: c.y, rawX: c.rawX, rawY: c.rawY)
                    t.apply(c)
                    active[c.contactID] = t
                    if checkStale { anchors[c.contactID] = (c.x, c.y, time) }
                    out.append(t)
                }
            } else {
                suppressed[c.contactID] = nil
                anchors[c.contactID] = nil
                if var t = active.removeValue(forKey: c.contactID) {
                    // 放開時部分控制器會回報 0,0，保留最後的有效位置
                    t.phase = .ended
                    out.append(t)
                }
            }
        }
        // 沒出現在這個 frame 的觸點視為已放開（依觸點 id 排序；先檢查，平常沒有就不必排序）
        if active.keys.contains(where: { !seen.contains($0) }) {
            for (cid, t) in active.sorted(by: { $0.value.id < $1.value.id }) where !seen.contains(cid) {
                var ended = t
                ended.phase = .ended
                active[cid] = nil
                anchors[cid] = nil
                out.append(ended)
            }
        }
        if suppressed.keys.contains(where: { !seen.contains($0) }) {
            for cid in Array(suppressed.keys) where !seen.contains(cid) { suppressed[cid] = nil }
        }
        return out
    }

    /// 裝置移除或停止時，把仍在螢幕上的觸點全部取消
    mutating func cancelAll() -> [Touch] {
        let out = active.values.sorted { $0.id < $1.id }.map { t -> Touch in
            var c = t
            c.phase = .cancelled
            return c
        }
        active.removeAll()
        anchors.removeAll()
        return out
    }
}

private extension Touch {
    mutating func apply(_ c: RawContact) {
        x = c.x
        y = c.y
        rawX = c.rawX
        rawY = c.rawY
        pressure = c.pressure
        width = c.width
        height = c.height
        confidence = c.confidence
    }
}
