import CoreGraphics
import Foundation
import MultiTouchKit
import Testing
@testable import MultiTouchKitGestures

/// 2026-10-28 事故：mtk-server --gestures 在拖曳中被結束，mouseUp 沒送出，系統一直認為左鍵按住。
@Suite struct OutputStateTests {
    @Test func releasesPressedButtonAtLastPoint() {
        var s = GestureOutputState()
        s.record(.mouseDown(.left, CGPoint(x: 10, y: 10), clickCount: 1))
        s.record(.mouseDragged(.left, CGPoint(x: 50, y: 60)))
        #expect(s.releaseEvents(fallback: .zero) == [.mouseUp(.left, CGPoint(x: 50, y: 60), clickCount: 1)])
        s.record(.mouseUp(.left, CGPoint(x: 50, y: 60), clickCount: 1))
        #expect(s.releaseEvents(fallback: .zero).isEmpty)
        #expect(s.isEmpty)
    }

    @Test func endsContinuousGestures() {
        var s = GestureOutputState()
        s.record(.scroll(dx: 0, dy: 5, phase: .began))
        s.record(.magnify(0.1, phase: .began))
        s.record(.rotate(degrees: 3, phase: .changed))
        s.record(.swipe(.horizontal, progress: 0.2, velocity: 0, fingers: 3, phase: .began))
        s.record(.mouseDown(.right, CGPoint(x: 1, y: 2), clickCount: 1))
        #expect(s.releaseEvents(fallback: .zero) == [
            .scroll(dx: 0, dy: 0, phase: .cancelled), .magnify(0, phase: .cancelled), .rotate(degrees: 0, phase: .cancelled),
            .swipe(.horizontal, progress: 0, velocity: 0, fingers: 0, phase: .cancelled),
            .mouseUp(.right, CGPoint(x: 1, y: 2), clickCount: 1),
        ])
        s.record(.scroll(dx: 0, dy: 0, phase: .ended))
        s.record(.momentum(dx: 0, dy: 0, phase: .began))
        #expect(s.releaseEvents(fallback: .zero).first == .momentum(dx: 0, dy: 0, phase: .ended))
    }

    @Test func fallsBackToCursorWithoutKnownPoint() {
        var s = GestureOutputState()
        s.pressed = [.left]
        #expect(s.releaseEvents(fallback: CGPoint(x: 7, y: 8)) == [.mouseUp(.left, CGPoint(x: 7, y: 8), clickCount: 1)])
    }
}

/// 模擬送出端：記錄事件，releaseAll 依自己的狀態補送（與 CGEventGestureOutput 相同邏輯）
final class RecordingOutput: GestureOutput, @unchecked Sendable {
    var events: [GestureEvent] = []
    var state = GestureOutputState()
    var releaseCalls = 0

    func send(_ e: [GestureEvent]) {
        for x in e { state.record(x) }
        events += e
    }

    func releaseAll() {
        releaseCalls += 1
        send(state.releaseEvents(fallback: .zero))
    }

    var buttonHeld: Bool { !state.pressed.isEmpty }
}

@Suite(.serialized) struct ControllerSafetyTests {
    let queue = DispatchQueue(label: "test.gestures")

    func makeController(exclude: Set<String> = []) -> (GestureController, RecordingOutput) {
        let output = RecordingOutput()
        var config = GestureController.Configuration()
        config.excludedBundleIDs = exclude
        let c = GestureController(configuration: config, queue: queue, output: output)
        c.displayID = CGMainDisplayID()
        return (c, output)
    }

    /// 一指拖曳到按住狀態（0.2 秒、往右 100 個正規化 0.001 單位 × 次數）
    func startDrag(_ c: GestureController) {
        var seq: UInt64 = 0
        let t0 = MultiTouchClock.now()
        for i in 0..<30 {
            seq += 1
            let x = 0.3 + Double(i) * 0.005
            let phase: TouchPhase = i == 0 ? .began : .moved
            let touch = Touch(id: 1, contactID: 0, phase: phase, x: x, y: 0.5, rawX: Int(x * 9600), rawY: 4800)
            queue.sync { c.handle(TouchFrame(deviceID: 1, sequence: seq, timestamp: t0 + UInt64(i) * 8_000_000, scanTime: nil, touches: [touch])) }
        }
    }

    @Test func shutdownReleasesHeldButtonAndIgnoresLaterFrames() {
        let (c, out) = makeController()
        startDrag(c)
        #expect(out.buttonHeld)
        queue.sync { c.shutdown() }
        #expect(!out.buttonHeld)
        #expect(out.events.last.map { if case .mouseUp(.left, _, _) = $0 { true } else { false } } == true)
        let count = out.events.count
        let touch = Touch(id: 2, contactID: 0, phase: .began, x: 0.5, y: 0.5, rawX: 0, rawY: 0)
        queue.sync { c.handle(TouchFrame(deviceID: 1, sequence: 99, timestamp: MultiTouchClock.now(), scanTime: nil, touches: [touch])) }
        #expect(out.events.count == count)
    }

    @Test func deviceRemovalCancelReleasesButton() {
        let (c, out) = makeController()
        startDrag(c)
        queue.sync { c.cancel(reason: "裝置移除") }
        #expect(!out.buttonHeld)
    }

    /// 拖曳中觸控螢幕的顯示器消失（mtk-server 把 displayID 設為 nil）：之後手指離開的 mouseUp 無法換算座標，
    /// 不在這時放開的話系統會一直認為左鍵按住
    @Test func losingDisplayReleasesButton() {
        let (c, out) = makeController()
        startDrag(c)
        #expect(out.buttonHeld)
        c.displayID = nil
        let touch = Touch(id: 1, contactID: 0, phase: .ended, x: 0.5, y: 0.5, rawX: 0, rawY: 0)
        queue.sync { c.handle(TouchFrame(deviceID: 1, sequence: 99, timestamp: MultiTouchClock.now(), scanTime: nil, touches: [touch])) }
        #expect(!out.buttonHeld)
    }

    @Test func watchdogReleasesWhenReportsStop() {
        let (c, out) = makeController()
        startDrag(c)
        let now = Double(MultiTouchClock.now()) / 1e9
        queue.sync { c.checkWatchdog(now: now + 1) }
        #expect(out.buttonHeld)                      // 1 秒還在容許範圍
        queue.sync { c.checkWatchdog(now: now + 2.5) }
        #expect(!out.buttonHeld)
    }

    @Test func watchdogIgnoresIdle() {
        let (c, out) = makeController()
        queue.sync { c.checkWatchdog(now: Double(MultiTouchClock.now()) / 1e9 + 100) }
        #expect(out.events.isEmpty)
        #expect(out.releaseCalls == 0)
    }

    @Test func switchingToExcludedAppReleasesButton() {
        let (c, out) = makeController(exclude: ["com.example.game"])
        startDrag(c)
        queue.sync { c.frontmostChanged(to: "com.example.other") }
        #expect(out.buttonHeld)
        queue.sync { c.frontmostChanged(to: "com.example.game") }
        #expect(!out.buttonHeld)
        // 之後同一組手指的移動被忽略
        let count = out.events.count
        let touch = Touch(id: 1, contactID: 0, phase: .moved, x: 0.6, y: 0.5, rawX: 0, rawY: 0)
        queue.sync { c.handle(TouchFrame(deviceID: 1, sequence: 100, timestamp: MultiTouchClock.now(), scanTime: nil, touches: [touch])) }
        #expect(out.events.count == count)
    }
}
