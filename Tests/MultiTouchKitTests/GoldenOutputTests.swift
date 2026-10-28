import Foundation
import Testing
@testable import MultiTouchKit

/// mtk-server 輸出格式的 golden 測試：效能重構（手寫格式化、單一緩衝區）前後必須逐位元組相同。
/// - golden：固定輸入的完整輸出（由 b80ac9e 的實作產生）
/// - 性質測試：與下方保留的參考實作（b80ac9e 原樣）比對大量亂數輸入
@Suite struct GoldenOutputTests {
    static let frame = TouchFrame(deviceID: 2, sequence: 41, timestamp: 1_234_567_890_123, scanTime: 6553, touches: [
        Touch(id: 7, contactID: 3, phase: .began, x: 0.123455, y: 0.999995, rawX: 1185, rawY: 9599,
              pressure: 0.5, width: 0.0000049999, height: 1, confidence: false),
        Touch(id: 8, contactID: 0, phase: .stationary, x: 0, y: 1, rawX: 0, rawY: 9600),
    ])

    @Test func jsonFrameGolden() {
        // 0.123455 → 0.12345、0.999995 → 0.99999：%.5f 依二進位值精確四捨五入
        #expect(TouchJSON.frame(Self.frame) == #"{"type":"frame","v":1,"device":2,"seq":41,"t":1234567890123,"scan":6553,"touches":[{"id":7,"cid":3,"phase":"began","x":0.12345,"y":0.99999,"rx":1185,"ry":9599,"p":0.50000,"w":0.00000,"h":1.00000,"conf":false},{"id":8,"cid":0,"phase":"stationary","x":0.00000,"y":1.00000,"rx":0,"ry":9600}]}"#)
    }

    @Test func jsonEmptyFrame() {
        let f = TouchFrame(deviceID: 0, sequence: 0, timestamp: 0, scanTime: nil, touches: [])
        #expect(TouchJSON.frame(f) == #"{"type":"frame","v":1,"device":0,"seq":0,"t":0,"touches":[]}"#)
    }

