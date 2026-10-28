import Foundation

/// mtk-server 在 UDP 與 WebSocket 上使用的 JSON 訊息格式（見 docs/server-protocol.md）。
/// 刻意不用 JSONEncoder：格式固定、欄位順序穩定。每 frame 的 frame 訊息直接寫入位元組（`frameBytes`），
/// 輸出由 GoldenOutputTests 保證與原本以 `String(format:)` 組字串的版本逐位元組相同。
public enum TouchJSON {
    /// 每則訊息的 `v` 欄位；只在格式不相容地改變時遞增（新增欄位不算）
    public static let protocolVersion = 1

    /// `type: frame` 訊息：一個 TouchFrame 的所有觸點
    public static func frame(_ frame: TouchFrame) -> String {
        var bytes: [UInt8] = []
        frameBytes(frame, into: &bytes)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 與 `frame(_:)` 相同的內容（UTF-8），附加到 `bytes` 尾端。mtk-server 每 frame 重複使用同一個緩衝區，
    /// 不經過 String／NSString：125 Hz × 10 指時每秒約 6000 個數字，`String(format:)` 是主要成本
    package static func frameBytes(_ frame: TouchFrame, into bytes: inout [UInt8]) {
        var w = ByteWriter(bytes: bytes)
        bytes = []
        w.reserve(96 + frame.touches.count * 128)
        w.append("{\"type\":\"frame\",\"v\":")
        w.append(protocolVersion)
        w.append(",\"device\":")
        w.append(frame.deviceID)
        w.append(",\"seq\":")
        w.append(frame.sequence)
        w.append(",\"t\":")
        w.append(frame.timestamp)
        if let scan = frame.scanTime {
            w.append(",\"scan\":")
            w.append(UInt64(scan))
        }
        w.append(",\"touches\":[")
        for (i, t) in frame.touches.enumerated() {
            if i > 0 { w.append(",") }
            w.append("{\"id\":")
            w.append(t.id)
            w.append(",\"cid\":")
            w.append(t.contactID)
            w.append(",\"phase\":\"")
            w.append(phaseName(t.phase))
            w.append("\",\"x\":")
            w.appendFixed5(t.x)
            w.append(",\"y\":")
            w.appendFixed5(t.y)
            w.append(",\"rx\":")
            w.append(t.rawX)
            w.append(",\"ry\":")
            w.append(t.rawY)
            if let p = t.pressure {
                w.append(",\"p\":")
                w.appendFixed5(p)
            }
            if let width = t.width {
                w.append(",\"w\":")
                w.appendFixed5(width)
            }
            if let h = t.height {
                w.append(",\"h\":")
                w.appendFixed5(h)
            }
            if let c = t.confidence { w.append(c ? ",\"conf\":true" : ",\"conf\":false") }
            // 套用觸控校正時附上校正前的座標（校正工具以它收集原始位置）
            if let ux = t.uncalibratedX, let uy = t.uncalibratedY {
                w.append(",\"ux\":")
                w.appendFixed5(ux)
                w.append(",\"uy\":")
                w.appendFixed5(uy)
            }
            w.append("}")
        }
        w.append("]}")
        bytes = w.bytes
    }

    /// `type: device` 訊息；`event` 為 added／removed／reinitialized
    public static func device(_ info: MultiTouchDeviceInfo, event: String) -> String {
        "{\"type\":\"device\",\"v\":\(protocolVersion),\"event\":\"\(escape(event))\",\"device\":\(deviceObject(info))}"
    }

    /// WebSocket 用戶端連線時送出的 `type: hello` 訊息：伺服器版本、目前的裝置與觸控螢幕所在的顯示器
    public static func hello(server: String, devices: [MultiTouchDeviceInfo], display: DisplayInfo? = nil) -> String {
        var s = "{\"type\":\"hello\",\"v\":\(protocolVersion),\"server\":\"\(escape(server))\",\"version\":\"\(MultiTouchKitVersion.string)\",\"devices\":["
            + devices.map(deviceObject).joined(separator: ",") + "]"
        if let display { s += ",\"display\":" + displayObject(display) }
        return s + "}"
    }

    /// `type: display` 訊息：觸控螢幕對應的顯示器改變了（觸控螢幕晚於 mtk-server 接上、顯示器重新排列等）。
    /// 內容與 hello 的 `display` 欄位相同；找不到顯示器時為 null
    public static func display(_ display: DisplayInfo?) -> String {
        "{\"type\":\"display\",\"v\":\(protocolVersion),\"display\":" + (display.map(displayObject) ?? "null") + "}"
    }

    /// 觸控螢幕所在的顯示器。bounds 為全域 Quartz 座標（點，原點在主螢幕左上、y 向下）
    public static func displayObject(_ d: DisplayInfo) -> String {
        var s = "{\"id\":\(d.id)"
        if let name = d.name { s += ",\"name\":\"\(escape(name))\"" }
        s += ",\"edid\":\"\(d.edid)\",\"uuid\":\"\(escape(d.uuid))\",\"main\":\(d.isMain)"
        s += String(format: ",\"bounds\":[%.0f,%.0f,%.0f,%.0f]", d.bounds.origin.x, d.bounds.origin.y, d.bounds.width, d.bounds.height)
        return s + ",\"pixels\":[\(d.pixelWidth),\(d.pixelHeight)],\"hz\":" + String(format: "%.0f", d.refreshRate) + "}"
    }

    /// 裝置資訊物件（hello 與 device 訊息共用）
    public static func deviceObject(_ d: MultiTouchDeviceInfo) -> String {
        var s = "{\"id\":\(d.id),\"vendorId\":\(d.vendorID),\"productId\":\(d.productID)"
        s += ",\"manufacturer\":\"\(escape(d.manufacturer))\",\"product\":\"\(escape(d.product))\""
        s += ",\"serial\":\"\(escape(d.serialNumber))\",\"locationId\":\(d.locationID)"
        s += ",\"maxContacts\":\(d.maxContacts),\"slotsPerReport\":\(d.slotsPerReport)"
        if let w = d.physicalWidthMillimeters { s += ",\"widthMM\":" + String(format: "%.1f", w) }
        if let h = d.physicalHeightMillimeters { s += ",\"heightMM\":" + String(format: "%.1f", h) }
        return s + ",\"exclusive\":\(d.exclusive),\"calibrated\":\(d.isCalibrated)}"
    }

    /// 與 `String(format: "%.5f", v)` 完全相同
    static func number(_ v: Double) -> String {
        var w = ByteWriter(bytes: [])
        w.appendFixed5(v)
        return String(decoding: w.bytes, as: UTF8.self)
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func phaseName(_ phase: TouchPhase) -> StaticString {
        switch phase {
        case .began: "began"
        case .moved: "moved"
        case .stationary: "stationary"
        case .ended: "ended"
        case .cancelled: "cancelled"
        }
    }
}

/// 把 ASCII 片段、整數與固定小數直接寫入位元組陣列（不經過 String）
struct ByteWriter {
    var bytes: [UInt8]

    mutating func reserve(_ additional: Int) {
        bytes.reserveCapacity(bytes.count + additional)
    }

    mutating func append(_ s: StaticString) {
        bytes.append(contentsOf: UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
    }

    mutating func append(_ v: Int) {
        if v < 0 {
            bytes.append(UInt8(ascii: "-"))
            append(v.magnitude)
        } else {
            append(UInt64(v))
        }
    }

    mutating func append(_ v: UInt64) {
        append(UInt(v))
    }

    mutating func append(_ v: UInt) {
        // 最多 20 位數：先寫到堆疊上的 tuple 再反向複製
        var digits: (UInt64, UInt64, UInt64) = (0, 0, 0)
        var count = 0
        var n = v
        withUnsafeMutableBytes(of: &digits) { raw in
            repeat {
                raw[count] = UInt8(ascii: "0") + UInt8(n % 10)
                n /= 10
                count += 1
            } while n > 0
            for i in stride(from: count - 1, through: 0, by: -1) { bytes.append(raw[i]) }
        }
    }

    /// 與 `String(format: "%.5f", v)` 完全相同。
    ///
    /// printf 依 v 的「精確二進位值」四捨五入（tie 時取偶數）。`v * 1e5` 有約 1e-11 的誤差，只有在真實值
    /// 非常接近 .5 的邊界時才可能取錯，所以離邊界 1e-6 以內、或不在 0...1（含 -0.0、NaN）時交給 `String(format:)`。
    mutating func appendFixed5(_ v: Double) {
        guard v.sign == .plus, v <= 1 else {
            bytes.append(contentsOf: String(format: "%.5f", v).utf8)
            return
        }
        let scaled = v * 100_000
        let floor = scaled.rounded(.down)
        let fraction = scaled - floor
        guard abs(fraction - 0.5) > 1e-6 else {
            bytes.append(contentsOf: String(format: "%.5f", v).utf8)
            return
        }
        let n = Int(floor) + (fraction > 0.5 ? 1 : 0) // 0...100000
        bytes.append(UInt8(ascii: "0") + UInt8(n / 100_000))
        bytes.append(UInt8(ascii: "."))
        var rest = n % 100_000
        var divisor = 10_000
        for _ in 0..<5 {
            bytes.append(UInt8(ascii: "0") + UInt8(rest / divisor))
            rest %= divisor
            divisor /= 10
        }
    }
}
