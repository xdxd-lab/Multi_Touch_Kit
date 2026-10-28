import AppKit
import CoreGraphics
import Foundation
import MultiTouchKit

/// 把 MultiTouchManager（或 SimulatedTouchSource）的 frame 接到 GestureRecognizer 與 GestureOutput：
/// 座標換算到觸控螢幕所在的顯示器、慣性的計時、前景 App 排除，以及「不讓滑鼠鍵卡住」的各種保護：
/// 結束（`shutdown`）、裝置移除（`cancel`）、系統睡眠、切到被排除的 App、觸控報告中斷（watchdog）時，
/// 都會放開按住的滑鼠鍵並結束進行中的連續手勢。
///
/// `handle(_:)` 必須在建構時指定的 `queue` 上呼叫（通常就是 MultiTouchManager.queue）。
public final class GestureController: @unchecked Sendable {
    /// 建立 controller 時的設定
    public struct Configuration: Sendable {
        /// 手勢辨識參數
        public var recognizer = GestureRecognizer.Configuration()
        /// 這些 bundle ID 的 App 在前景時暫停手勢（手指落下當時判斷）
        public var excludedBundleIDs: Set<String> = []
        /// 計時頻率（慣性捲動）
        public var tickRate: Double = 120
        /// 有手指在螢幕上、卻超過這麼久沒有收到任何觸控報告（裝置斷線、卡住）時，取消手勢並放開按鍵（秒）
        public var watchdogTimeout: Double = 2

        /// 預設值：不排除任何 App、120 Hz 慣性計時、2 秒 watchdog
        public init() {}
    }

    /// 建立時的設定
    public let configuration: Configuration
    /// `handle`／`cancel`／`shutdown` 必須在這個佇列上呼叫；慣性與 watchdog 的計時器也在這裡執行
    public let queue: DispatchQueue
    /// 手勢事件的送出端
    public let output: GestureOutput
    /// 診斷訊息（在 `queue` 或主執行緒上呼叫）；任何執行緒皆可設定
    public var logHandler: (@Sendable (String) -> Void)? {
        get { _logHandler.wrapped }
        set { _logHandler.wrapped = newValue }
    }

    private let _displayID = Locked<CGDirectDisplayID?>(nil)
    private let _frontmostBundleID = Locked<String?>(nil)
    private let _logHandler = Locked<(@Sendable (String) -> Void)?>(nil)
    private var observers: [NSObjectProtocol] = []

    // 以下只在 queue 上存取
    private var recognizer: GestureRecognizer
    private var timer: DispatchSourceTimer?
    private var suspendedSequence = false
    private var activeTouchIDs: Set<UInt64> = []
    /// 控制器回報 Confidence = false（手掌等非刻意觸碰）的觸點，整個生命週期都不參與手勢。ILITEK 沒有這個欄位
    private var ignoredTouchIDs: Set<UInt64> = []
    private var watchdog: DispatchSourceTimer?
    private var lastFrameTime = 0.0
    private var stopped = false

    /// - Parameters:
    ///   - queue: 觸控來源的佇列（通常是 `MultiTouchManager.queue`）
    ///   - output: 送出端，例如 `CGEventGestureOutput` 或 dry-run 用的 `LoggingGestureOutput`
    public init(configuration: Configuration = .init(), queue: DispatchQueue, output: GestureOutput) {
        self.configuration = configuration
        self.queue = queue
        self.output = output
        recognizer = GestureRecognizer(configuration: configuration.recognizer)
    }

    deinit {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        timer?.cancel()
        watchdog?.cancel()
    }

    /// 觸控螢幕所在的顯示器；nil 時不送出事件（找不到顯示器）
    public var displayID: CGDirectDisplayID? {
        get { _displayID.wrapped }
        set { _displayID.wrapped = newValue }
    }

