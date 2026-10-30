import Foundation
import MultiTouchKit
import Network

/// 非阻塞 UDP 傳送端（JSON 與 TUIO 共用）。
/// 以 connect() 固定目的地：之後的 send() 不必每次查路由、複製位址（每 frame 的核心成本約少 1/4）。
/// 沒有接收端時下一次 send 可能回傳 ECONNREFUSED，與 sendto 一樣忽略。
final class UDPSender: @unchecked Sendable {
    let label: String
    private let fd: Int32
    private var address = sockaddr_storage()
    private let addressLength: socklen_t

    init?(host: String, port: UInt16) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        fd = socket(info.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        addressLength = info.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &address) { raw in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: info.pointee.ai_addr, count: Int(info.pointee.ai_addrlen)))
        }
        label = "\(host):\(port)"
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addressLength) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
    }

    deinit {
        close(fd)
    }

    func send(_ bytes: UnsafeRawBufferPointer) {
        _ = Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
    }

    func send(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { send($0) }
    }

    func send(_ data: Data) {
        data.withUnsafeBytes { send($0) }
    }

    /// 解析 "HOST:PORT"（IPv6 請寫成 [::1]:7777）
    static func parse(_ text: String) -> (host: String, port: UInt16)? {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (host.isEmpty ? "127.0.0.1" : host, port)
    }
}

/// WebSocket 伺服器：把 JSON 文字訊息廣播給所有連線（Network.framework）
final class WebSocketHub: @unchecked Sendable {
    private let queue: DispatchQueue
    private let listener: NWListener
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let hello: @Sendable () -> String
    private let log: @Sendable (String) -> Void

    /// - Parameter lan: false 時只接受本機（loopback）連線
    init(port: UInt16, lan: Bool, queue: DispatchQueue,
         hello: @escaping @Sendable () -> String, log: @escaping @Sendable (String) -> Void) throws {
        self.queue = queue
        self.hello = hello
        self.log = log
        let parameters = NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.allowLocalEndpointReuse = true
        if !lan { parameters.requiredInterfaceType = .loopback }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("WebSocket 伺服器：ws://\(lan ? "<本機 IP>" : "127.0.0.1"):\(port)")
            case .failed(let error): log("WebSocket 伺服器錯誤：\(error)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
        for c in connections.values { c.cancel() }
        connections.removeAll()
    }

    /// 有沒有已連線的用戶端（在 queue 上讀取）
    var hasClients: Bool { !connections.isEmpty }

    func broadcast(_ text: String) {
        guard !connections.isEmpty else { return }
        broadcast(Data(text.utf8))
    }

    /// `data` 為 UTF-8 文字
    func broadcast(_ data: Data) {
        for c in connections.values { send(data, to: c) }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                send(Data(hello().utf8), to: connection)
                log("WebSocket 用戶端連線：\(connection.endpoint)")
            case .failed:
                // 失敗的連線不會自行釋放：必須 cancel（之後會再收到 .cancelled）
                connections[key] = nil
                connection.cancel()
            case .cancelled:
                connections[key] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    /// 持續接收以偵測關閉；用戶端送來的內容一律忽略
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] _, context, _, error in
            guard let self, let connection else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                connection.cancel()
            } else {
                receive(on: connection)
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "mtk", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

/// 把每個 frame 分送給 UDP JSON、WebSocket、TUIO（在觸控來源的 queue 上呼叫）。
/// 沒有接收者時不編碼；JSON 與 TUIO 的位元組緩衝區每 frame 重複使用。
final class OutputFanout {
    var udp: [UDPSender] = []
    var webSocket: WebSocketHub?
    var tuioSender: UDPSender?
    private var tuio: TUIOEncoder
    /// 仍在螢幕上的觸點，依 id 排序（TUIO alive；最多約 10 筆，線性搜尋）
    private var alive: [Touch] = []
    private var json: [UInt8] = []
    private var osc: [UInt8] = []

    init(tuioSource: String) {
        tuio = TUIOEncoder(source: tuioSource)
    }

    func send(_ frame: TouchFrame) {
        let wantsJSON = !udp.isEmpty || webSocket?.hasClients == true
        if wantsJSON {
            json.removeAll(keepingCapacity: true)
            TouchJSON.frameBytes(frame, into: &json)
            json.withUnsafeBytes { bytes in for sender in udp { sender.send(bytes) } }
            if let webSocket, webSocket.hasClients { webSocket.broadcast(Data(json)) }
        }
        updateAlive(frame.touches)
        if let tuioSender {
            tuio.encode(alive: alive, updated: frame.touches, onlyChanged: true, timestamp: frame.timestamp, into: &osc)
            tuioSender.send(osc)
        }
    }

    /// 裝置事件（加入、移除、重新初始化）
    func send(message: String) {
        let data = Data(message.utf8)
        for sender in udp { sender.send(data) }
        webSocket?.broadcast(data)
    }

    private func updateAlive(_ touches: [Touch]) {
        for t in touches {
            let index = alive.firstIndex { $0.id >= t.id }
            if t.phase.isTerminal {
                if let index, alive[index].id == t.id { alive.remove(at: index) }
            } else if let index, alive[index].id == t.id {
                alive[index] = t
            } else {
                alive.insert(t, at: index ?? alive.endIndex)
            }
        }
    }
}
