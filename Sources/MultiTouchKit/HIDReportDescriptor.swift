import Foundation

/// HID 報告的種類
public enum HIDReportKind: Sendable, Hashable {
    case input
    case output
    case feature
}

/// 描述元中的一個 collection
public struct HIDCollection: Sendable, Equatable {
    /// 在整份描述元中的流水號，用來區分同 usage 的不同 collection（例如 10 個 Finger）
    public var index: Int
    /// 0 = Physical、1 = Application、2 = Logical …
    public var type: UInt8
    public var usagePage: UInt16
    public var usage: UInt16
}

/// 報告中的一個欄位（對應一個 usage）
public struct HIDField: Sendable, Equatable {
    public var kind: HIDReportKind
    public var reportID: UInt8
    public var usagePage: UInt16
    public var usage: UInt16
    /// 從 report 資料起點算起的位元位移（不含 report ID 位元組）
    public var bitOffset: Int
    public var bitSize: Int
    public var logicalMin: Int64
    public var logicalMax: Int64
    public var physicalMin: Int64
    public var physicalMax: Int64
    public var unitExponent: Int8
    public var unit: UInt32
    public var isConstant: Bool
    public var isVariable: Bool
    public var isRelative: Bool
    /// 由外到內的 collection 鏈
    public var collectionPath: [HIDCollection]

    public func isUsage(_ page: UInt16, _ usage: UInt16) -> Bool {
        usagePage == page && self.usage == usage
    }

    /// 讀取欄位值；`payload` 不含 report ID
    public func value(in payload: UnsafeBufferPointer<UInt8>) -> Int64 {
        guard bitSize > 0, bitSize <= 64 else { return 0 }
        var raw: UInt64 = 0
        for i in 0..<bitSize {
            let bit = bitOffset + i
            let byte = bit >> 3
            guard byte < payload.count else { break }
            if payload[byte] & (1 << UInt8(bit & 7)) != 0 { raw |= 1 << UInt64(i) }
        }
        if logicalMin < 0, bitSize < 64, raw & (1 << UInt64(bitSize - 1)) != 0 {
            return Int64(bitPattern: raw | ~((1 << UInt64(bitSize)) - 1))
        }
        return Int64(bitPattern: raw)
    }

    public func value(in payload: [UInt8]) -> Int64 {
        payload.withUnsafeBufferPointer { value(in: $0) }
    }

    /// 寫入欄位值；`payload` 不含 report ID
    public func write(_ value: Int64, into payload: inout [UInt8]) {
        let raw = UInt64(bitPattern: value)
        for i in 0..<bitSize {
            let bit = bitOffset + i
            let byte = bit >> 3
            guard byte < payload.count else { break }
            let mask = UInt8(1 << (bit & 7))
            if raw & (1 << UInt64(i)) != 0 {
                payload[byte] |= mask
            } else {
                payload[byte] &= ~mask
            }
        }
    }

    /// 依邏輯範圍正規化到 0...1
    public func normalized(_ value: Int64) -> Double {
        let range = Double(logicalMax - logicalMin)
        guard range > 0 else { return 0 }
        return min(max((Double(value) - Double(logicalMin)) / range, 0), 1)
    }

    /// 實體長度（公釐）；單位不是公分或英吋時回傳 nil
    public var physicalLengthMillimeters: Double? {
        let span = Double(physicalMax - physicalMin)
        guard span > 0 else { return nil }
        let scaled = span * pow(10, Double(unitExponent))
        switch unit {
        case 0x11: return scaled * 10 // SI 線性：公分
        case 0x13: return scaled * 25.4 // English 線性：英吋
        default: return nil
        }
    }
}

public enum HIDDescriptorError: Error, Sendable {
    case truncated(offset: Int)
}

/// HID 報告描述元解析器（HID 1.11 §6.2.2），只處理觸控需要的項目
public struct HIDReportDescriptor: Sendable {
    public private(set) var fields: [HIDField] = []
    public private(set) var usesReportIDs = false
    private var reportBits: [ReportKey: Int] = [:]

    private struct ReportKey: Hashable, Sendable {
        var kind: HIDReportKind
        var id: UInt8
    }

    private struct Globals {
        var usagePage: UInt16 = 0
        var logicalMin: Int64 = 0
        var logicalMax: Int64 = 0
        var logicalMaxUnsigned: Int64 = 0
        var physicalMin: Int64 = 0
        var physicalMax: Int64 = 0
        var physicalMaxUnsigned: Int64 = 0
        var unitExponent: Int8 = 0
        var unit: UInt32 = 0
        var reportSize = 0
        var reportID: UInt8 = 0
        var reportCount = 0
    }

    public var inputFields: [HIDField] { fields.filter { $0.kind == .input } }
    public var featureFields: [HIDField] { fields.filter { $0.kind == .feature } }

    /// 報告資料長度（位元組，不含 report ID）
    public func reportByteCount(_ kind: HIDReportKind, id: UInt8) -> Int {
        ((reportBits[ReportKey(kind: kind, id: id)] ?? 0) + 7) / 8
    }