    /// 開始追蹤系統睡眠與前景 App（排除清單用）。必須在主執行緒呼叫，且主執行緒要有 run loop。
    @MainActor
    public func startObservingWorkspace() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { self.cancel(reason: "系統即將睡眠") }
        })
        guard !configuration.excludedBundleIDs.isEmpty else { return }
        _frontmostBundleID.wrapped = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) {
            [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self else { return }
            let id = app?.bundleIdentifier
            queue.async { self.frontmostChanged(to: id) }
        })
    }

    /// 前景 App 改變（在 queue 上）。切到被排除的 App 時，進行中的手勢立即取消並忽略到所有手指離開。
    func frontmostChanged(to bundleID: String?) {
        _frontmostBundleID.wrapped = bundleID
        guard let bundleID, configuration.excludedBundleIDs.contains(bundleID), !activeTouchIDs.isEmpty, !suspendedSequence else { return }
        logHandler?("手勢：切換到排除的 App（\(bundleID)），取消進行中的手勢並放開按鍵")
        send(recognizer.reset())
        output.releaseAll()
        suspendedSequence = true
        updateTimer()
    }

    private var frontmostIsExcluded: Bool {
        guard !configuration.excludedBundleIDs.isEmpty else { return false }
        return _frontmostBundleID.wrapped.map(configuration.excludedBundleIDs.contains) ?? false
    }

    // MARK: - 輸入（在 queue 上）

    /// 處理一個觸控 frame（在 `queue` 上）：換算到觸控螢幕的全域座標、辨識並送出事件。
    /// `displayID` 為 nil（找不到顯示器）時只追蹤手指、不送出事件
    public func handle(_ frame: TouchFrame) {
        guard !stopped else { return }
        lastFrameTime = Double(MultiTouchClock.now()) / 1e9
        defer { updateWatchdog() }
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
        for t in frame.touches where t.phase == .began && t.confidence == false { ignoredTouchIDs.insert(t.id) }
        let touches = frame.touches.filter { !ignoredTouchIDs.contains($0.id) }
        for t in frame.touches where t.phase.isTerminal { ignoredTouchIDs.remove(t.id) }
        let time = Double(frame.timestamp) / 1e9
        guard let displayID else { return }
        let mapping = ScreenMapping(displayID: displayID)
        let mapped = touches.map {
            GestureTouch(id: $0.id, position: mapping.globalPoint(x: $0.x, y: $0.y), isDown: !$0.phase.isTerminal)
        }
        send(recognizer.process(mapped, at: time))
        updateTimer()
    }

    /// 取消進行中的手勢並放開所有按住的鍵（裝置移除、睡眠等）。之後的觸控照常處理。
    public func cancel(reason: String? = nil) {
        let events = recognizer.reset()
        if let reason, !events.isEmpty || !activeTouchIDs.isEmpty { logHandler?("手勢：\(reason)，取消進行中的手勢並放開按鍵") }
        send(events)
        output.releaseAll()
        activeTouchIDs.removeAll()
        ignoredTouchIDs.removeAll()
        suspendedSequence = false
        updateTimer()
        updateWatchdog()
    }

    /// 結束程式前呼叫（在 queue 上）：放開所有按住的鍵、結束連續手勢，之後不再處理任何觸控
    public func shutdown() {
        guard !stopped else { return }
        cancel()
        stopped = true
        timer?.cancel()
        timer = nil
        watchdog?.cancel()
        watchdog = nil
    }

    /// watchdog：有手指在螢幕上卻超過 `watchdogTimeout` 沒有觸控報告時取消（測試用 internal）
    func checkWatchdog(now: Double) {
        guard !activeTouchIDs.isEmpty, now - lastFrameTime > configuration.watchdogTimeout else { return }
        cancel(reason: String(format: "%.1f 秒沒有收到觸控報告（裝置斷線或卡住）", now - lastFrameTime))
    }

    private func updateWatchdog() {
        if !activeTouchIDs.isEmpty && !stopped {
            guard watchdog == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.checkWatchdog(now: Double(MultiTouchClock.now()) / 1e9) }
            watchdog = t
            t.resume()
        } else if let watchdog {
            watchdog.cancel()
            self.watchdog = nil
        }
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
