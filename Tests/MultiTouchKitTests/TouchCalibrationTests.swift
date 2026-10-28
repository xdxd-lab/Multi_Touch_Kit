import Foundation
import Testing
@testable import MultiTouchKit

@Suite struct TouchCalibrationTests {
    /// 9 個校正十字（10%／50%／90%）
    static let targets: [TouchCalibration.Point] = [0.1, 0.5, 0.9].flatMap { y in [0.1, 0.5, 0.9].map { TouchCalibration.Point(x: $0, y: y) } }

    /// 模擬面板的對位誤差：控制器回報的位置 = distort(使用者按的位置)。含縮放、平移與右上角的局部偏差
    static func distort(_ p: TouchCalibration.Point) -> TouchCalibration.Point {
        TouchCalibration.Point(x: 0.01 + 0.97 * p.x + 0.02 * p.x * (1 - p.y),
                               y: 0.015 + 0.98 * p.y - 0.015 * p.x * (1 - p.y))
    }

    static func samples(noise: Double = 0, seed: UInt64 = 1) -> [TouchCalibration.Sample] {
        var rng = SplitMix64(seed: seed)
        return targets.map { t in
            var m = distort(t)
            m.x += (Double(rng.next() % 2001) / 1000 - 1) * noise
            m.y += (Double(rng.next() % 2001) / 1000 - 1) * noise
            return TouchCalibration.Sample(target: t, measured: m, count: 5)
        }
    }

    @Test func identityChangesNothing() {
        let p = TouchCalibration.identity.apply(x: 0.3, y: 0.7)
        #expect(abs(p.x - 0.3) < 1e-12 && abs(p.y - 0.7) < 1e-12)
    }

    @Test func recoversDistortionAcrossThePanel() throws {
        let fit = try #require(TouchCalibration.fit(Self.samples()))
        #expect(fit.calibration.model == .quadratic)
        #expect(fit.problem == nil)
        #expect(fit.excluded.isEmpty)
        #expect(fit.residuals.allSatisfy { $0 < 0.002 })
        // 校正點以外的位置也要對（二次模型近似畸變的反函數）：誤差從 ~1.5% 降到 0.2% 以下
        var worstBefore = 0.0, worstAfter = 0.0
        for i in 1...9 {
            for j in 1...9 {
                let t = TouchCalibration.Point(x: Double(i) / 10, y: Double(j) / 10)
                let m = Self.distort(t)
                let p = fit.calibration.apply(x: m.x, y: m.y)
                worstBefore = max(worstBefore, hypot(m.x - t.x, m.y - t.y))
                worstAfter = max(worstAfter, hypot(p.x - t.x, p.y - t.y))
            }
        }
        #expect(worstBefore > 0.01)
        #expect(worstAfter < 0.002, "最大誤差 \(worstAfter)")
    }

    @Test func toleratesNoise() throws {
        let fit = try #require(TouchCalibration.fit(Self.samples(noise: 0.002, seed: 7)))
        let mean = fit.residuals.reduce(0, +) / Double(fit.residuals.count)
        #expect(mean < 0.003)
        #expect(fit.problem == nil)
        #expect(fit.excluded.isEmpty)  // 一般雜訊不可被當成離群點
    }

    @Test func excludesOneOutlier() throws {
        var samples = Self.samples(noise: 0.0005, seed: 3)
        samples[2].measured.x += 0.05  // 右上角點錯
        let fit = try #require(TouchCalibration.fit(samples))
        #expect(fit.excluded == [2])
        let others = fit.residuals.indices.filter { $0 != 2 }.map { fit.residuals[$0] }
        #expect(others.allSatisfy { $0 < 0.003 })
    }

    @Test func modelDependsOnPointCount() {
        let all = Self.samples()
        #expect(TouchCalibration.fit(Array(all.prefix(2))) == nil)
        #expect(TouchCalibration.fit([all[0], all[2], all[6]])?.calibration.model == .affine)
        // 6 點但只分布在兩列：二次項無法決定，退回仿射
        #expect(TouchCalibration.fit(Array(all.prefix(6)))?.calibration.model == .affine)
        // 6 點涵蓋三列三行：二次
        #expect(TouchCalibration.fit([0, 1, 2, 4, 6, 8].map { all[$0] })?.calibration.model == .quadratic)
    }

    @Test func rejectsCollinearPoints() {
        let line = [0.1, 0.5, 0.9].map { TouchCalibration.Sample(target: .init(x: $0, y: 0.5), measured: .init(x: $0, y: 0.5)) }
        #expect(TouchCalibration.fit(line) == nil)
    }

    @Test func flagsUnreasonableCalibrations() throws {
        // 點錯成鏡像（左右顛倒）：映射會翻轉
        let mirrored = Self.targets.map { TouchCalibration.Sample(target: $0, measured: .init(x: 1 - $0.x, y: $0.y)) }
        #expect(try #require(TouchCalibration.fit(mirrored)).problem != nil)
        // 整體位移 10%：超過校正量上限
        let shifted = Self.targets.map { TouchCalibration.Sample(target: $0, measured: .init(x: $0.x - 0.1, y: $0.y)) }
        #expect(try #require(TouchCalibration.fit(shifted)).problem != nil)
    }

