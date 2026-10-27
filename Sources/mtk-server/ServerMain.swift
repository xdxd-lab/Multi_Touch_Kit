// mtk-server：獨占觸控螢幕，透過 UDP JSON、WebSocket、TUIO 1.1 廣播給其他程式。
import CoreGraphics
import Foundation
import MultiTouchKit
import MultiTouchKitGestures

struct ServerOptions {
    var udpTargets = ["127.0.0.1:7777"]
    var wsPort: UInt16? = 7778
    var wsLAN = false
    var tuioTarget: String? = "127.0.0.1:3333"
    var exclusive = true
    var vendorID: Int?
    var productID: Int?
    var simulate = false
    var simulatePattern = SimulatedTouchSource.Pattern.drums
    var verbose = false
    var gestures = false
    var gesturesDryRun = false
    var gesturesSwipe = SwipeMode.keys
    var gesturesExclude: Set<String> = []
    var gesturesLog = false
    var releaseButtons = false
    var gesturesRotationGain: Double?
    var gesturesMagnifyExponent: Double?
    var gesturesMomentumGain: Double?
    var display = DisplaySelector.environment ?? .automatic

    static let usage = """
    用法：mtk-server [選項]
      --udp HOST:PORT   UDP JSON 目的地，可重複指定（預設 127.0.0.1:7777）
      --no-udp          不送 UDP JSON
      --ws PORT         WebSocket 埠（預設 7778）
      --ws-lan          WebSocket 開放給區網（預設只接受本機）
      --no-ws           不開 WebSocket
      --tuio HOST:PORT  TUIO 1.1 目的地（預設 127.0.0.1:3333）
      --no-tuio         不送 TUIO
      --vid N / --pid N 只使用指定的 Vendor／Product ID（可寫 0x222A）
      --shared          不獨占裝置（系統游標仍會跟著動）
      --display SEL     觸控螢幕所在的顯示器，放在 WebSocket hello 的 display 欄位（預設 auto 或 MTK_DISPLAY）
                        例：edid:6474:aa15、name:Sculptor,size:1920x1080（格式見 docs/server-protocol.md）
      --list-displays   列出顯示器後離開
      --simulate        使用模擬觸控（不需要硬體）
      --simulate-pattern drums|gestures  模擬觸控的模式（隱含 --simulate；預設 drums）。
                        gestures：每 12 秒依序做出各種手勢，搭配 --gestures 驗證辨識
      --verbose         印出每個觸控事件
      --gestures        把觸控合成為系統操作（點擊、拖曳、右鍵、捲動、縮放、旋轉、多指滑動），
                        同時照常廣播 10 點；需要「輔助使用」權限（見 docs/gestures.md）
      --gestures-dry-run  只辨識並印出手勢、不送事件（隱含 --gestures；--simulate 時一律為 dry-run）
      --gestures-swipe dock|keys  三／四指滑動的送出方式（預設 keys：Control＋方向鍵；dock：跟手的 Dock 手勢，實驗性）
      --gestures-exclude BUNDLE_ID[,…]  這些 App 在前景時暫停手勢（例：com.unity3d.UnityEditor5.x）
      --gestures-log    送出事件時也印出手勢摘要（與 dry-run 相同格式，標籤為 [手勢]）
      --release-buttons 在目前游標位置送出左／右／中鍵放開後離開（mtk-server 異常結束、滑鼠鍵卡住時的復原）
      --gestures-rotation-gain X     旋轉增益（送出角度 = 手指角度 × X，預設 1.5）
      --gestures-magnify-exponent X  縮放增益（送出倍率 = 指距倍率^X，預設 0.6；1 = 等比例）
      --gestures-momentum-gain X     捲動慣性距離倍數（預設 1；2 = 滑行約兩倍遠）
    """

