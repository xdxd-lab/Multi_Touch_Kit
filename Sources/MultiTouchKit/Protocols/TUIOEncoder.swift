import Foundation

/// OSC 1.0 編碼（TUIO 的傳輸格式）
enum OSC {
    enum Argument: Equatable {
        case int(Int32)
        case float(Float)
        case string(String)
    }

    static func message(_ address: String, _ arguments: [Argument]) -> Data {
        var data = Data()
        appendString(address, to: &data)
        var tags = ","
        for a in arguments {
            switch a {
            case .int: tags += "i"
            case .float: tags += "f"
            case .string: tags += "s"
            }
        }
        appendString(tags, to: &data)
        for a in arguments {
            switch a {
            case .int(let v): appendBigEndian(UInt32(bitPattern: v), to: &data)
            case .float(let v): appendBigEndian(v.bitPattern, to: &data)
            case .string(let v): appendString(v, to: &data)
            }
        }
        return data
    }

    /// 時間標記固定為 1（立即）
    static func bundle(_ elements: [Data]) -> Data {
        var data = Data()
        appendString("#bundle", to: &data)
        appendBigEndian(UInt64(1), to: &data)
        for e in elements {
            appendBigEndian(UInt32(e.count), to: &data)
            data.append(e)
        }
        return data
    }

    /// 字串以 null 結尾，並補齊到 4 位元組倍數
    static func appendString(_ s: String, to data: inout Data) {
        data.append(contentsOf: Array(s.utf8))
        let padding = 4 - (s.utf8.count % 4)
        data.append(contentsOf: [UInt8](repeating: 0, count: padding))
    }

