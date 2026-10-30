import Foundation

/// 程式庫版本。mtk_version()、mtk-server 的 hello、Unity 套件的 package.json 必須一致（VersionConsistencyTests 會檢查）
public enum MultiTouchKitVersion {
    /// 語意化版本字串（MAJOR.MINOR.PATCH）
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
    /// 這個 frame 中的階段
    public var phase: TouchPhase
    /// 正規化座標 0...1，原點在面板左上角：x 由左到右
    public var x: Double
    /// 正規化座標 0...1：y 由上到下
    public var y: Double
    /// 控制器的原始 X 座標（HID 邏輯範圍內的值）
    public var rawX: Int
    /// 控制器的原始 Y 座標
    public var rawY: Int
    /// 0...1；裝置不支援時為 nil
    public var pressure: Double?
    /// 依裝置定義範圍正規化的接觸寬度；不支援時為 nil
    public var width: Double?
    /// 依裝置定義範圍正規化的接觸高度；不支援時為 nil
    public var height: Double?
    /// 控制器判斷是否為有意的觸碰（false 通常是手掌）；不支援時為 nil
    public var confidence: Bool?
    /// 套用觸控校正前的正規化 x（`TouchCalibration`）；沒有套用校正時為 nil，`x` 就是原始值
    public var uncalibratedX: Double?
    /// 套用觸控校正前的正規化 y；沒有套用校正時為 nil
    public var uncalibratedY: Double?

    /// 一般由 MultiTouchManager 建立；測試或自訂的觸控來源可自行建立
    public init(id: UInt64, contactID: Int, phase: TouchPhase, x: Double, y: Double, rawX: Int, rawY: Int,
                pressure: Double? = nil, width: Double? = nil, height: Double? = nil, confidence: Bool? = nil,
                uncalibratedX: Double? = nil, uncalibratedY: Double? = nil) {
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
        self.uncalibratedX = uncalibratedX
        self.uncalibratedY = uncalibratedY
    }
}

/// 一次完整的觸控掃描結果
public struct TouchFrame: Sendable {
    /// 產生這個 frame 的裝置（`MultiTouchDeviceInfo.id`；模擬來源為 0）
    public var deviceID: Int
    /// 每個裝置各自遞增
    public var sequence: UInt64
    /// 收到 HID 報告的時間（奈秒，MultiTouchClock 時基）
    public var timestamp: UInt64
    /// 控制器回報的 Scan Time（通常以 100 µs 為單位）；不支援時為 nil
    public var scanTime: UInt32?
    /// 這個 frame 中所有觸點，包含剛放開（ended／cancelled）的
    public var touches: [Touch]

    /// 一般由 MultiTouchManager 建立；測試或自訂的觸控來源可自行建立
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
    /// 裝置編號（從 1 開始，同一個 manager 中不重複使用；拔掉再接上會得到新的編號）
    public var id: Int
    /// USB Vendor ID（ILITEK 為 0x222A）
    public var vendorID: Int
    /// USB Product ID
    public var productID: Int
    /// 廠商名稱（USB 字串描述元；沒有時為空字串）
    public var manufacturer: String
    /// 產品名稱（USB 字串描述元；沒有時為空字串）
    public var product: String
    /// 序號（沒有時為空字串）
    public var serialNumber: String
    /// USB 位置：同一個實體裝置的各個 HID 介面相同，換插孔會改變
    public var locationID: Int
    /// 控制器宣告的最大同時觸點數
    public var maxContacts: Int
    /// 單一報告可容納的觸點數（小於 maxContacts 時為 hybrid mode）
    public var slotsPerReport: Int
    /// 觸控面板的實體寬度（mm，由 HID 描述元的 Physical 範圍與單位計算）；描述元沒有提供時為 nil
    public var physicalWidthMillimeters: Double?
    /// 觸控面板的實體高度（mm）；描述元沒有提供時為 nil
    public var physicalHeightMillimeters: Double?
    /// 控制器會回報 Scan Time（`TouchFrame.scanTime` 有值）
    public var hasScanTime: Bool
    /// 已獨占：系統不再把觸控當成滑鼠
    public var exclusive: Bool
    /// 正在套用觸控校正（`TouchCalibration`）
    public var isCalibrated: Bool

    /// 一般由 MultiTouchManager 建立；自行建立可用於測試或模擬（例如傳給 `DisplayLocator.resolve(_:panel:)`）
    public init(id: Int, vendorID: Int, productID: Int, manufacturer: String, product: String, serialNumber: String,
                locationID: Int, maxContacts: Int, slotsPerReport: Int, physicalWidthMillimeters: Double?,
                physicalHeightMillimeters: Double?, hasScanTime: Bool, exclusive: Bool, isCalibrated: Bool = false) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.manufacturer = manufacturer
        self.product = product
        self.serialNumber = serialNumber
        self.locationID = locationID
        self.maxContacts = maxContacts
        self.slotsPerReport = slotsPerReport
        self.physicalWidthMillimeters = physicalWidthMillimeters
        self.physicalHeightMillimeters = physicalHeightMillimeters
        self.hasScanTime = hasScanTime
        self.exclusive = exclusive
        self.isCalibrated = isCalibrated
    }
}

/// 裝置清單的變化（`MultiTouchManager.deviceHandler`）
public enum DeviceEvent: Sendable {
    /// 開啟了新的裝置（啟動時已接上的也會送出）
    case added(MultiTouchDeviceInfo)
    /// 裝置已拔除或 manager 停止；之前仍在螢幕上的觸點已先以 cancelled 送出
    case removed(MultiTouchDeviceInfo)
    /// 重新送出多點模式初始化（喚醒後、或偵測到控制器退回滑鼠模式時）
    case reinitialized(MultiTouchDeviceInfo)
}
