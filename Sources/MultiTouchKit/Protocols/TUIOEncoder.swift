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
public struct TUIOEncoder: Sendable {
    public var source: String
    private var frameID: Int32 = 0
    private var last: [UInt64: (x: Double, y: Double, t: UInt64)] = [:]

    public init(source: String) {
        self.source = source
    }

    /// - Parameters:
    ///   - alive: 目前所有仍在螢幕上的觸點（跨裝置）
    ///   - updated: 這個 frame 位置有變化或剛按下的觸點
    public mutating func encode(alive: [Touch], updated: [Touch], timestamp: UInt64) -> Data {
        // 在 1...Int32.max 循環：TUIO 把 fseq -1 視為特殊值
        frameID = frameID == .max ? 1 : frameID + 1
        var elements: [Data] = [
            OSC.message("/tuio/2Dcur", [.string("source"), .string(source)]),
            OSC.message("/tuio/2Dcur", [.string("alive")] + alive.map { .int(sessionID($0)) }),
        ]
        for t in updated where !t.phase.isTerminal {
            var vx = 0.0
            var vy = 0.0
            if let p = last[t.id], timestamp > p.t {
                let dt = Double(timestamp - p.t) / 1e9
                vx = (t.x - p.x) / dt
                vy = (t.y - p.y) / dt
            }
            last[t.id] = (t.x, t.y, timestamp)
            elements.append(OSC.message("/tuio/2Dcur", [
                .string("set"), .int(sessionID(t)), .float(Float(t.x)), .float(Float(t.y)),
                .float(Float(vx)), .float(Float(vy)), .float(0),
            ]))
        }
        let aliveIDs = Set(alive.map(\.id))
        last = last.filter { aliveIDs.contains($0.key) }
        elements.append(OSC.message("/tuio/2Dcur", [.string("fseq"), .int(frameID)]))
        return OSC.bundle(elements)
    }

    private func sessionID(_ t: Touch) -> Int32 {
        Int32(truncatingIfNeeded: t.id & 0x7FFF_FFFF)
    }
}