    public init(bytes: [UInt8]) throws {
        var g = Globals()
        var globalStack: [Globals] = []
        var usages: [(page: UInt16, usage: UInt16)] = []
        var usageMin: (page: UInt16, usage: UInt16)?
        var usageMax: UInt16?
        var collections: [HIDCollection] = []
        var collectionCounter = 0

        func clearLocals() {
            usages.removeAll()
            usageMin = nil
            usageMax = nil
        }

        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE { // long item：跳過
                guard i + 2 < bytes.count else { throw HIDDescriptorError.truncated(offset: i) }
                i += 3 + Int(bytes[i + 1])
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let size = sizeCode == 3 ? 4 : sizeCode
            let type = (prefix >> 2) & 0x03
            let tag = (prefix >> 4) & 0x0F
            guard i + 1 + size <= bytes.count else { throw HIDDescriptorError.truncated(offset: i) }
            var u: UInt32 = 0
            for k in 0..<size { u |= UInt32(bytes[i + 1 + k]) << (8 * UInt32(k)) }
            let s: Int64
            switch size {
            case 1: s = Int64(Int8(truncatingIfNeeded: u))
            case 2: s = Int64(Int16(truncatingIfNeeded: u))
            case 4: s = Int64(Int32(bitPattern: u))
            default: s = 0
            }
            i += 1 + size

            switch type {
            case 0: // Main
                switch tag {
                case 0x8, 0x9, 0xB:
                    let kind: HIDReportKind = tag == 0x8 ? .input : (tag == 0x9 ? .output : .feature)
                    var list = usages
                    if let lo = usageMin, let hi = usageMax, hi >= lo.usage {
                        let upper = min(Int(hi), Int(lo.usage) + max(g.reportCount, 1) - 1)
                        for v in Int(lo.usage)...upper { list.append((lo.page, UInt16(v))) }
                    }
                    let isVariable = u & 0x02 != 0
                    let key = ReportKey(kind: kind, id: g.reportID)
                    let start = reportBits[key] ?? 0
                    // 邏輯最小值 ≥ 0 但最大值被符號延伸成負數時，視為無號數（常見的描述元寫法錯誤）
                    let lmax = g.logicalMin >= 0 && g.logicalMax < 0 ? g.logicalMaxUnsigned : g.logicalMax
                    let pmax = g.physicalMin >= 0 && g.physicalMax < 0 ? g.physicalMaxUnsigned : g.physicalMax
                    for n in 0..<g.reportCount {
                        let usage = isVariable
                            ? (list.isEmpty ? (g.usagePage, UInt16(0)) : list[min(n, list.count - 1)])
                            : (list.first ?? (g.usagePage, 0))
                        fields.append(HIDField(
                            kind: kind, reportID: g.reportID, usagePage: usage.0, usage: usage.1,
                            bitOffset: start + n * g.reportSize, bitSize: g.reportSize,
                            logicalMin: g.logicalMin, logicalMax: lmax,
                            physicalMin: g.physicalMin, physicalMax: pmax,
                            unitExponent: g.unitExponent, unit: g.unit,
                            isConstant: u & 0x01 != 0, isVariable: isVariable, isRelative: u & 0x04 != 0,
                            collectionPath: collections))
                    }
                    reportBits[key] = start + g.reportSize * g.reportCount
                    if g.reportID != 0 { usesReportIDs = true }
                    clearLocals()
                case 0xA:
                    let usage = usages.first ?? (g.usagePage, 0)
                    collections.append(HIDCollection(index: collectionCounter, type: UInt8(truncatingIfNeeded: u),
                                                     usagePage: usage.page, usage: usage.usage))
                    collectionCounter += 1
                    clearLocals()
                case 0xC:
                    _ = collections.popLast()
                    clearLocals()
                default:
                    break
                }
            case 1: // Global
                switch tag {
                case 0x0: g.usagePage = UInt16(truncatingIfNeeded: u)
                case 0x1: g.logicalMin = s
                case 0x2: g.logicalMax = s; g.logicalMaxUnsigned = Int64(u)
                case 0x3: g.physicalMin = s
                case 0x4: g.physicalMax = s; g.physicalMaxUnsigned = Int64(u)
                case 0x5: g.unitExponent = u <= 0xF ? Int8(u >= 8 ? Int(u) - 16 : Int(u)) : Int8(truncatingIfNeeded: s)
                case 0x6: g.unit = u
                case 0x7: g.reportSize = Int(u)
                case 0x8: g.reportID = UInt8(truncatingIfNeeded: u)
                case 0x9: g.reportCount = Int(u)
                case 0xA: globalStack.append(g)
                case 0xB: g = globalStack.popLast() ?? g
                default: break
                }
            case 2: // Local
                let page = size == 4 ? UInt16(u >> 16) : g.usagePage
                let usage = UInt16(truncatingIfNeeded: u)
                switch tag {
                case 0x0: usages.append((page, usage))
                case 0x1: usageMin = (page, usage)
                case 0x2: usageMax = usage
                default: break
                }
            default:
                break
            }
        }
    }
}
