import AppKit
import CoreGraphics
import Foundation
import MultiTouchKit

/// 把 MultiTouchManager（或 SimulatedTouchSource）的 frame 接到 GestureRecognizer 與 GestureOutput：
/// 座標換算到觸控螢幕所在的顯示器、長按與慣性的計時、前景 App 排除。
///
/// `handle(_:)` 必須在建構時指定的 `queue` 上呼叫（通常就是 MultiTouchManager.queue）。
public final class GestureController: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var recognizer = GestureRecognizer.Configuration()
        /// 這些 bundle ID 的 App 在前景時暫停手勢（手指落下當時判斷）
        public var excludedBundleIDs: Set<String> = []
        /// 計時頻率（長按、慣性捲動）
        public var tickRate: Double = 120

        public init() {}
    }

    public let configuration: Configuration
    public let queue: DispatchQueue
    public let output: GestureOutput
    /// 診斷訊息（在 `queue` 或主執行緒上呼叫）
    public var logHandler: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var _displayID: CGDirectDisplayID?
    private var _frontmostBundleID: String?
    private var observer: NSObjectProtocol?

    // 以下只在 queue 上存取
    private var recognizer: GestureRecognizer
    private var timer: DispatchSourceTimer?
    private var suspendedSequence = false
    private var activeTouchIDs: Set<UInt64> = []

    public init(configuration: Configuration = .init(), queue: DispatchQueue, output: GestureOutput) {
        self.configuration = configuration
        self.queue = queue
        self.output = output
        recognizer = GestureRecognizer(configuration: configuration.recognizer)
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        timer?.cancel()
    }

    /// 觸控螢幕所在的顯示器；nil 時不送出事件（找不到顯示器）
    public var displayID: CGDirectDisplayID? {
        get { lock.withLock { _displayID } }
        set { lock.withLock { _displayID = newValue } }
    }

    /// 開始追蹤前景 App（排除清單用）。必須在主執行緒呼叫。
    @MainActor
    public func startObservingFrontmostApp() {
        guard observer == nil, !configuration.excludedBundleIDs.isEmpty else { return }
        lock.withLock { _frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.lock.withLock { self?._frontmostBundleID = app?.bundleIdentifier }
        }
    }

    private var frontmostIsExcluded: Bool {
        guard !configuration.excludedBundleIDs.isEmpty else { return false }
        return lock.withLock { _frontmostBundleID.map(configuration.excludedBundleIDs.contains) ?? false }
    }

    // MARK: - 輸入（在 queue 上）

    public func handle(_ frame: TouchFrame) {
        let wasEmpty = activeTouchIDs.isEmpty
        for t in frame.touches {
            if t.phase.isTerminal { activeTouchIDs.remove(t.id) } else { activeTouchIDs.insert(t.id) }
        }
        // 第一根手指落下時判斷前景 App；被排除就忽略整個手勢直到所有手指離開
        if wasEmpty, frame.touches.contains(where: { $0.phase == .began }), frontmostIsExcluded {
            suspendedSequence = true
            send(recognizer.reset())
            updateTimer()
        }
        if suspendedSequence {
            if activeTouchIDs.isEmpty { suspendedSequence = false }
            return
        }
        let time = Double(frame.timestamp) / 1e9
        guard let displayID else { return }
        let mapping = ScreenMapping(displayID: displayID)
        let touches = frame.touches.map {
            GestureTouch(id: $0.id, position: mapping.globalPoint(x: $0.x, y: $0.y), isDown: !$0.phase.isTerminal)
        }
        send(recognizer.process(touches, at: time))
        updateTimer()
    }

    /// 取消進行中的手勢（裝置移除、停止時）
    public func cancel() {
        send(recognizer.reset())
        activeTouchIDs.removeAll()
        suspendedSequence = false
        updateTimer()
    }

    private func send(_ events: [GestureEvent]) {
        guard !events.isEmpty else { return }
        output.send(events)
    }

    private func updateTimer() {
        if recognizer.needsTick {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1 / configuration.tickRate, leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        } else if let timer {
            timer.cancel()
            self.timer = nil
        }
    }

    private func tick() {
        send(recognizer.tick(at: Double(MultiTouchClock.now()) / 1e9))
        updateTimer()
    }
}