    static func appendBigEndian<T: FixedWidthInteger>(_ v: T, to data: inout Data) {
        withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// TUIO 1.1 `/tuio/2Dcur` 編碼器。座標為 0...1、原點左上，與 Touch 相同。
///
/// 整個 bundle 直接寫進同一個位元組緩衝區（每則訊息的長度先留位置、寫完再回填），
/// 不為每則 OSC 訊息各自配置 Data；輸出與 `OSC.message`／`OSC.bundle` 組出的結果逐位元組相同。
public struct TUIOEncoder: Sendable {
    /// TUIO 1.1 `source` 訊息的內容，建議為「程式名稱@主機名稱」（接收端用來區分多個來源）
    public var source: String {
        didSet { sourceMessage = Self.makeSourceMessage(source) }
    }
    private var frameID: Int32 = 0
    private var last: [UInt64: (x: Double, y: Double, t: UInt64)] = [:]
    /// `source` 訊息每個 frame 都相同，預先編好
    private var sourceMessage: [UInt8]
    private var buffer: [UInt8] = []

    /// - Parameter source: 見 `source`
    public init(source: String) {
        self.source = source
        sourceMessage = Self.makeSourceMessage(source)
    }

    /// - Parameters:
    ///   - alive: 目前所有仍在螢幕上的觸點（跨裝置）
    ///   - updated: 這個 frame 位置有變化或剛按下的觸點
    public mutating func encode(alive: [Touch], updated: [Touch], timestamp: UInt64) -> Data {
        var out = buffer
        buffer = []
        out.removeAll(keepingCapacity: true)
        encode(alive: alive, updated: updated, onlyChanged: false, timestamp: timestamp, into: &out)
        defer { buffer = out }
        return Data(out)
    }

    /// 寫入 `bytes`（先清空、保留容量），mtk-server 每 frame 重複使用同一個緩衝區。
    /// - Parameter onlyChanged: true 時 `updated` 中只取 began／moved（可直接傳 frame.touches）
    package mutating func encode(alive: [Touch], updated: [Touch], onlyChanged: Bool, timestamp: UInt64,
                                 into bytes: inout [UInt8]) {
        // 在 1...Int32.max 循環：TUIO 把 fseq -1 視為特殊值
        frameID = frameID == .max ? 1 : frameID + 1
        bytes.removeAll(keepingCapacity: true)
        bytes.reserveCapacity(96 + sourceMessage.count + alive.count * 4 + updated.count * 60)
        var w = OSCWriter(bytes: bytes)
        bytes = []
        w.append(string: "#bundle")
        w.append(bigEndian: UInt64(1))
        w.append(element: sourceMessage)

        w.beginElement()
        w.append(string: "/tuio/2Dcur")
        w.appendTypeTags(prefix: "s", repeating: "i", count: alive.count)
        w.append(string: "alive")
        for t in alive { w.append(bigEndian: UInt32(bitPattern: Self.sessionID(t))) }
        w.endElement()

        for t in updated where !t.phase.isTerminal {
            if onlyChanged && t.phase != .began && t.phase != .moved { continue }
            var vx = 0.0
            var vy = 0.0
            if let p = last[t.id], timestamp > p.t {
                let dt = Double(timestamp - p.t) / 1e9
                vx = (t.x - p.x) / dt
                vy = (t.y - p.y) / dt
            }
            last[t.id] = (t.x, t.y, timestamp)
            w.beginElement()
            w.append(string: "/tuio/2Dcur")
            w.append(string: ",sifffff")
            w.append(string: "set")
            w.append(bigEndian: UInt32(bitPattern: Self.sessionID(t)))
            w.append(bigEndian: Float(t.x).bitPattern)
            w.append(bigEndian: Float(t.y).bitPattern)
            w.append(bigEndian: Float(vx).bitPattern)
            w.append(bigEndian: Float(vy).bitPattern)
            w.append(bigEndian: Float(0).bitPattern)
            w.endElement()
        }
        // 已離開的觸點不再需要速度基準。先檢查（不配置），只有真的有才重建字典（通常只在放開的那個 frame）
        if last.keys.contains(where: { id in !alive.contains { $0.id == id } }) {
            last = last.filter { entry in alive.contains { $0.id == entry.key } }
        }

        w.beginElement()
        w.append(string: "/tuio/2Dcur")
        w.append(string: ",si")
        w.append(string: "fseq")
        w.append(bigEndian: UInt32(bitPattern: frameID))
        w.endElement()
        bytes = w.bytes
    }

    private static func sessionID(_ t: Touch) -> Int32 {
        Int32(truncatingIfNeeded: t.id & 0x7FFF_FFFF)
    }

    private static func makeSourceMessage(_ source: String) -> [UInt8] {
        [UInt8](OSC.message("/tuio/2Dcur", [.string("source"), .string(source)]))
    }
}

/// OSC bundle 的就地寫入
private struct OSCWriter {
    var bytes: [UInt8]
    private var elementStart = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    /// 以 null 結尾，並補齊到 4 位元組倍數（與 OSC.appendString 相同）
    mutating func append(string: StaticString) {
        let count = string.utf8CodeUnitCount
        bytes.append(contentsOf: UnsafeBufferPointer(start: string.utf8Start, count: count))
        appendPadding(afterStringOf: count)
    }

    mutating func appendTypeTags(prefix: UInt8, repeating tag: UInt8, count: Int) {
        bytes.append(UInt8(ascii: ","))
        bytes.append(prefix)
        for _ in 0..<count { bytes.append(tag) }
        appendPadding(afterStringOf: count + 2)
    }

    private mutating func appendPadding(afterStringOf count: Int) {
        for _ in 0..<(4 - count % 4) { bytes.append(0) }
    }

    mutating func append<T: FixedWidthInteger>(bigEndian v: T) {
        withUnsafeBytes(of: v.bigEndian) { bytes.append(contentsOf: $0) }
    }

    /// 已編好的訊息
    mutating func append(element: [UInt8]) {
        append(bigEndian: UInt32(element.count))
        bytes.append(contentsOf: element)
    }

    /// 先留 4 位元組的長度，`endElement` 時回填
    mutating func beginElement() {
        elementStart = bytes.count
        append(bigEndian: UInt32(0))
    }

    mutating func endElement() {
        let size = UInt32(bytes.count - elementStart - 4).bigEndian
        withUnsafeBytes(of: size) { raw in
            for i in 0..<4 { bytes[elementStart + i] = raw[i] }
        }
    }
}

private extension OSCWriter {
    mutating func appendTypeTags(prefix: StaticString, repeating tag: StaticString, count: Int) {
        appendTypeTags(prefix: prefix.utf8Start.pointee, repeating: tag.utf8Start.pointee, count: count)
    }
}
