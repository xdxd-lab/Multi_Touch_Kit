import Foundation
import Network

/// 非阻塞 UDP 傳送端（JSON 與 TUIO 共用）
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
    }

    deinit {
        close(fd)
    }

    func send(_ data: Data) {
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, addressLength)
                }
            }
        }
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

    func broadcast(_ text: String) {
        guard !connections.isEmpty else { return }
        let data = Data(text.utf8)
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
            case .failed, .cancelled:
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
