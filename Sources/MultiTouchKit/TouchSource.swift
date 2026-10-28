import Foundation

/// 觸控 frame 的來源：實體觸控螢幕（`MultiTouchManager`）或模擬（`SimulatedTouchSource`）。
/// 程式只依賴這個介面時，`--simulate` 之類的切換不必到處分支。
public protocol TouchSource: AnyObject, Sendable {
    /// `frameHandler` 執行的序列佇列；需要與觸控處理同步的狀態請只在這個佇列上存取
    var queue: DispatchQueue { get }
    /// 每個 frame 呼叫一次（在 `queue` 上）；任何執行緒皆可設定
    var frameHandler: (@Sendable (TouchFrame) -> Void)? { get set }
    /// 目前提供觸控的裝置（任何執行緒皆可讀取）
    var connectedDevices: [MultiTouchDeviceInfo] { get }
    /// 開始產生 frame；已在執行時不做任何事
    func start() throws
    /// 停止；仍在螢幕上的觸點會先以 cancelled 送出
    func stop()
}

extension MultiTouchManager: TouchSource {}

extension SimulatedTouchSource: TouchSource {
    public var connectedDevices: [MultiTouchDeviceInfo] { [Self.deviceInfo] }
}
