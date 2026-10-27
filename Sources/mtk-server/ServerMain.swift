// mtk-server：獨占觸控螢幕，透過 UDP JSON、WebSocket、TUIO 1.1 廣播給其他程式。
import CoreGraphics
import Foundation
import MultiTouchKit

struct ServerOptions {
    var udpTargets = ["127.0.0.1:7777"]
    var wsPort: UInt16? = 7778
    var wsLAN = false
    var tuioTarget: String? = "127.0.0.1:3333"
    var exclusive = true
    var vendorID: Int?
    var productID: Int?
    var simulate = false
    var verbose = false
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
      --verbose         印出每個觸控事件
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
            case "--verbose": o.verbose = true
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                fail("未知選項：\(a)")
            }
        }
        return o
    }
}

@main
struct ServerCommand {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let server = ServerRuntime(options: ServerOptions.parse(Array(CommandLine.arguments.dropFirst())))
        server.start()
        withExtendedLifetime(server) { dispatchMain() }
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
    /// 觸控螢幕所在的顯示器（在主執行緒解析，才拿得到名稱）
    private let displayLock = NSLock()
    private var _display: DisplayInfo?
    private var display: DisplayInfo? { displayLock.withLock { _display } }

    init(options: ServerOptions) {
        self.options = options
        if options.simulate {
            let source = SimulatedTouchSource()
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

        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [self] in
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

    private func handle(_ frame: TouchFrame) {
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
        case .removed(let info): message = TouchJSON.device(info, event: "removed")
        case .reinitialized(let info): message = TouchJSON.device(info, event: "reinitialized")
        }
        let data = Data(message.utf8)
        for sender in udp { sender.send(data) }
        webSocket?.broadcast(message)
    }
}
