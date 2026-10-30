import Foundation
import MultiTouchKit

/// 從執行中的 mtk-server（WebSocket，見 docs/server-protocol.md）接收觸控。
///
/// 校正時使用：常駐的 mtk-server 獨占著觸控螢幕，viewer 不必請使用者暫停它，直接以 frame 中校正前的座標
/// （`ux`／`uy`，沒有套用校正時就是 `x`／`y`）收集。存檔後 mtk-server 會自動重新載入校正檔。
final class ServerTouchSource: TouchSource, @unchecked Sendable {
    let queue = DispatchQueue(label: "mtk-viewer.server", qos: .userInteractive)
    let url: URL
    private let _frameHandler = Locked<(@Sendable (TouchFrame) -> Void)?>(nil)
    private let devices = Locked<[MultiTouchDeviceInfo]>([])
    private let helloReceived = DispatchSemaphore(value: 0)
    /// stop() 在主執行緒、receive 的回呼在 URLSession 的佇列上存取
    private let connection = Locked<(task: URLSessionWebSocketTask, session: URLSession)?>(nil)

    var frameHandler: (@Sendable (TouchFrame) -> Void)? {
        get { _frameHandler.wrapped }
        set { _frameHandler.wrapped = newValue }
    }

    var connectedDevices: [MultiTouchDeviceInfo] { devices.wrapped }

    private init(url: URL) {
        self.url = url
    }

    /// 連線並等待 hello；`timeout` 內沒有回應（mtk-server 沒有執行或沒開 WebSocket）時回傳 nil
    static func connect(to url: URL, timeout: TimeInterval) -> ServerTouchSource? {
        let source = ServerTouchSource(url: url)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        source.connection.wrapped = (task, session)
        task.resume()
        source.receive()
        guard source.helloReceived.wait(timeout: .now() + timeout) == .success else {
            source.stop()
            return nil
        }
        return source
    }

    /// 連線時就已開始接收
    func start() throws {}

    func stop() {
        guard let (task, session) = connection.withLock({ c in defer { c = nil }; return c }) else { return }
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func receive() {
        connection.wrapped?.task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                queue.async { self.handle(text) }
                receive()
            case .success(.data(let data)):
                queue.async { self.handle(String(decoding: data, as: UTF8.self)) }
                receive()
            case .success:
                receive()
            case .failure:
                break  // 連線中斷：校正畫面會顯示沒有觸控
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "hello":
            devices.wrapped = (message["devices"] as? [[String: Any]] ?? []).compactMap(Self.device)
            helloReceived.signal()
        case "device":
            guard let info = (message["device"] as? [String: Any]).flatMap(Self.device) else { return }
            devices.withLock { list in
                list.removeAll { $0.id == info.id }
                if message["event"] as? String != "removed" { list.append(info) }
            }
        case "frame":
            if let frame = Self.frame(message) { frameHandler?(frame) }
        default:
            break
        }
    }

    static func device(_ d: [String: Any]) -> MultiTouchDeviceInfo? {
        guard let id = d["id"] as? Int else { return nil }
        return MultiTouchDeviceInfo(
            id: id, vendorID: d["vendorId"] as? Int ?? 0, productID: d["productId"] as? Int ?? 0,
            manufacturer: d["manufacturer"] as? String ?? "", product: d["product"] as? String ?? "",
            serialNumber: d["serial"] as? String ?? "", locationID: d["locationId"] as? Int ?? 0,
            maxContacts: d["maxContacts"] as? Int ?? 0, slotsPerReport: d["slotsPerReport"] as? Int ?? 0,
            physicalWidthMillimeters: d["widthMM"] as? Double, physicalHeightMillimeters: d["heightMM"] as? Double,
            hasScanTime: false, exclusive: d["exclusive"] as? Bool ?? false, isCalibrated: d["calibrated"] as? Bool ?? false)
    }

    static func frame(_ m: [String: Any]) -> TouchFrame? {
        guard let touches = m["touches"] as? [[String: Any]] else { return nil }
        let phases: [String: TouchPhase] = ["began": .began, "moved": .moved, "stationary": .stationary, "ended": .ended, "cancelled": .cancelled]
        return TouchFrame(
            deviceID: m["device"] as? Int ?? 0, sequence: (m["seq"] as? NSNumber)?.uint64Value ?? 0,
            timestamp: (m["t"] as? NSNumber)?.uint64Value ?? 0, scanTime: nil,
            touches: touches.compactMap { t in
                guard let id = (t["id"] as? NSNumber)?.uint64Value, let phase = (t["phase"] as? String).flatMap({ phases[$0] }),
                      let x = t["x"] as? Double, let y = t["y"] as? Double else { return nil }
                return Touch(id: id, contactID: t["cid"] as? Int ?? 0, phase: phase, x: x, y: y,
                             rawX: t["rx"] as? Int ?? 0, rawY: t["ry"] as? Int ?? 0,
                             uncalibratedX: t["ux"] as? Double, uncalibratedY: t["uy"] as? Double)
            })
    }
}
