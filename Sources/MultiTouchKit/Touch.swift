import Foundation

public enum MultiTouchKitVersion {
    public static let string = "0.1.0"
}

/// 觸點的生命週期階段；數值與 C ABI（MTK_PHASE_*）、Unity 套件一致，不可更改
public enum TouchPhase: UInt8, Sendable, CustomStringConvertible {
    case began = 0
    case moved = 1
    case stationary = 2
    case ended = 3
    case cancelled = 4

    public var description: String {
        switch self {
        case .began: "began"
        case .moved: "moved"
        case .stationary: "stationary"
        case .ended: "ended"
        case .cancelled: "cancelled"
        }
    }

    /// 這個階段之後手指已不在螢幕上
    public var isTerminal: Bool { self == .ended || self == .cancelled }
}

/// 一根手指在某個 frame 的狀態
public struct Touch: Sendable, Equatable {
    /// 這次觸碰的唯一編號（從 1 開始遞增，跨裝置不重複）
    public var id: UInt64
    /// 控制器回報的 Contact Identifier，放開後會被重複使用
    public var contactID: Int
    public var phase: TouchPhase
    /// 正規化座標 0...1，原點在面板左上角
    public var x: Double
    public var y: Double
    /// 控制器的原始座標
    public var rawX: Int
    public var rawY: Int
    /// 0...1；裝置不支援時為 nil
    public var pressure: Double?
    /// 依裝置定義範圍正規化的接觸寬高；不支援時為 nil
    public var width: Double?
    public var height: Double?
    /// 控制器判斷是否為有意的觸碰（false 通常是手掌）；不支援時為 nil
    public var confidence: Bool?

    public init(id: UInt64, contactID: Int, phase: TouchPhase, x: Double, y: Double, rawX: Int, rawY: Int,
                pressure: Double? = nil, width: Double? = nil, height: Double? = nil, confidence: Bool? = nil) {
        self.id = id
        self.contactID = contactID
        self.phase = phase
        self.x = x
        self.y = y
        self.rawX = rawX
        self.rawY = rawY
        self.pressure = pressure
        self.width = width
        self.height = height
        self.confidence = confidence
    }
}

/// 一次完整的觸控掃描結果
public struct TouchFrame: Sendable {
    public var deviceID: Int
    /// 每個裝置各自遞增
    public var sequence: UInt64
    /// 收到 HID 報告的時間（奈秒，MultiTouchClock 時基）
    public var timestamp: UInt64
    /// 控制器回報的 Scan Time（通常以 100 µs 為單位）；不支援時為 nil
    public var scanTime: UInt32?
    /// 這個 frame 中所有觸點，包含剛放開（ended／cancelled）的
    public var touches: [Touch]

    public init(deviceID: Int, sequence: UInt64, timestamp: UInt64, scanTime: UInt32?, touches: [Touch]) {
        self.deviceID = deviceID
        self.sequence = sequence
        self.timestamp = timestamp
        self.scanTime = scanTime
        self.touches = touches
    }

    /// 仍在螢幕上的觸點
    public var activeTouches: [Touch] { touches.filter { !$0.phase.isTerminal } }
}

/// 觸控裝置資訊
public struct MultiTouchDeviceInfo: Sendable, Hashable {
    public var id: Int
    public var vendorID: Int
    public var productID: Int
    public var manufacturer: String
    public var product: String
    public var serialNumber: String
    public var locationID: Int
    /// 控制器宣告的最大同時觸點數
    public var maxContacts: Int
    /// 單一報告可容納的觸點數（小於 maxContacts 時為 hybrid mode）
    public var slotsPerReport: Int
    public var physicalWidthMillimeters: Double?
    public var physicalHeightMillimeters: Double?
    public var hasScanTime: Bool
    public var exclusive: Bool
}

public enum DeviceEvent: Sendable {
    case added(MultiTouchDeviceInfo)
    case removed(MultiTouchDeviceInfo)
    /// 重新送出多點模式初始化（喚醒後、或偵測到控制器退回滑鼠模式時）
    case reinitialized(MultiTouchDeviceInfo)
}
