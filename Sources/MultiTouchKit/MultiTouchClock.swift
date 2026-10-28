import CoreGraphics
import Darwin

/// 觸控時間戳記使用的時鐘：mach_absolute_time 換算成奈秒。
/// 同一台 Mac 上所有程序共用同一時基，所以 mtk-server 送出的時間也能直接比較。
public enum MultiTouchClock {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// 現在時間（奈秒）
    public static func now() -> UInt64 {
        nanoseconds(fromHostTime: mach_absolute_time())
    }

    /// HID 報告時間戳記（mach absolute time）→ 奈秒
    public static func nanoseconds(fromHostTime t: UInt64) -> UInt64 {
        let tb = timebase
        if tb.numer == tb.denom { return t }
        // 拆成商與餘數避免乘法溢位
        return (t / tb.denom) * tb.numer + (t % tb.denom) * tb.numer / tb.denom
    }
}

/// 把正規化觸控座標對應到 macOS 螢幕
public struct ScreenMapping: Sendable {
    /// 面板相對於畫面的旋轉（螢幕在「顯示器」設定中旋轉時使用）
    public enum Rotation: Int, Sendable {
        case none = 0
        case degrees90 = 90
        case degrees180 = 180
        case degrees270 = 270
    }

    /// 觸控螢幕所在的顯示器。預設是主螢幕，但觸控螢幕通常不是主螢幕：請用 `init?(selector:panel:)` 或 `DisplayLocator` 找出正確的顯示器
    public var displayID: CGDirectDisplayID
    /// 面板相對畫面的旋轉（在翻轉之後套用）
    public var rotation: Rotation
    /// 面板左右顛倒（先於旋轉套用）
    public var flipX: Bool
    /// 面板上下顛倒（先於旋轉套用）
    public var flipY: Bool

    /// - Parameter displayID: 預設主螢幕；觸控螢幕不是主螢幕時請明確指定（見 `displayID`）
    public init(displayID: CGDirectDisplayID = CGMainDisplayID(), rotation: Rotation = .none,
                flipX: Bool = false, flipY: Bool = false) {
        self.displayID = displayID
        self.rotation = rotation
        self.flipX = flipX
        self.flipY = flipY
    }

    /// 套用旋轉與翻轉後的正規化座標（原點左上）
    public func orient(x: Double, y: Double) -> (x: Double, y: Double) {
        var (u, v) = (flipX ? 1 - x : x, flipY ? 1 - y : y)
        switch rotation {
        case .none: break
        case .degrees90: (u, v) = (1 - v, u)
        case .degrees180: (u, v) = (1 - u, 1 - v)
        case .degrees270: (u, v) = (v, 1 - u)
        }
        return (u, v)
    }

    /// 全域 Quartz 座標（點，原點在主螢幕左上、y 向下），可直接用於 CGEvent
    public func globalPoint(x: Double, y: Double) -> CGPoint {
        let (u, v) = orient(x: x, y: y)
        let b = CGDisplayBounds(displayID)
        return CGPoint(x: b.origin.x + u * b.width, y: b.origin.y + v * b.height)
    }

    /// 全域 Cocoa 座標（點，原點在主螢幕左下、y 向上），可用於 NSWindow／NSScreen
    public func cocoaPoint(x: Double, y: Double) -> CGPoint {
        let p = globalPoint(x: x, y: y)
        return CGPoint(x: p.x, y: CGDisplayBounds(CGMainDisplayID()).height - p.y)
    }
}
