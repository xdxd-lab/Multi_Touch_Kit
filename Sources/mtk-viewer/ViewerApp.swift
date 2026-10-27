// mtk-viewer：全螢幕顯示每根手指的位置與編號，用來目視確認 10 點觸控。Esc 或 Q 離開。
import AppKit
import MultiTouchKit

@main
@MainActor
final class ViewerApp: NSObject, NSApplicationDelegate {
    private static var shared: ViewerApp?

    private var window: NSWindow!
    private var touchView: TouchView!
    private var manager: MultiTouchManager?
    private var simulator: SimulatedTouchSource?
    private var mapping = ScreenMapping()
    private var statusMessage = ""

    static func main() {
        let app = NSApplication.shared
        let delegate = ViewerApp()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            用法：mtk-viewer [選項]
              --display N   顯示在第 N 個螢幕（從 0 開始，預設為主螢幕）
              --rotate DEG  觸控面板相對畫面的旋轉：0、90、180、270
              --simulate    使用模擬觸控（不需要硬體）
            """)
            exit(0)
        }
        var screen = NSScreen.main ?? NSScreen.screens[0]
        if let i = arguments.firstIndex(of: "--display"), i + 1 < arguments.count, let n = Int(arguments[i + 1]),
           NSScreen.screens.indices.contains(n) {
            screen = NSScreen.screens[n]
        }
        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            mapping.displayID = id
        }
        if let i = arguments.firstIndex(of: "--rotate"), i + 1 < arguments.count,
           let rotation = Int(arguments[i + 1]).flatMap(ScreenMapping.Rotation.init(rawValue:)) {
            mapping.rotation = rotation
        }

        touchView = TouchView(frame: screen.frame)
        window = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: true)
        window.contentView = touchView
        window.backgroundColor = .black
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(touchView)
        NSApp.activate(ignoringOtherApps: true)

        let handler: @Sendable (TouchFrame) -> Void = { frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { ViewerApp.shared?.receive(frame) } }
        }
        if arguments.contains("--simulate") {
            let source = SimulatedTouchSource()
            source.frameHandler = handler
            source.start()
            simulator = source
            touchView.status = "模擬觸控"
        } else {
            let manager = MultiTouchManager()
            manager.frameHandler = handler
            manager.logHandler = { message in
                print(message)
                DispatchQueue.main.async { MainActor.assumeIsolated { ViewerApp.shared?.touchView.status = message } }
            }
            do {
                try manager.start()
            } catch {
                touchView.status = "啟動失敗：\(error)"
            }
            if manager.connectedDevices.isEmpty { touchView.status = "沒有偵測到觸控螢幕，接上後會自動開始" }
            self.manager = manager
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.stop()
        simulator?.stop()
        print(touchView.summary)
    }

    private func receive(_ frame: TouchFrame) {
        guard let window else { return }
        let points = frame.touches.map { touch -> CGPoint in
            let screenPoint = mapping.cocoaPoint(x: touch.x, y: touch.y)
            return touchView.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        }
        touchView.apply(frame, points: points)
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class TouchView: NSView {
    private struct Ripple {
        var point: CGPoint
        var start: CFTimeInterval
        var hue: CGFloat
    }

    private var touches: [UInt64: (touch: Touch, point: CGPoint)] = [:]
    private var ripples: [Ripple] = []
    private var frameTimes: [UInt64] = []
    private var maxSimultaneous = 0
    private var totalTaps = 0
    private var timer: Timer?
    var status = "" { didSet { needsDisplay = true } }

    var summary: String { "mtk-viewer：最多同時 \(maxSimultaneous) 點，共 \(totalTaps) 次按下" }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
        }
    }

    func apply(_ frame: TouchFrame, points: [CGPoint]) {
        for (touch, point) in zip(frame.touches, points) {
            if touch.phase.isTerminal {
                touches[touch.id] = nil
            } else {
                touches[touch.id] = (touch, point)
            }
            if touch.phase == .began {
                totalTaps += 1
                ripples.append(Ripple(point: point, start: CACurrentMediaTime(), hue: hue(for: touch.id)))
            }
        }
        maxSimultaneous = max(maxSimultaneous, touches.count)
        frameTimes.append(frame.timestamp)
        if frameTimes.count > 64 { frameTimes.removeFirst(frameTimes.count - 64) }
        startAnimating()
        needsDisplay = true
    }

    private func startAnimating() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let view = ViewerAppViewBox.view else { return }
                view.tick()
            }
        }
        ViewerAppViewBox.view = self
    }

    fileprivate func tick() {
        let now = CACurrentMediaTime()
        ripples.removeAll { now - $0.start > 0.35 }
        if ripples.isEmpty {
            timer?.invalidate()
            timer = nil
        }
        needsDisplay = true
    }

    private func hue(for id: UInt64) -> CGFloat {
        CGFloat((id * 37) % 360) / 360
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let now = CACurrentMediaTime()
        for r in ripples {
            let progress = CGFloat((now - r.start) / 0.35)
            let radius = 40 + progress * 80
            NSColor(hue: r.hue, saturation: 0.8, brightness: 1, alpha: 1 - progress).setStroke()
            let path = NSBezierPath(ovalIn: NSRect(x: r.point.x - radius, y: r.point.y - radius, width: radius * 2, height: radius * 2))
            path.lineWidth = 4
            path.stroke()
        }
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.white,
        ]
        for (touch, point) in touches.values {
            NSColor(hue: hue(for: touch.id), saturation: 0.7, brightness: 0.95, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 45, y: point.y - 45, width: 90, height: 90)).fill()
            let label = "\(touch.id)" as NSString
            let size = label.size(withAttributes: labelAttributes)
            label.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: labelAttributes)
        }

        var rate = ""
        if frameTimes.count > 8, let first = frameTimes.first, let last = frameTimes.last, last > first {
            rate = String(format: "  回報率 %.0f Hz", Double(frameTimes.count - 1) / (Double(last - first) / 1e9))
        }
        let hud = "觸點 \(touches.count)  最多 \(maxSimultaneous)  按下 \(totalTaps)\(rate)\n\(status)\nEsc／Q 離開"
        (hud as NSString).draw(at: CGPoint(x: 24, y: bounds.height - 110), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ])
    }
}

/// Timer 的 closure 需為 Sendable，透過主執行緒專用的 box 取回 view
@MainActor
private enum ViewerAppViewBox {
    static weak var view: TouchView?
}
