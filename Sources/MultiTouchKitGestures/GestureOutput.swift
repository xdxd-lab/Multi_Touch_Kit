import ApplicationServices
import CoreGraphics
import Foundation

/// 手勢事件的送出端。`send` 一律在 GestureController 的佇列上依序呼叫。
public protocol GestureOutput: AnyObject, Sendable {
    func send(_ events: [GestureEvent])
    /// 放開所有仍按住的滑鼠鍵、結束所有進行中的連續手勢（結束程式、裝置移除、睡眠等）。
    /// 依送出端自己記錄的狀態處理，與辨識器的狀態無關；沒有東西需要放開時不送任何事件。
    func releaseAll()
}

extension GestureOutput {
    public func releaseAll() {}
}

/// 送出端記錄「目前按住／進行中」的狀態，並產生放開用的事件（純邏輯，可測）
struct GestureOutputState: Sendable, Equatable {
    var pressed: Set<MouseButton> = []
    var lastPoint: CGPoint?
    var scrolling = false
    var momentum = false
    var magnifying = false
    var rotating = false
    var swipe: SwipeAxis?

    var isEmpty: Bool { pressed.isEmpty && !scrolling && !momentum && !magnifying && !rotating && swipe == nil }

    mutating func record(_ e: GestureEvent) {
        switch e {
        case .pointer(let p): lastPoint = p
        case .mouseDown(let b, let p, _): pressed.insert(b); lastPoint = p
        case .mouseDragged(_, let p): lastPoint = p
        case .mouseUp(let b, let p, _): pressed.remove(b); lastPoint = p
        case .scroll(_, _, let ph): scrolling = ph == .began || ph == .changed
        case .momentum(_, _, let ph): momentum = ph != .ended
        case .magnify(_, let ph): magnifying = ph == .began || ph == .changed
        case .rotate(_, let ph): rotating = ph == .began || ph == .changed
        case .swipe(let axis, _, _, _, let ph): swipe = (ph == .began || ph == .changed) ? axis : nil
        }
    }

    /// 放開用的事件；`fallback` 為沒有記錄到位置時使用的游標位置
    func releaseEvents(fallback: CGPoint) -> [GestureEvent] {
        var out: [GestureEvent] = []
        if scrolling { out.append(.scroll(dx: 0, dy: 0, phase: .cancelled)) }
        if momentum { out.append(.momentum(dx: 0, dy: 0, phase: .ended)) }
        if magnifying { out.append(.magnify(0, phase: .cancelled)) }
        if rotating { out.append(.rotate(degrees: 0, phase: .cancelled)) }
        if let swipe { out.append(.swipe(swipe, progress: 0, velocity: 0, fingers: 0, phase: .cancelled)) }
        let p = lastPoint ?? fallback
        if pressed.contains(.left) { out.append(.mouseUp(.left, p, clickCount: 1)) }
        if pressed.contains(.right) { out.append(.mouseUp(.right, p, clickCount: 1)) }
        return out
    }
}

/// 三／四指滑動的送出方式
public enum SwipeMode: String, Sendable, CaseIterable {
    /// 未公開的 dock swipe 事件：畫面跟著手指移動，放開時依進度與速度決定是否切換（與觸控板相同）
    case dock
    /// 放開時送出 Mission Control 的鍵盤快速鍵（Control＋方向鍵；公開 API，macOS 更新後較不易失效）
    case keys
}

/// keys 模式下 swipe 對應的快速鍵（系統設定 → 鍵盤 → 鍵盤快速鍵 → Mission Control 的預設值）
public enum SwipeShortcut: Sendable, Equatable, CustomStringConvertible {
    /// 手指往左 → 右邊的桌面（Control＋→）
    case nextSpace
    /// 手指往右 → 左邊的桌面（Control＋←）
    case previousSpace
    /// 手指往上（Control＋↑）
    case missionControl
    /// 手指往下（Control＋↓）
    case appExpose

