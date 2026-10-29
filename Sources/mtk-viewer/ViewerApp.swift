// mtk-viewer：全螢幕顯示每根手指的位置與編號，用來目視確認 10 點觸控。Esc 或 Q 離開。
import AppKit
import MultiTouchKit
import MultiTouchKitArt

@main
@MainActor
final class ViewerApp: NSObject, NSApplicationDelegate {
    private static var shared: ViewerApp?

    private var window: NSWindow!
    private var touchView: TouchView!
    /// --calibrate 時的畫面（取代 touchView）
    private var calibrationView: CalibrationView?
    private var source: TouchSource?
    private var signalSources: [DispatchSourceSignal] = []
    private var mapping = ScreenMapping()
    private var statusMessage = ""

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        let delegate = ViewerApp()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // 純執行檔沒有 bundle 圖示：Dock 中顯示品牌圖示（與 MultiTouchKit Server.app 相同）
        app.applicationIconImage = BrandIcon.applicationIcon
        app.run()
    }

    static let usage = """
    用法：mtk-viewer [選項]
      --display SEL   觸控螢幕所在的顯示器（預設 auto，或環境變數 MTK_DISPLAY）。
                      例：edid:6474:aa15、name:Sculptor,size:1920x1080、main、id:2（格式見 docs/swift-package.md）
      --list-displays 列出顯示器後離開
      --rotate DEG    觸控面板相對畫面的旋轉：0、90、180、270
      --simulate      使用模擬觸控（不需要硬體）
      --stale-touch-timeout SEC  誤觸：觸點幾乎不動超過 SEC 秒就取消（預設 30，0 = 關閉）
      --server URL    改從 mtk-server 的 WebSocket 接收觸控（例：ws://127.0.0.1:7778）；--calibrate 時預設先試 ws://127.0.0.1:7778
      --calibrate     觸控校正：9 個十字同時顯示，任意點擊，Enter 儲存（常駐 mtk-server 執行中也可以）
      --calibrate-reset  刪除這個觸控螢幕的校正後離開
    """

    /// 常駐 mtk-server 的 WebSocket（預設埠）；校正時優先透過它收集，不必暫停常駐服務
    static let serverURL = URL(string: "ws://127.0.0.1:7778")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        handleTerminationSignals()
        var selector = DisplaySelector.environment ?? .automatic
        var simulate = false
        var configuration = MultiTouchManager.Configuration()
        var calibrate = false, calibrateReset = false
        var serverURL: URL?
        var args = CommandLineArguments(usage: Self.usage)
        while let a = args.next() {
            switch a {
            case "--list-displays":
                for d in DisplayLocator.onlineDisplays() { print(d) }
                exit(0)
            case "--display": selector = args.displaySelector()
            case "--rotate":
                let text = args.value(for: a, "角度")
                guard let rotation = Int(text).flatMap(ScreenMapping.Rotation.init(rawValue:)) else {
                    args.fail("--rotate 需要 0、90、180 或 270（收到「\(text)」）")
                }
                mapping.rotation = rotation
            case "--simulate": simulate = true
            case "--stale-touch-timeout": configuration.staleTouchTimeout = args.staleTouchTimeout()
            case "--server":
                let text = args.value(for: a, " WebSocket 網址")
                guard let url = URL(string: text), ["ws", "wss"].contains(url.scheme ?? "") else { args.fail("--server 需要 ws:// 網址（收到「\(text)」）") }
                serverURL = url
            case "--calibrate": calibrate = true
            case "--calibrate-reset": calibrateReset = true
            default: args.unknown(a)
            }
        }

        // 先開啟觸控裝置，auto 才能用面板實體尺寸挑選顯示器
        touchView = TouchView(frame: .zero)
        let handler: @Sendable (TouchFrame) -> Void = { frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { ViewerApp.shared?.receive(frame) } }
        }
        let source: TouchSource
        var sourceDescription = "模擬觸控"
        if simulate {
            source = SimulatedTouchSource()
            touchView.status = "模擬觸控"
        } else if serverURL != nil || calibrate || calibrateReset,
                  let server = ServerTouchSource.connect(to: serverURL ?? Self.serverURL, timeout: 1.5),
                  !server.connectedDevices.isEmpty || serverURL != nil {
            // 常駐 mtk-server 獨占著觸控螢幕：透過它的 WebSocket 收集（frame 中有校正前的座標）
            source = server
            sourceDescription = "透過 mtk-server"
            print("透過 mtk-server（\(server.url.absoluteString)）接收觸控")
        } else if let serverURL {
            print("無法連線 \(serverURL.absoluteString)（mtk-server 沒有執行或沒有開 WebSocket）")
            exit(1)
        } else {
            // 校正必須收集原始座標：不套用目前的校正
            if calibrate || calibrateReset { configuration.calibration = .disabled }
            let manager = MultiTouchManager(configuration: configuration)
            manager.logHandler = { message in
                print(message)
                DispatchQueue.main.async { MainActor.assumeIsolated { ViewerApp.shared?.setStatus(message) } }
            }
            source = manager
            sourceDescription = "直接讀取觸控螢幕"
        }
        source.frameHandler = handler
        self.source = source
        if !simulate {
            do {
                try source.start()
            } catch {
                touchView.status = "啟動失敗：\(error)"
            }
            if source.connectedDevices.isEmpty { touchView.status = "沒有偵測到觸控螢幕，接上後會自動開始" }
        }
        if calibrate || calibrateReset {
            // mtk-server --simulate 沒有 device 訊息：以模擬裝置資訊代替（只用於測試畫面）
            let simulated = simulate || (source is ServerTouchSource && source.connectedDevices.isEmpty)
            guard let device = source.connectedDevices.first ?? (simulated ? SimulatedTouchSource.deviceInfo : nil) else {
                print("找不到觸控螢幕：沒有接上，或被其他程式獨占（例如 Unity，或沒有開 WebSocket 的 mtk-server）。請關閉該程式後再試")
                exit(1)
            }
            if calibrateReset {
                let store = TouchCalibrationStore()
                do {
                    let removed = try store.remove(for: device)
                    print(removed > 0 ? "已刪除 \(device.product) 的觸控校正（\(store.url.path)）；執行中的 mtk-server 會在 2 秒內停止套用"
                                      : "\(device.product) 沒有觸控校正")
                    source.stop()
                    exit(0)
                } catch {
                    print("刪除失敗：\(error.localizedDescription)")
                    exit(1)
                }
            }
            let match = DisplayLocator.resolve(selector, panel: device)
            calibrationView = CalibrationView(context: .init(device: device, display: match?.display, sourceDescription: sourceDescription))
        }

        var screen = NSScreen.main ?? NSScreen.screens[0]
        let panel = source.connectedDevices.first
        if let match = DisplayLocator.resolve(selector, panel: panel) {
            print("顯示器：\(match.display)（\(match.note)）")
            mapping.displayID = match.display.id
            if let s = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == match.display.id
            }) {
                screen = s
            }
        } else {
            print("找不到符合 \(selector) 的顯示器，使用主螢幕")
            mapping.displayID = CGMainDisplayID()
        }

        let content: NSView = calibrationView ?? touchView
        content.frame = CGRect(origin: .zero, size: screen.frame.size)
        window = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: true)
        window.contentView = content
        window.backgroundColor = .black
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
        calibrationView?.toView = { [unowned self] x, y in
            content.convert(window.convertPoint(fromScreen: mapping.cocoaPoint(x: x, y: y)), from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        // 模擬來源在視窗建立後才開始，第一個 frame 才不會在沒有視窗時被丟掉
        if simulate { try? source.start() }
        scheduleSnapshotIfRequested(content)
    }

    /// SIGINT（Ctrl-C）、SIGTERM、SIGHUP 都走 NSApp.terminate，讓 applicationWillTerminate 停止觸控來源並印出摘要。
    /// 先設為 SIG_IGN 再用 DispatchSource 接收：系統預設動作會直接結束程序、跳過收尾；而在 shell 腳本中以 `&`
    /// 背景啟動時 SIGINT 會被繼承為「忽略」，不自己處理的話 Ctrl-C／kill -INT 完全沒有作用。
    private func handleTerminationSignals() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            signalSource.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            signalSource.resume()
            signalSources.append(signalSource)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        source?.stop()
        print(calibrationView?.summary ?? touchView.summary)
    }

    /// 開發與驗證用：環境變數 MTK_VIEWER_SNAPSHOT=路徑 時，執行 3 秒（或 MTK_VIEWER_SNAPSHOT_DELAY 秒）後把畫面輸出成 PNG 並結束。
    /// 直接繪製 view，不需要「螢幕錄製」權限
    private func scheduleSnapshotIfRequested(_ view: NSView) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MTK_VIEWER_SNAPSHOT"] else { return }
        let delay = environment["MTK_VIEWER_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print("已輸出畫面：\(path)")
                NSApp.terminate(nil)
            }
        }
    }

    private func setStatus(_ message: String) {
        touchView.status = message
        calibrationView?.status = message
    }

    private func receive(_ frame: TouchFrame) {
        guard let window else { return }
        if let calibrationView {
            calibrationView.apply(frame)
            return
        }
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
