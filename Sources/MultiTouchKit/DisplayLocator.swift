import AppKit
import CoreGraphics

/// 一台已連線的顯示器
public struct DisplayInfo: Sendable, Hashable, CustomStringConvertible {
    public var id: CGDirectDisplayID
    /// 系統顯示的名稱（例如「Sculptor (1)」）。同名顯示器的編號由 macOS 指定、不保證固定；
    /// 只有在主執行緒取得清單時才有值。
    public var name: String?
    /// EDID 的廠商／型號／序號（CGDisplayVendorNumber 等）
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    /// 由 EDID 推導、重開機後仍相同的識別碼
    public var uuid: String
    public var isMain: Bool
    public var isBuiltin: Bool
    /// 全域 Quartz 座標（點，原點在主螢幕左上）
    public var bounds: CGRect
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    /// EDID 宣告的實體尺寸（mm）；未知時為 0
    public var widthMillimeters: Double
    public var heightMillimeters: Double
    public var rotation: Double

    public var edid: String { String(format: "%04x:%04x:%u", vendor, model, serial) }

    public var description: String {
        String(format: "id=%u「%@」%dx%d@%.0fHz edid=%@ %.0fx%.0fmm%@", id, name ?? "?", pixelWidth, pixelHeight,
               refreshRate, edid, widthMillimeters, heightMillimeters, isMain ? " 主螢幕" : "")
    }
}

/// 選擇觸控螢幕對應的顯示器。文字格式（mtk-server／mtk-viewer 的 --display、C API mtk_set_display、
/// 環境變數 MTK_DISPLAY）以逗號串接多個條件，全部符合才算：
///
///     auto                        依觸控面板實體尺寸自動挑選（預設）
///     main                        主螢幕
///     id:2  或  2                 CGDirectDisplayID（重新接線後可能改變）
///     uuid:2B0DA454-...           顯示器 UUID
///     edid:6474:aa15[:序號]       EDID 廠商:型號（16 進位）[:序號（10 進位）]，最可靠
///     name:Sculptor               名稱包含（不分大小寫）
///     size:1920x1080              目前解析度（像素）
///     hz:60                       更新率
///
/// 例：兩台同名「Sculptor」時用 `name:Sculptor,size:1920x1080` 或 `edid:6474:aa15` 區分。
public struct DisplaySelector: Sendable, Hashable, CustomStringConvertible {
    public enum Criterion: Sendable, Hashable {
        case automatic
        case main
        case id(CGDirectDisplayID)
        case uuid(String)
        case edid(vendor: UInt32, model: UInt32, serial: UInt32?)
        case name(String)
        case size(width: Int, height: Int)
        case refreshRate(Double)
    }

    public var criteria: [Criterion]
    public let text: String

    public static let automatic = DisplaySelector(criteria: [.automatic], text: "auto")
    public static let main = DisplaySelector(criteria: [.main], text: "main")

    public init(criteria: [Criterion], text: String) {
        self.criteria = criteria
        self.text = text
    }

    /// 解析文字格式；格式錯誤回傳 nil。空字串視為 auto。
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var criteria: [Criterion] = []
        for part in trimmed.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let (key, value): (String, String) = {
                guard let colon = part.firstIndex(of: ":") else { return (part.lowercased(), "") }
                return (part[..<colon].lowercased(), String(part[part.index(after: colon)...]))
            }()
            switch key {
            case "auto": criteria.append(.automatic)
            case "main": criteria.append(.main)
            case "id":
                guard let id = UInt32(value) else { return nil }
                criteria.append(.id(id))
            case "uuid":
                guard !value.isEmpty else { return nil }
                criteria.append(.uuid(value.uppercased()))
            case "edid":
                let fields = value.split(separator: ":", omittingEmptySubsequences: false)
                guard fields.count == 2 || fields.count == 3,
                      let vendor = UInt32(Self.stripHex(fields[0]), radix: 16),
                      let model = UInt32(Self.stripHex(fields[1]), radix: 16) else { return nil }
                var serial: UInt32?
                if fields.count == 3 {
                    guard let s = UInt32(fields[2]) else { return nil }
                    serial = s
                }
                criteria.append(.edid(vendor: vendor, model: model, serial: serial))
            case "name":
                guard !value.isEmpty else { return nil }
                criteria.append(.name(value))
            case "size":
                let wh = value.lowercased().split(separator: "x")
                guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]) else { return nil }
                criteria.append(.size(width: w, height: h))
            case "hz":
                guard let hz = Double(value) else { return nil }
                criteria.append(.refreshRate(hz))
            default:
                guard value.isEmpty, let id = UInt32(key) else { return nil }
                criteria.append(.id(id))
            }
        }
        if criteria.isEmpty { criteria = [.automatic] }
        self.init(criteria: criteria, text: trimmed.isEmpty ? "auto" : trimmed)
    }

    /// 環境變數 MTK_DISPLAY（未設定或格式錯誤時為 nil）
    public static var environment: DisplaySelector? {
        ProcessInfo.processInfo.environment["MTK_DISPLAY"].flatMap(DisplaySelector.init)
    }

    public var description: String { text }

    private static func stripHex(_ s: Substring) -> Substring {
        s.lowercased().hasPrefix("0x") ? s.dropFirst(2) : s
    }

    func matches(_ d: DisplayInfo) -> Bool {
        criteria.allSatisfy { c in
            switch c {
            case .automatic: true
            case .main: d.isMain
            case .id(let id): d.id == id
            case .uuid(let u): d.uuid == u
            case .edid(let v, let m, let s): d.vendor == v && d.model == m && (s == nil || d.serial == s)
            case .name(let n): d.name?.localizedCaseInsensitiveContains(n) ?? false
            case .size(let w, let h): d.pixelWidth == w && d.pixelHeight == h
            case .refreshRate(let hz): abs(d.refreshRate - hz) < 0.5
            }
        }
    }
}