    @Test func applyClampsToUnitRange() {
        let shift = TouchCalibration(model: .affine, x: [0.55, 1, 0], y: [0.5, 0, 1])
        #expect(shift.apply(x: 1, y: 0.5).x == 1)
    }

    @Test func trackerKeepsUncalibratedCoordinates() {
        var tracker = ContactTracker()
        let contact = RawContact(contactID: 0, tip: true, x: 0.41, y: 0.52, rawX: 1, rawY: 2,
                                 uncalibratedX: 0.4, uncalibratedY: 0.5)
        let touch = tracker.update([contact]) { 1 }[0]
        #expect(touch.x == 0.41 && touch.uncalibratedX == 0.4 && touch.uncalibratedY == 0.5)
    }

    @Test func jsonIncludesUncalibratedCoordinatesAndCalibratedFlag() {
        let touch = Touch(id: 1, contactID: 0, phase: .moved, x: 0.41, y: 0.52, rawX: 1, rawY: 2, uncalibratedX: 0.4, uncalibratedY: 0.5)
        let json = TouchJSON.frame(TouchFrame(deviceID: 1, sequence: 1, timestamp: 1, scanTime: nil, touches: [touch]))
        #expect(json.contains(#""x":0.41000,"y":0.52000,"rx":1,"ry":2,"ux":0.40000,"uy":0.50000}"#))
        var info = SimulatedTouchSource.deviceInfo
        info.isCalibrated = true
        #expect(TouchJSON.deviceObject(info).hasSuffix(#""exclusive":false,"calibrated":true}"#))
    }
}

@Suite struct TouchCalibrationStoreTests {
    func store() -> TouchCalibrationStore {
        TouchCalibrationStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("mtk-calibration-test-\(UUID().uuidString)/calibration.json"))
    }

    func device(serial: String = "", location: Int = 0x100000, vendor: Int = 0x222A) -> MultiTouchDeviceInfo {
        MultiTouchDeviceInfo(id: 1, vendorID: vendor, productID: 1, manufacturer: "ILITEK", product: "ILITEK-TP", serialNumber: serial,
                             locationID: location, maxContacts: 10, slotsPerReport: 10, physicalWidthMillimeters: 309.3,
                             physicalHeightMillimeters: 173.9, hasScanTime: true, exclusive: true)
    }

    func entry(_ device: MultiTouchDeviceInfo, shift: Double) -> TouchCalibrationStore.Entry {
        .init(device: .init(device), displayEDID: "6474:aa15:0", displayName: "Sculptor (1)",
              calibration: TouchCalibration(model: .affine, x: [0.5 + shift, 1, 0], y: [0.5, 0, 1]),
              samples: TouchCalibrationTests.samples(), errorBefore: 4.2, errorAfter: 0.8)
    }

    @Test func missingFileHasNoEntries() {
        #expect(store().entries().isEmpty)
        #expect(store().entry(for: device()) == nil)
    }

    @Test func roundTripAndReplace() throws {
        let s = store()
        try s.save(entry(device(), shift: 0.01))
        try s.save(entry(device(), shift: 0.02))  // 同一裝置：取代
        #expect(s.entries().count == 1)
        let loaded = try #require(s.entry(for: device()))
        #expect(loaded.calibration.x[0] == 0.52)
        #expect(loaded.samples.count == 9 && loaded.displayEDID == "6474:aa15:0")
    }

    @Test func matchingRules() throws {
        let s = store()
        try s.save(entry(device(location: 0x100000), shift: 0.01))
        try s.save(entry(device(location: 0x200000), shift: 0.02))
        // 換插孔（LocationID 不同）仍套用；同 VID／PID 多筆時優先相同 LocationID
        #expect(s.entry(for: device(location: 0x300000)) != nil)
        #expect(s.entry(for: device(location: 0x200000))?.calibration.x[0] == 0.52)
        #expect(s.entry(for: device(vendor: 0x1234)) == nil)
        // 兩邊都有序號且不同：不套用
        let withSerial = store()
        try withSerial.save(entry(device(serial: "A"), shift: 0.01))
        #expect(withSerial.entry(for: device(serial: "B")) == nil)
        #expect(withSerial.entry(for: device(serial: "A")) != nil)
    }

    @Test func removeForDevice() throws {
        let s = store()
        try s.save(entry(device(), shift: 0.01))
        #expect(try s.remove(for: device()) == 1)
        #expect(s.entries().isEmpty)
        #expect(try s.remove(for: device()) == 0)
    }
}

@Suite struct TouchCalibrationRobustnessTests {
    @Test func malformedCoefficientsLeaveCoordinatesUnchanged() {
        let broken = TouchCalibration(model: .quadratic, x: [0.5, 1], y: [0.5, 0, 1, 0, 0, 0])
        let p = broken.apply(x: 0.3, y: 0.4)
        #expect(abs(p.x - 0.3) < 1e-12 && abs(p.y - 0.4) < 1e-12)
    }
}