    /// 放開時位移超過 `minimumProgress` 或甩動速度超過 `minimumVelocity`（progress／秒）才觸發
    public static func resolve(axis: SwipeAxis, progress: Double, velocity: Double,
                               minimumProgress: Double = 0.25, minimumVelocity: Double = 1.0) -> SwipeShortcut? {
        let direction: Double
        if abs(progress) >= minimumProgress {
            direction = progress
        } else if abs(velocity) >= minimumVelocity {
            direction = velocity
        } else {
            return nil
        }
        switch axis {
        case .horizontal: return direction < 0 ? .nextSpace : .previousSpace
        case .vertical: return direction < 0 ? .missionControl : .appExpose
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .previousSpace: 123
        case .nextSpace: 124
        case .appExpose: 125
        case .missionControl: 126
        }
    }

    public var description: String {
        switch self {
        case .nextSpace: "Control+→（下一個桌面）"
        case .previousSpace: "Control+←（上一個桌面）"
        case .missionControl: "Control+↑（Mission Control）"
        case .appExpose: "Control+↓（App Exposé）"
        }
    }
}

/// 把手勢摘要交給 log，不送出（dry-run；或與 CGEventGestureOutput 一起用 CombinedGestureOutput 記錄實際送出的手勢）。
/// 連續手勢不逐筆印出，結束時印出累計量（位移、倍率、角度、持續時間）。
public final class LoggingGestureOutput: GestureOutput, @unchecked Sendable {
    /// 每行開頭的標籤，例如「手勢 dry-run」→「[手勢 dry-run] …」
    public let label: String
    private let log: (String) -> Void
    private let swipeMode: SwipeMode
    private let clock: () -> Double
    private var scroll = Accumulator()
    private var momentum = Accumulator()
    private var magnifyScale = 1.0
    private var magnifyStart = 0.0
    private var rotation = 0.0
    private var rotationStart = 0.0
    private var mouseDown: (point: CGPoint, time: Double, drags: Int)?

    struct Accumulator {
        var dx = 0.0
        var dy = 0.0
        var count = 0
        var start = 0.0

        mutating func reset(at time: Double) { self = Accumulator(start: time) }
        mutating func add(_ x: Double, _ y: Double) {
            dx += x
            dy += y
            count += 1
        }
    }

    /// - Parameter clock: 目前時間（秒），用來計算持續時間；測試時可替換
    public init(label: String = "手勢 dry-run", swipeMode: SwipeMode = .keys,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                log: @escaping (String) -> Void) {
        self.label = label
        self.swipeMode = swipeMode
        self.clock = clock
        self.log = log
    }