    @Test func numberEdgeCasesMatchPrintf() {
        let values: [Double] = [0, 1, 0.5, 0.000005, 0.0000049999, 0.0000050001, 0.123455, 0.999995, 0.9999949,
                                0.99999500001, 1e-7, 1.0 / 3, 2.0 / 3, 0.000015, 0.000025, 0.125, 0.999999999,
                                Double.leastNonzeroMagnitude, 0.1 + 0.2, 0.00001, 0.99999,
                                // 範圍外與特殊值走 String(format:) 後備路徑
                                -0.0, -0.3, 1.5, 123.456, .nan, .infinity, -.infinity, 1.0.nextUp]
        for v in values { #expect(TouchJSON.number(v) == String(format: "%.5f", v), "v=\(v)") }
    }

    @Test func numberRandomMatchesPrintf() {
        var rng = SplitMix64(seed: 0x6A50_4E)
        for _ in 0..<200_000 {
            let v = Double(rng.next() >> 11) / Double(1 << 53) // [0, 1)
            #expect(TouchJSON.number(v) == String(format: "%.5f", v))
        }
        // 5 位小數的 tie 附近（x.xxxxx5 ± 幾個 ulp）
        for k in 0..<100_000 {
            let tie = (Double(k) + 0.5) / 100_000
            for v in [tie.nextDown, tie, tie.nextUp] where v <= 1 {
                #expect(TouchJSON.number(v) == String(format: "%.5f", v), "v=\(v)")
            }
        }
    }

    @Test func jsonFrameRandomMatchesReference() {
        var rng = SplitMix64(seed: 0x4A53_4F4E)
        let phases: [TouchPhase] = [.began, .moved, .stationary, .ended, .cancelled]
        for seq in 0..<5000 {
            let touches = (0..<Int(rng.next() % 11)).map { i in
                Touch(id: rng.next() >> 20, contactID: i, phase: phases[Int(rng.next() % 5)],
                      x: rng.unit(), y: rng.unit(), rawX: Int(rng.next() % 9601), rawY: Int(rng.next() % 9601),
                      pressure: rng.next() % 2 == 0 ? rng.unit() : nil, width: rng.next() % 3 == 0 ? rng.unit() : nil,
                      height: rng.next() % 3 == 0 ? rng.unit() : nil, confidence: rng.next() % 4 == 0 ? (rng.next() % 2 == 0) : nil)
            }
            let f = TouchFrame(deviceID: Int(rng.next() % 4), sequence: UInt64(seq), timestamp: rng.next() >> 1,
                               scanTime: rng.next() % 2 == 0 ? UInt32(truncatingIfNeeded: rng.next()) : nil, touches: touches)
            #expect(TouchJSON.frame(f) == ReferenceTouchJSON.frame(f))
        }
    }

    @Test func jsonDeviceAndHelloEscaping() {
        let info = MultiTouchDeviceInfo(id: 1, vendorID: 0x222A, productID: 1, manufacturer: "IL\"I\\TEK\n\t\u{01}",
                                        product: "觸控 🖐 Panel\r", serialNumber: "", locationID: 0, maxContacts: 10,
                                        slotsPerReport: 10, physicalWidthMillimeters: 309.3, physicalHeightMillimeters: nil,
                                        hasScanTime: true, exclusive: true)
        #expect(TouchJSON.device(info, event: "added") == #"{"type":"device","v":1,"event":"added","device":{"id":1,"vendorId":8746,"productId":1,"manufacturer":"IL\"I\\TEK\n\t\u0001","product":"觸控 🖐 Panel\r","maxContacts":10,"slotsPerReport":10,"widthMM":309.3,"exclusive":true}}"#)
        #expect(TouchJSON.hello(server: "mtk-server", devices: [info]) == ReferenceTouchJSON.hello(server: "mtk-server", devices: [info]))
    }

    // MARK: - TUIO

    /// began → moved（有速度）→ 全部離開
    static func tuioSequence(_ encode: (inout TUIOEncoder, [Touch], [Touch], UInt64) -> Data) -> [String] {
        var tuio = TUIOEncoder(source: "MultiTouchKit@host")
        let a = Touch(id: 7, contactID: 3, phase: .began, x: 0.25, y: 0.5, rawX: 1, rawY: 2)
        var b = a; b.phase = .moved; b.x = 0.3
        var c = b; c.phase = .ended
        return [encode(&tuio, [a], [a], 1_000_000_000), encode(&tuio, [b], [b], 1_010_000_000),
                encode(&tuio, [], [c], 1_020_000_000)].map { $0.map { String(format: "%02x", $0) }.joined() }
    }

    @Test func tuioGolden() {
        let hex = Self.tuioSequence { $0.encode(alive: $1, updated: $2, timestamp: $3) }
        #expect(hex == [
            "2362756e646c650000000000000000010000002c2f7475696f2f3244637572002c737300736f7572636500004d756c7469546f7563684b697440686f737400000000001c2f7475696f2f3244637572002c736900616c69766500000000000007000000342f7475696f2f3244637572002c736966666666660000000073657400000000073e8000003f0000000000000000000000000000000000001c2f7475696f2f3244637572002c736900667365710000000000000001",
            "2362756e646c650000000000000000010000002c2f7475696f2f3244637572002c737300736f7572636500004d756c7469546f7563684b697440686f737400000000001c2f7475696f2f3244637572002c736900616c69766500000000000007000000342f7475696f2f3244637572002c736966666666660000000073657400000000073e99999a3f00000040a0000000000000000000000000001c2f7475696f2f3244637572002c736900667365710000000000000002",
            "2362756e646c650000000000000000010000002c2f7475696f2f3244637572002c737300736f7572636500004d756c7469546f7563684b697440686f73740000000000182f7475696f2f3244637572002c730000616c6976650000000000001c2f7475696f2f3244637572002c736900667365710000000000000003",
        ])
    }

    /// mtk-server 用的就地版本（onlyChanged：直接傳 frame.touches）與公開版本＋手動過濾相同
    @Test func tuioInPlaceMatchesPublic() {
        var a = TUIOEncoder(source: "src")
        var b = TUIOEncoder(source: "src")
        var bytes: [UInt8] = []
        let t1 = Touch(id: 1, contactID: 0, phase: .began, x: 0.1, y: 0.2, rawX: 0, rawY: 0)
        var t2 = Touch(id: 2, contactID: 1, phase: .stationary, x: 0.3, y: 0.4, rawX: 0, rawY: 0)
        for step in 0..<3 {
            var m = t1; m.phase = step == 0 ? .began : .moved; m.x += 0.01 * Double(step)
            t2.phase = step == 2 ? .ended : .stationary
            let frame = [m, t2]
            let alive = frame.filter { !$0.phase.isTerminal }
            let expected = a.encode(alive: alive, updated: frame.filter { $0.phase == .began || $0.phase == .moved },
                                    timestamp: UInt64(step + 1) * 8_000_000)
            b.encode(alive: alive, updated: frame, onlyChanged: true, timestamp: UInt64(step + 1) * 8_000_000, into: &bytes)
            #expect(Data(bytes) == expected)
        }
    }

    @Test func tuioRandomMatchesReference() {
        var rng = SplitMix64(seed: 0x5455_494F)
        var tuio = TUIOEncoder(source: "src")
        var reference = ReferenceTUIOEncoder(source: "src")
        var active: [UInt64: Touch] = [:]
        var nextID: UInt64 = 1
        var time: UInt64 = 1_000_000_000
        for _ in 0..<5000 {
            time += 8_000_000 + rng.next() % 1_000_000
            var updated: [Touch] = []
            for (id, var t) in active {
                switch rng.next() % 6 {
                case 0: t.phase = .ended; active[id] = nil
                case 1, 2: t.phase = .moved; t.x = rng.unit(); t.y = rng.unit(); active[id] = t
                default: t.phase = .stationary; active[id] = t
                }
                updated.append(t)
            }
            if active.count < 10, rng.next() % 3 == 0 {
                let t = Touch(id: nextID, contactID: 0, phase: .began, x: rng.unit(), y: rng.unit(), rawX: 0, rawY: 0)
                nextID += 1
                active[t.id] = t
                updated.append(t)
            }
            let alive = active.values.sorted { $0.id < $1.id }
            let changed = updated.filter { $0.phase == .began || $0.phase == .moved }
            #expect(tuio.encode(alive: alive, updated: changed, timestamp: time)
                    == reference.encode(alive: alive, updated: changed, timestamp: time))
        }
    }
}

