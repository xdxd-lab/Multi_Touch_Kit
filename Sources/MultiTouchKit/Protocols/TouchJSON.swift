import Foundation

/// mtk-server 在 UDP 與 WebSocket 上使用的 JSON 訊息格式（見 docs/server-protocol.md）。
/// 刻意手動組字串：格式固定、欄位順序穩定、每個 frame 不需配置 JSONEncoder。
public enum TouchJSON {
    public static let protocolVersion = 1

    public static func frame(_ frame: TouchFrame) -> String {
        var s = "{\"type\":\"frame\",\"v\":\(protocolVersion),\"device\":\(frame.deviceID),\"seq\":\(frame.sequence),\"t\":\(frame.timestamp)"
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

    public static func device(_ info: MultiTouchDeviceInfo, event: String) -> String {
        "{\"type\":\"device\",\"v\":\(protocolVersion),\"event\":\"\(escape(event))\",\"device\":\(deviceObject(info))}"
    }

    public static func hello(server: String, devices: [MultiTouchDeviceInfo]) -> String {
        "{\"type\":\"hello\",\"v\":\(protocolVersion),\"server\":\"\(escape(server))\",\"version\":\"\(MultiTouchKitVersion.string)\",\"devices\":["
            + devices.map(deviceObject).joined(separator: ",") + "]}"
    }

    public static func deviceObject(_ d: MultiTouchDeviceInfo) -> String {
        var s = "{\"id\":\(d.id),\"vendorId\":\(d.vendorID),\"productId\":\(d.productID)"
        s += ",\"manufacturer\":\"\(escape(d.manufacturer))\",\"product\":\"\(escape(d.product))\""
        s += ",\"maxContacts\":\(d.maxContacts),\"slotsPerReport\":\(d.slotsPerReport)"
        if let w = d.physicalWidthMillimeters { s += ",\"widthMM\":" + String(format: "%.1f", w) }
        if let h = d.physicalHeightMillimeters { s += ",\"heightMM\":" + String(format: "%.1f", h) }
        return s + ",\"exclusive\":\(d.exclusive)}"
    }

    static func number(_ v: Double) -> String {
        String(format: "%.5f", v)
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
}