    public func send(_ events: [GestureEvent]) {
        let now = clock()
        func ms(_ start: Double) -> String { String(format: "%.0f ms", (now - start) * 1000) }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        for e in events {
            switch e {
            case .mouseDown(_, let p, _):
                mouseDown = (p, now, 0)
                log("[\(label)] \(e)")
            case .mouseDragged:
                mouseDown?.drags += 1
            case .mouseUp(_, let p, _):
                // 拖曳不逐筆印出，放開時標明拖曳距離，避免和點擊混淆
                if let down = mouseDown, down.drags > 0 {
                    let distance = hypot(p.x - down.point.x, p.y - down.point.y)
                    log("[\(label)] \(e)（拖曳 \(f(distance)) 點、\(down.drags) 筆、\(ms(down.time))）")
                } else {
                    log("[\(label)] \(e)")
                }
                mouseDown = nil
            case .scroll(let dx, let dy, let phase):
                if phase == .began { scroll.reset(at: now) }
                scroll.add(dx, dy)
                if phase == .began { log("[\(label)] \(e)") }
                if phase == .ended || phase == .cancelled {
                    log("[\(label)] scroll \(phase)：共 dx=\(f(scroll.dx)) dy=\(f(scroll.dy)) 點、\(scroll.count) 筆、\(ms(scroll.start))")
                }
            case .momentum(let dx, let dy, let phase):
                if phase == .began { momentum.reset(at: now) }
                momentum.add(dx, dy)
                if phase == .began { log("[\(label)] \(e)") }
                if phase == .ended {
                    log("[\(label)] momentum ended：慣性共 dx=\(f(momentum.dx)) dy=\(f(momentum.dy)) 點、\(momentum.count) 筆、\(ms(momentum.start))")
                }
            case .magnify(let m, let phase):
                if phase == .began {
                    magnifyScale = 1
                    magnifyStart = now
                }
                magnifyScale *= 1 + m
                if phase == .began { log("[\(label)] \(e)") }
                if phase == .ended || phase == .cancelled {
                    log("[\(label)] magnify \(phase)：總倍率 ×\(String(format: "%.3f", magnifyScale))、\(ms(magnifyStart))")
                }
            case .rotate(let degrees, let phase):
                if phase == .began {
                    rotation = 0
                    rotationStart = now
                }
                rotation += degrees
                if phase == .began { log("[\(label)] \(e)") }
                if phase == .ended || phase == .cancelled {
                    log("[\(label)] rotate \(phase)：共 \(f(rotation))°（逆時針為正）、\(ms(rotationStart))")
                }
            case .swipe(_, _, _, _, .changed):
                continue
            case .swipe(let axis, let progress, let velocity, _, .ended) where swipeMode == .keys:
                let shortcut = SwipeShortcut.resolve(axis: axis, progress: progress, velocity: velocity)
                log("[\(label)] \(e) → \(shortcut.map(\.description) ?? "不觸發")")
            default:
                log("[\(label)] \(e)")
            }
        }
    }
}

/// 依序交給多個送出端（例如實際送出＋記錄）
public final class CombinedGestureOutput: GestureOutput, @unchecked Sendable {
    public let outputs: [GestureOutput]

    public init(_ outputs: [GestureOutput]) {
        self.outputs = outputs
    }

    public func send(_ events: [GestureEvent]) {
        for o in outputs { o.send(events) }
    }

    public func releaseAll() {
        for o in outputs { o.releaseAll() }
    }
}

/// 以 CGEvent 合成系統事件。需要「輔助使用」權限（未授權時系統會靜默丟棄事件）。
///
/// - 點擊、拖曳、捲動、鍵盤：公開 API。
/// - 縮放、旋轉、dock swipe：未公開的 gesture 事件欄位（macOS 26.2 驗證），macOS 更新後可能失效，見 docs/gestures.md。
public final class CGEventGestureOutput: GestureOutput, @unchecked Sendable {
    public let swipeMode: SwipeMode
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastMouse: CGPoint?
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var dockSwipe: (axis: SwipeAxis, offset: Double)?
    private var state = GestureOutputState()

    public init(swipeMode: SwipeMode = .keys) {
        self.swipeMode = swipeMode
    }

    /// 送出事件需要的「輔助使用」權限；prompt 為 true 時，未授權會跳出系統詢問視窗
    public static func isTrusted(prompt: Bool) -> Bool {
        // kAXTrustedCheckOptionPrompt 的值（Swift 6 不允許直接引用該全域變數）
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func send(_ events: [GestureEvent]) {
        for e in events { post(e) }
    }

    public func releaseAll() {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        for e in state.releaseEvents(fallback: cursor) { post(e) }
    }

    /// 不論本程序是否送過 mouseDown，在目前游標位置送出左、右、中鍵的 mouseUp
    /// （mtk-server --release-buttons：上次結束時鍵卡住的復原方法）
    public static func releaseSystemButtons() {
        let source = CGEventSource(stateID: .hidSystemState)
        let p = CGEvent(source: nil)?.location ?? .zero
        for (type, button) in [(CGEventType.leftMouseUp, CGMouseButton.left), (.rightMouseUp, .right), (.otherMouseUp, .center)] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
        }
    }

    /// 系統是否認為滑鼠鍵按住中（含其他程式送出的合成事件）
    public static var systemButtonsPressed: [CGMouseButton] {
        [CGMouseButton.left, .right, .center].filter { CGEventSource.buttonState(.combinedSessionState, button: $0) }
    }

