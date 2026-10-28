import Foundation
import Testing
@testable import MultiTouchKit

@Suite struct TouchCalibrationCollectorTests {
    var nextID: UInt64 = 0
    var time: UInt64 = 1_000_000_000

    /// 模擬一次點擊：落下、按住 100 ms（125 Hz）、放開。頭幾個 frame 的位置偏移（手指剛接觸時不穩）
    mutating func tap(_ collector: inout TouchCalibrationCollector, x: Double, y: Double, wobble: Double = 0.02) -> [TouchCalibrationCollector.Tap] {
        nextID += 1
        var result: [TouchCalibrationCollector.Tap] = []
        for i in 0...13 {
            let phase: TouchPhase = i == 0 ? .began : (i == 13 ? .ended : .moved)
            let offset = i < 3 ? wobble : 0  // 前 24 ms 偏移
            let touch = Touch(id: nextID, contactID: 0, phase: phase, x: 0.5, y: 0.5, rawX: 0, rawY: 0,
                              uncalibratedX: x + offset, uncalibratedY: y)
            result += collector.process(TouchFrame(deviceID: 1, sequence: 0, timestamp: time, scanTime: nil, touches: [touch]))
            time += 8_000_000
        }
        return result
    }

    @Test mutating func assignsTapsToNearestTargetUsingUncalibratedPosition() {
        var c = TouchCalibrationCollector(panelWidthMillimeters: 309.3, panelHeightMillimeters: 173.9)
        let taps = tap(&c, x: 0.905, y: 0.11)
        #expect(taps.count == 1 && taps[0].target == 2)
        // 頭 40 ms 的偏移被略過：位置是穩定後的值
        #expect(abs(taps[0].position.x - 0.905) < 1e-9)
        #expect(c.taps[2].count == 1)
    }

    @Test mutating func ignoresTapsFarFromAllTargets() {
        var c = TouchCalibrationCollector()
        let taps = tap(&c, x: 0.3, y: 0.3)
        #expect(taps.first?.target == nil)
        #expect(c.ignored == 1 && c.samples.isEmpty)
    }

    @Test mutating func cancelledTouchesAreNotTaps() {
        var c = TouchCalibrationCollector()
        nextID += 1
        let began = Touch(id: nextID, contactID: 0, phase: .began, x: 0.1, y: 0.1, rawX: 0, rawY: 0)
        var cancelled = began
        cancelled.phase = .cancelled
        c.process(TouchFrame(deviceID: 1, sequence: 0, timestamp: 1, scanTime: nil, touches: [began]))
        #expect(c.process(TouchFrame(deviceID: 1, sequence: 1, timestamp: 2, scanTime: nil, touches: [cancelled])).isEmpty)
        #expect(c.samples.isEmpty)
    }

    @Test mutating func medianPerTargetAndLiveFit() throws {
        var c = TouchCalibrationCollector(panelWidthMillimeters: 309.3, panelHeightMillimeters: 173.9)
        // 每個十字點 3 次（其中一次誤差較大），模擬面板偏差 distort
        for target in TouchCalibrationCollector.standardTargets {
            let d = TouchCalibrationTests.distort(target)
            _ = tap(&c, x: d.x, y: d.y)
            _ = tap(&c, x: d.x + 0.004, y: d.y)
            _ = tap(&c, x: d.x + 0.03, y: d.y)  // 單次誤觸：中位數不受影響
        }
        #expect(c.samples.count == 9 && c.samples.allSatisfy { $0.count == 3 })
        let fit = try #require(c.fit)
        #expect(fit.problem == nil)
        let errors = c.meanErrors(fit)
        #expect(errors.before > 2)           // 校正前約 4 mm
        #expect(try #require(errors.after) < 1)  // 校正後 1 mm 以下
        #expect(try #require(c.residualMillimeters(target: 4, fit: fit)) < 1.5)
        c.reset()
        #expect(c.samples.isEmpty && c.ignored == 0)
    }
}