    static func parse(_ arguments: [String]) -> ServerOptions {
        var o = ServerOptions()
        var customUDP = false
        var it = arguments.makeIterator()
        func number(_ text: String?) -> Int? {
            guard let text else { return nil }
            return text.lowercased().hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text)
        }
        func fail(_ message: String) -> Never {
            print(message)
            print(usage)
            exit(2)
        }
        while let a = it.next() {
            switch a {
            case "--udp":
                guard let target = it.next(), UDPSender.parse(target) != nil else { fail("--udp 需要 HOST:PORT") }
                if !customUDP { o.udpTargets = [] }
                customUDP = true
                o.udpTargets.append(target)
            case "--no-udp": o.udpTargets = []; customUDP = true
            case "--ws":
                guard let port = number(it.next()).flatMap(UInt16.init(exactly:)) else { fail("--ws 需要埠號") }
                o.wsPort = port
            case "--ws-lan": o.wsLAN = true
            case "--no-ws": o.wsPort = nil
            case "--tuio":
                guard let target = it.next(), UDPSender.parse(target) != nil else { fail("--tuio 需要 HOST:PORT") }
                o.tuioTarget = target
            case "--no-tuio": o.tuioTarget = nil
            case "--vid": o.vendorID = number(it.next())
            case "--pid": o.productID = number(it.next())
            case "--shared": o.exclusive = false
            case "--display":
                guard let selector = it.next().flatMap(DisplaySelector.init) else { fail("--display 格式錯誤") }
                o.display = selector
            case "--list-displays":
                for d in DisplayLocator.onlineDisplays() { print(d) }
                exit(0)
            case "--simulate": o.simulate = true
            case "--simulate-pattern":
                guard let pattern = it.next().flatMap(SimulatedTouchSource.Pattern.init(rawValue:)) else {
                    fail("--simulate-pattern 需要 " + SimulatedTouchSource.Pattern.allCases.map(\.rawValue).joined(separator: " 或 "))
                }
                o.simulate = true
                o.simulatePattern = pattern
            case "--verbose": o.verbose = true
            case "--gestures": o.gestures = true
            case "--gestures-dry-run": o.gestures = true; o.gesturesDryRun = true
            case "--gestures-swipe":
                guard let mode = it.next().flatMap(SwipeMode.init(rawValue:)) else { fail("--gestures-swipe 需要 dock 或 keys") }
                o.gesturesSwipe = mode
            case "--gestures-exclude":
                guard let list = it.next(), !list.isEmpty else { fail("--gestures-exclude 需要 bundle ID") }
                o.gesturesExclude.formUnion(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            case "--gestures-log": o.gesturesLog = true
            case "--release-buttons": o.releaseButtons = true
            case "--gestures-rotation-gain":
                guard let v = it.next().flatMap(Double.init), v > 0 else { fail("--gestures-rotation-gain 需要大於 0 的數字") }
                o.gesturesRotationGain = v
            case "--gestures-magnify-exponent":
                guard let v = it.next().flatMap(Double.init), v > 0 else { fail("--gestures-magnify-exponent 需要大於 0 的數字") }
                o.gesturesMagnifyExponent = v
            case "--gestures-momentum-gain":
                guard let v = it.next().flatMap(Double.init), v > 0 else { fail("--gestures-momentum-gain 需要大於 0 的數字") }
                o.gesturesMomentumGain = v
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                fail("未知選項：\(a)")
            }
        }
        if !o.gestures && (o.gesturesSwipe != .keys || !o.gesturesExclude.isEmpty || o.gesturesLog
                           || o.gesturesRotationGain != nil || o.gesturesMagnifyExponent != nil || o.gesturesMomentumGain != nil) {
            print("注意：--gestures-* 選項需搭配 --gestures 才會生效")
        }
        return o
    }
}

@main
struct ServerCommand {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let options = ServerOptions.parse(Array(CommandLine.arguments.dropFirst()))
        if options.releaseButtons {
            let pressed = CGEventGestureOutput.systemButtonsPressed
            CGEventGestureOutput.releaseSystemButtons()
            print(pressed.isEmpty ? "已送出滑鼠鍵放開（系統原本沒有按住的鍵）" : "已放開卡住的滑鼠鍵：\(pressed.map(\.rawValue))")
            if !CGEventGestureOutput.isTrusted(prompt: false) { print("注意：沒有「輔助使用」權限時系統會丟棄這些事件") }
            exit(0)
        }
        let server = ServerRuntime(options: options)
        server.start()
        // 用 RunLoop（而非 dispatchMain）：NSWorkspace 的前景 App 通知需要主執行緒的 run loop
        withExtendedLifetime(server) { RunLoop.main.run() }
    }
}