    private func post(_ event: GestureEvent) {
        state.record(event)
        switch event {
        case .pointer(let p):
            mouse(.mouseMoved, p, button: .left, clickCount: 0)
        case .mouseDown(let button, let p, let n):
            mouse(button == .left ? .leftMouseDown : .rightMouseDown, p, button: button, clickCount: n)
        case .mouseDragged(let button, let p):
            mouse(button == .left ? .leftMouseDragged : .rightMouseDragged, p, button: button, clickCount: 1)
        case .mouseUp(let button, let p, let n):
            mouse(button == .left ? .leftMouseUp : .rightMouseUp, p, button: button, clickCount: n)
        case .scroll(let dx, let dy, let phase):
            if phase == .began { scrollRemainder = (0, 0) }
            scroll(dx: dx, dy: dy, phaseField: .scrollWheelEventScrollPhase, value: Self.scrollPhase(phase))
        case .momentum(let dx, let dy, let phase):
            scroll(dx: dx, dy: dy, phaseField: .scrollWheelEventMomentumPhase, value: Self.momentumPhase(phase))
        case .magnify(let m, let phase):
            gesture(hidType: PrivateField.hidZoom, phase: phase, valueField: PrivateField.zoomValue, value: m)
        case .rotate(let degrees, let phase):
            gesture(hidType: PrivateField.hidRotation, phase: phase, valueField: PrivateField.rotationValue, value: degrees)
        case .swipe(let axis, let progress, let velocity, _, let phase):
            switch swipeMode {
            case .dock: dock(axis: axis, progress: progress, velocity: velocity, phase: phase)
            case .keys:
                if phase == .ended, let shortcut = SwipeShortcut.resolve(axis: axis, progress: progress, velocity: velocity) {
                    key(shortcut.keyCode, flags: [.maskControl, .maskSecondaryFn, .maskNumericPad])
                }
            }
        }
    }

    // MARK: - 公開 API