/// 列出顯示器並依 DisplaySelector 找出觸控螢幕所在的那一台
public enum DisplayLocator {
    public struct Match: Sendable {
        public var display: DisplayInfo
        /// 給人看的選擇理由（例如「實體尺寸最接近」「符合多台，取第一台非主螢幕」）
        public var note: String
    }

    /// 目前連線的顯示器。名稱只有在主執行緒呼叫時才會填入。
    public static func onlineDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        let names = Thread.isMainThread ? MainActor.assumeIsolated { screenNames() } : [:]
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            let size = CGDisplayScreenSize(id)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            } ?? ""
            return DisplayInfo(
                id: id, name: names[id], vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id), uuid: uuid, isMain: CGDisplayIsMain(id) != 0,
                isBuiltin: CGDisplayIsBuiltin(id) != 0, bounds: CGDisplayBounds(id),
                pixelWidth: mode?.pixelWidth ?? CGDisplayPixelsWide(id), pixelHeight: mode?.pixelHeight ?? CGDisplayPixelsHigh(id),
                refreshRate: mode?.refreshRate ?? 0, widthMillimeters: size.width, heightMillimeters: size.height,
                rotation: CGDisplayRotation(id))
        }
    }

    /// - Parameter panel: 觸控面板資訊，`auto` 用它的實體尺寸比對；nil 時自動模式只能退回主螢幕
    public static func resolve(_ selector: DisplaySelector, panel: MultiTouchDeviceInfo? = nil,
                               displays: [DisplayInfo] = onlineDisplays()) -> Match? {
        let candidates = displays.filter(selector.matches)
        guard !candidates.isEmpty else { return nil }
        if selector.criteria.contains(.automatic) {
            if let w = panel?.physicalWidthMillimeters, let h = panel?.physicalHeightMillimeters,
               let best = closestBySize(candidates, panelWidth: w, panelHeight: h) {
                return Match(display: best, note: String(format: "實體尺寸最接近觸控面板（%.0fx%.0fmm）", w, h))
            }
            if let main = candidates.first(where: \.isMain) {
                return Match(display: main, note: "找不到尺寸相符的顯示器，使用主螢幕")
            }
            return Match(display: candidates[0], note: "找不到尺寸相符的顯示器")
        }
        if candidates.count == 1 { return Match(display: candidates[0], note: "符合 \(selector)") }
        let ordered = candidates.sorted { ($0.isMain ? 1 : 0, $0.id) < ($1.isMain ? 1 : 0, $1.id) }
        return Match(display: ordered[0], note: "符合 \(selector) 的顯示器有 \(candidates.count) 台，取第一台非主螢幕；請加上更多條件")
    }

    /// 長邊與短邊分別比對（不受旋轉影響），兩邊都要在 ±30% 內
    static func closestBySize(_ displays: [DisplayInfo], panelWidth: Double, panelHeight: Double) -> DisplayInfo? {
        let panelLong = max(panelWidth, panelHeight)
        let panelShort = min(panelWidth, panelHeight)
        guard panelShort > 0 else { return nil }
        var best: (DisplayInfo, Double)?
        for d in displays {
            let long = max(d.widthMillimeters, d.heightMillimeters)
            let short = min(d.widthMillimeters, d.heightMillimeters)
            guard short > 0 else { continue }
            let a = abs(log(long / panelLong))
            let b = abs(log(short / panelShort))
            guard a < log(1.3), b < log(1.3) else { continue }
            if best == nil || a + b < best!.1 { best = (d, a + b) }
        }
        return best?.0
    }

    @MainActor
    private static func screenNames() -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                out[n.uint32Value] = screen.localizedName
            }
        }
        return out
    }
}

extension ScreenMapping {
    /// 依 DisplaySelector 建立對應；找不到顯示器時回傳 nil
    public init?(selector: DisplaySelector, panel: MultiTouchDeviceInfo? = nil, rotation: Rotation = .none,
                 flipX: Bool = false, flipY: Bool = false) {
        guard let match = DisplayLocator.resolve(selector, panel: panel) else { return nil }
        self.init(displayID: match.display.id, rotation: rotation, flipX: flipX, flipY: flipY)
    }
}