/// 所有可變狀態都只在觸控來源的佇列上存取
final class ServerRuntime: @unchecked Sendable {
    let options: ServerOptions
    private var manager: MultiTouchManager?
    private var simulator: SimulatedTouchSource?
    private let queue: DispatchQueue
    private var udp: [UDPSender] = []
    private var tuioSender: UDPSender?
    private var tuio = TUIOEncoder(source: "MultiTouchKit@\(ProcessInfo.processInfo.hostName)")
    private var webSocket: WebSocketHub?
    private var active: [UInt64: Touch] = [:]
    private var signalSources: [DispatchSourceSignal] = []
    private var gestures: GestureController?
    /// 觸控螢幕所在的顯示器（在主執行緒解析，才拿得到名稱）
    private let displayLock = NSLock()
    private var _display: DisplayInfo?
    private var display: DisplayInfo? { displayLock.withLock { _display } }

    init(options: ServerOptions) {
        self.options = options
        if options.simulate {
            let source = SimulatedTouchSource(pattern: options.simulatePattern)
            simulator = source
            queue = source.queue
        } else {
            var configuration = MultiTouchManager.Configuration()
            configuration.exclusive = options.exclusive
            configuration.vendorID = options.vendorID
            configuration.productID = options.productID
            let manager = MultiTouchManager(configuration: configuration)
            self.manager = manager
            queue = manager.queue
        }
    }

    private var devices: [MultiTouchDeviceInfo] {
        simulator != nil ? [SimulatedTouchSource.deviceInfo] : manager?.connectedDevices ?? []
    }