    private func mouse(_ type: CGEventType, _ p: CGPoint, button: MouseButton, clickCount: Int) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: button == .left ? .left : .right) else { return }
        if clickCount > 0 { e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        if let last = lastMouse {
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - last.x).rounded()))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - last.y).rounded()))
        }
        lastMouse = p
        e.post(tap: .cghidEventTap)
    }

    /// 像素單位、連續（觸控板式）捲動；小數位移累積到下一次
    private func scroll(dx: Double, dy: Double, phaseField: CGEventField, value: Int64) {
        let x = dx + scrollRemainder.x
        let y = dy + scrollRemainder.y
        let ix = x.rounded(.towardZero)
        let iy = y.rounded(.towardZero)
        scrollRemainder = (x - ix, y - iy)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(phaseField, value: value)
        e.post(tap: .cghidEventTap)
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 未公開的 gesture 事件

    /// CGEvent 未公開欄位編號（社群逆向整理，例如 Mac Mouse Fix 的 TouchSimulator；macOS 26.2 實測）
    enum PrivateField {
        static let eventType: UInt32 = 55          // kCGSEventTypeField：可設定任意事件類型
        static let gestureHIDType: UInt32 = 110    // IOHIDEventType
        static let zoomValue: UInt32 = 113
        static let rotationValue: UInt32 = 114
        static let swipeMotion: UInt32 = 123
        static let swipeProgress: UInt32 = 124
        static let swipeVelocityX: UInt32 = 129
        static let swipeVelocityY: UInt32 = 130
        static let gesturePhase: UInt32 = 132
        static let scrollGesturePhase: UInt32 = 134
        static let swipeProgressBits: UInt32 = 135
        static let swipeInverted: UInt32 = 136
        static let swipeMotionCopy: UInt32 = 165
        static let gestureFlavor: UInt32 = 41
        static let tinyA: UInt32 = 119
        static let tinyB: UInt32 = 139

        static let typeGesture: Int64 = 29         // NSEventTypeGesture
        static let typeDockControl: Int64 = 30     // kCGSEventDockControl
        static let hidRotation: Int64 = 5          // kIOHIDEventTypeRotation
        static let hidZoom: Int64 = 8              // kIOHIDEventTypeZoom
        static let hidDockSwipe: Int64 = 23        // kIOHIDEventTypeDockSwipe
        static let flavorMagic: Int64 = 33231
    }

    /// IOHIDEventPhaseBits
    private static func hidPhase(_ phase: GesturePhase) -> Int64 {
        switch phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        }
    }

    /// kCGScrollPhase*：began 1、changed 2、ended 4、cancelled 8
    private static func scrollPhase(_ phase: GesturePhase) -> Int64 { hidPhase(phase) }

    /// kCGMomentumScrollPhase*：begin 1、continue 2、end 3
    private static func momentumPhase(_ phase: MomentumPhase) -> Int64 {
        switch phase {
        case .began: 1
        case .changed: 2
        case .ended: 3
        }
    }

    private func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }

    private func gesture(hidType: Int64, phase: GesturePhase, valueField: UInt32, value: Double) {
        guard let e = CGEvent(source: source) else { return }
        e.setIntegerValueField(field(PrivateField.eventType), value: PrivateField.typeGesture)
        e.setIntegerValueField(field(PrivateField.gestureHIDType), value: hidType)
        e.setIntegerValueField(field(PrivateField.gesturePhase), value: Self.hidPhase(phase))
        e.setDoubleValueField(field(valueField), value: value)
        if let p = lastMouse { e.location = p }
        e.post(tap: .cgSessionEventTap)
    }

    /// Dock 的 swipe：offset 為累積位移（1 = 一整個桌面／完整打開 Mission Control）
    private func dock(axis: SwipeAxis, progress: Double, velocity: Double, phase: GesturePhase) {
        // 觸控板慣例：手指往左 = 往右邊的桌面；Dock 的 offset 正值代表往右邊的桌面／往上打開 Mission Control
        let offset = -progress
        if phase == .began { dockSwipe = (axis, offset) }
        guard dockSwipe != nil else { return }
        guard let e = CGEvent(source: source), let companion = CGEvent(source: source) else { return }
        let motion: Int64 = axis == .horizontal ? 1 : 2
        e.setIntegerValueField(field(PrivateField.eventType), value: PrivateField.typeDockControl)
        e.setIntegerValueField(field(PrivateField.gestureFlavor), value: PrivateField.flavorMagic)
        e.setIntegerValueField(field(PrivateField.gestureHIDType), value: PrivateField.hidDockSwipe)
        e.setIntegerValueField(field(PrivateField.gesturePhase), value: Self.hidPhase(phase))
        e.setIntegerValueField(field(PrivateField.scrollGesturePhase), value: Self.hidPhase(phase))
        e.setDoubleValueField(field(PrivateField.swipeProgress), value: offset)
        e.setIntegerValueField(field(PrivateField.swipeProgressBits), value: Int64(Float(offset).bitPattern))
        e.setIntegerValueField(field(PrivateField.swipeMotion), value: motion)
        e.setIntegerValueField(field(PrivateField.swipeMotionCopy), value: motion)
        e.setDoubleValueField(field(PrivateField.tinyA), value: Double(Float.leastNonzeroMagnitude))
        e.setDoubleValueField(field(PrivateField.tinyB), value: Double(Float.leastNonzeroMagnitude))
        if phase == .ended || phase == .cancelled {
            e.setDoubleValueField(field(PrivateField.swipeVelocityX), value: -velocity)
            e.setDoubleValueField(field(PrivateField.swipeVelocityY), value: -velocity)
            dockSwipe = nil
        }
        companion.setIntegerValueField(field(PrivateField.eventType), value: PrivateField.typeGesture)
        companion.setIntegerValueField(field(PrivateField.gestureFlavor), value: PrivateField.flavorMagic)
        e.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
    }
}