extension SplitMix64 {
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - 參考實作（b80ac9e 原樣保留，只供比對；不要修改）

enum ReferenceTouchJSON {
    static func frame(_ frame: TouchFrame) -> String {
        var s = "{\"type\":\"frame\",\"v\":\(TouchJSON.protocolVersion),\"device\":\(frame.deviceID),\"seq\":\(frame.sequence),\"t\":\(frame.timestamp)"
        if let scan = frame.scanTime { s += ",\"scan\":\(scan)" }
        s += ",\"touches\":["
        for (i, t) in frame.touches.enumerated() {
            if i > 0 { s += "," }
            s += "{\"id\":\(t.id),\"cid\":\(t.contactID),\"phase\":\"\(t.phase)\","
            s += "\"x\":" + number(t.x) + ",\"y\":" + number(t.y) + ",\"rx\":\(t.rawX),\"ry\":\(t.rawY)"
            if let p = t.pressure { s += ",\"p\":" + number(p) }
            if let w = t.width { s += ",\"w\":" + number(w) }
            if let h = t.height { s += ",\"h\":" + number(h) }
            if let c = t.confidence { s += ",\"conf\":\(c)" }
            s += "}"
        }
        return s + "]}"
    }

    static func hello(server: String, devices: [MultiTouchDeviceInfo]) -> String {
        "{\"type\":\"hello\",\"v\":\(TouchJSON.protocolVersion),\"server\":\"\(TouchJSON.escape(server))\",\"version\":\"\(MultiTouchKitVersion.string)\",\"devices\":["
            + devices.map(TouchJSON.deviceObject).joined(separator: ",") + "]}"
    }

    static func number(_ v: Double) -> String { String(format: "%.5f", v) }
}

struct ReferenceTUIOEncoder {
    var source: String
    private var frameID: Int32 = 0
    private var last: [UInt64: (x: Double, y: Double, t: UInt64)] = [:]

    init(source: String) { self.source = source }

    mutating func encode(alive: [Touch], updated: [Touch], timestamp: UInt64) -> Data {
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

    private func sessionID(_ t: Touch) -> Int32 { Int32(truncatingIfNeeded: t.id & 0x7FFF_FFFF) }
}