    func start() {
        for target in options.udpTargets {
            guard let (host, port) = UDPSender.parse(target), let sender = UDPSender(host: host, port: port) else {
                print("無法建立 UDP 目的地 \(target)")
                exit(1)
            }
            udp.append(sender)
            print("UDP JSON → \(sender.label)")
        }
        if let target = options.tuioTarget {
            guard let (host, port) = UDPSender.parse(target), let sender = UDPSender(host: host, port: port) else {
                print("無法建立 TUIO 目的地 \(target)")
                exit(1)
            }
            tuioSender = sender
            print("TUIO 1.1 → \(sender.label)")
        }
        if let port = options.wsPort {
            do {
                webSocket = try WebSocketHub(port: port, lan: options.wsLAN, queue: queue,
                                             hello: { [self] in TouchJSON.hello(server: "mtk-server", devices: devices, display: display) },
                                             log: { print($0) })
            } catch {
                print("無法開啟 WebSocket 埠 \(port)：\(error)")
                exit(1)
            }
        }

        if options.gestures { startGestures() }

        if let simulator {
            simulator.frameHandler = { [self] in handle($0) }
            print("使用模擬觸控來源")
            simulator.start()
        } else if let manager {
            manager.logHandler = { print($0) }
            manager.frameHandler = { [self] in handle($0) }
            manager.deviceHandler = { [self] in handle($0) }
            do {
                try manager.start()
            } catch {
                print("啟動失敗：\(error)")
                exit(1)
            }
            if manager.connectedDevices.isEmpty { print("目前沒有偵測到觸控螢幕，接上後會自動開始。") }
        }
        resolveDisplay()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let runtime = Unmanaged<ServerRuntime>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { runtime.resolveDisplay() }
        }, Unmanaged.passUnretained(self).toOpaque())

        // SIGHUP：關閉終端機／herdr pane；SIGTERM：pkill、launchctl bootout。
        // 都要先放開手勢按住的滑鼠鍵再結束，否則系統會一直認為左鍵按住（SIGKILL 無法攔截，見 --release-buttons）
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [self] in
                gestures?.shutdown()
                webSocket?.cancel()
                manager?.stop()
                simulator?.stop()
                print("已停止")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func startGestures() {
        var dryRun = options.gesturesDryRun
        if options.simulate && !dryRun {
            dryRun = true
            print("手勢：--simulate 時一律為 dry-run（模擬觸控會在桌面上到處點擊），只印出辨識結果")
        }
        let output: GestureOutput
        if dryRun {
            output = LoggingGestureOutput(swipeMode: options.gesturesSwipe) { print($0) }
        } else {
            let events = CGEventGestureOutput(swipeMode: options.gesturesSwipe)
            // 上次異常結束（例如 SIGKILL、當機後被 LaunchAgent 重新啟動）留下按住的鍵：啟動時先放開
            if !CGEventGestureOutput.systemButtonsPressed.isEmpty {
                print("手勢：啟動時偵測到滑鼠鍵按住中（可能是上次異常結束），先送出放開")
                CGEventGestureOutput.releaseSystemButtons()
            }
            output = options.gesturesLog
                ? CombinedGestureOutput([events, LoggingGestureOutput(label: "手勢", swipeMode: options.gesturesSwipe) { print($0) }])
                : events
            if !CGEventGestureOutput.isTrusted(prompt: true) {
                print("""
                手勢：尚未取得「輔助使用」權限，系統會丟棄合成的事件。
                  請到 系統設定 → 隱私權與安全性 → 輔助使用，允許執行 mtk-server 的 App（終端機或 mtk-server 本身），然後重新啟動。
                """)
            }
        }
        var configuration = GestureController.Configuration()
        configuration.excludedBundleIDs = options.gesturesExclude
        if let v = options.gesturesRotationGain { configuration.recognizer.rotationGain = v }
        if let v = options.gesturesMagnifyExponent { configuration.recognizer.magnifyExponent = v }
        // 慣性距離 ≈ 速度 ÷ friction，所以距離倍數 = friction 的倒數倍
        if let v = options.gesturesMomentumGain { configuration.recognizer.momentumFriction /= v }
        let controller = GestureController(configuration: configuration, queue: queue, output: output)
        controller.logHandler = { print($0) }
        MainActor.assumeIsolated { controller.startObservingWorkspace() }
        gestures = controller
        var notes = [dryRun ? "dry-run" : "送出系統事件", "三／四指滑動：\(options.gesturesSwipe.rawValue)"]
        if options.gesturesLog && !dryRun { notes.append("記錄手勢") }
        notes.append(String(format: "旋轉增益 %.2g、縮放增益 %.2g、慣性倍數 %.2g", configuration.recognizer.rotationGain,
                            configuration.recognizer.magnifyExponent, options.gesturesMomentumGain ?? 1))
        if !options.gesturesExclude.isEmpty { notes.append("排除 \(options.gesturesExclude.sorted().joined(separator: ", "))") }
        print("手勢合成：" + notes.joined(separator: "、"))
    }

    private func handle(_ frame: TouchFrame) {
        gestures?.handle(frame)
        for t in frame.touches {
            if t.phase.isTerminal { active[t.id] = nil } else { active[t.id] = t }
        }
        let json = TouchJSON.frame(frame)
        if !udp.isEmpty {
            let data = Data(json.utf8)
            for sender in udp { sender.send(data) }
        }
        webSocket?.broadcast(json)
        if let tuioSender {
            let alive = active.values.sorted { $0.id < $1.id }
            let updated = frame.touches.filter { $0.phase == .began || $0.phase == .moved }
            tuioSender.send(tuio.encode(alive: alive, updated: updated, timestamp: frame.timestamp))
        }
        if options.verbose {
            for t in frame.touches where t.phase != .stationary {
                print(String(format: "裝置 %d  touch %llu（cid %d）%@  x=%.4f y=%.4f",
                             frame.deviceID, t.id, t.contactID, t.phase.description, t.x, t.y))
            }
        }
    }

    /// 必須在主執行緒呼叫
    func resolveDisplay() {
        let match = DisplayLocator.resolve(options.display, panel: devices.first)
        let previous = display
        displayLock.withLock { _display = match?.display }
        gestures?.displayID = match?.display.id
        guard match?.display != previous || previous == nil else { return }
        if let match {
            print("觸控對應顯示器：\(match.display)（\(match.note)）")
        } else {
            print("找不到符合 \(options.display) 的顯示器")
        }
    }

    private func handle(_ event: DeviceEvent) {
        let message: String
        switch event {
        case .added(let info):
            message = TouchJSON.device(info, event: "added")
            DispatchQueue.main.async { [self] in resolveDisplay() }
        case .removed(let info):
            message = TouchJSON.device(info, event: "removed")
            gestures?.cancel()
        case .reinitialized(let info): message = TouchJSON.device(info, event: "reinitialized")
        }
        let data = Data(message.utf8)
        for sender in udp { sender.send(data) }
        webSocket?.broadcast(message)
    }
}
