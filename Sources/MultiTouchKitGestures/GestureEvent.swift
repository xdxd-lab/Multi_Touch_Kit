import CoreGraphics

/// 手勢的連續階段（對應 NSEvent.Phase 的 began／changed／ended／cancelled）
public enum GesturePhase: Sendable, Equatable, CustomStringConvertible {
    case began
    case changed
    case ended
    case cancelled

    public var description: String {
        switch self {
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        }
    }
}

/// 慣性捲動階段（對應 NSEvent.momentumPhase）
public enum MomentumPhase: Sendable, Equatable, CustomStringConvertible {
    case began
    case changed
    case ended

    public var description: String {
        switch self {
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        }
    }
}

public enum MouseButton: Sendable, Equatable, CustomStringConvertible {
    case left
    case right

    public var description: String { self == .left ? "left" : "right" }
}

public enum SwipeAxis: Sendable, Equatable, CustomStringConvertible {
    /// 左右：切換桌面（Space）／全螢幕 App
    case horizontal
    /// 上下：Mission Control（上）／App Exposé（下）
    case vertical

    public var description: String { self == .horizontal ? "horizontal" : "vertical" }
}

/// 辨識結果：與送出方式無關的抽象事件。座標為全域 Quartz 座標（點，原點在主螢幕左上、y 向下）。
///
/// 方向慣例與 macOS 觸控板相同（內容跟著手指走）：
/// - `scroll` 的 dx、dy 為手指位移（點）；手指往下 dy > 0，內容往下（等同捲輪往上）。
/// - `magnify` 為相對變化量（0.1 = 放大 10%），`rotate` 為角度，逆時針為正。
/// - `swipe` 的 progress 為手指位移除以設定的滑動距離，往右／往下為正。
public enum GestureEvent: Sendable, Equatable, CustomStringConvertible {
    /// 把游標移到手勢位置（捲動、縮放等事件會送給游標下方的視窗）
    case pointer(CGPoint)
    case mouseDown(MouseButton, CGPoint, clickCount: Int)
    case mouseDragged(MouseButton, CGPoint)
    case mouseUp(MouseButton, CGPoint, clickCount: Int)
    case scroll(dx: Double, dy: Double, phase: GesturePhase)
    case momentum(dx: Double, dy: Double, phase: MomentumPhase)
    case magnify(Double, phase: GesturePhase)
    case rotate(degrees: Double, phase: GesturePhase)
    /// velocity：結束時沿軸向的速度（progress／秒），用來判斷快速甩動
    case swipe(SwipeAxis, progress: Double, velocity: Double, fingers: Int, phase: GesturePhase)

    public var description: String {
        func p(_ point: CGPoint) -> String { "(\(Int(point.x.rounded())),\(Int(point.y.rounded())))" }
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        switch self {
        case .pointer(let at): return "pointer \(p(at))"
        case .mouseDown(let b, let at, let n): return "mouseDown \(b) \(p(at)) clicks=\(n)"
        case .mouseDragged(let b, let at): return "mouseDragged \(b) \(p(at))"
        case .mouseUp(let b, let at, let n): return "mouseUp \(b) \(p(at)) clicks=\(n)"
        case .scroll(let dx, let dy, let ph): return "scroll \(ph) dx=\(f(dx)) dy=\(f(dy))"
        case .momentum(let dx, let dy, let ph): return "momentum \(ph) dx=\(f(dx)) dy=\(f(dy))"
        case .magnify(let m, let ph): return "magnify \(ph) \(f(m))"
        case .rotate(let d, let ph): return "rotate \(ph) \(f(d))°"
        case .swipe(let axis, let progress, let v, let n, let ph):
            return "swipe \(axis) \(n)指 \(ph) progress=\(f(progress)) velocity=\(f(v))"
        }
    }
}

/// 一根手指在某個 frame 的位置（已換算成全域 Quartz 座標）
public struct GestureTouch: Sendable, Equatable {
    public var id: UInt64
    public var position: CGPoint
    /// false 代表這個 frame 手指已離開（ended／cancelled）
    public var isDown: Bool

    public init(id: UInt64, position: CGPoint, isDown: Bool = true) {
        self.id = id
        self.position = position
        self.isDown = isDown
    }
}
