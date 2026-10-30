import CoreGraphics
import Foundation
import Testing
@testable import MultiTouchKit

@Suite struct DescriptorTests {
    let descriptor = try! HIDReportDescriptor(bytes: Fixtures.bytes(Fixtures.ilitekTouchDescriptor))

    @Test func ilitekLayout() throws {
        let layout = try #require(DigitizerLayout(descriptor: descriptor))
        #expect(layout.reportID == 4)
        #expect(layout.slots.count == 10)
        #expect(layout.reportLength == 63)
        #expect(layout.contactCount != nil)
        #expect(layout.scanTime != nil)
        #expect(layout.maxContactsFeature?.reportID == 6)
        #expect(layout.deviceModeFeature == nil)
        #expect(layout.slots[0].x.logicalMax == 9600)
        #expect(layout.slots[0].y.logicalMax == 9600)
        let width = try #require(layout.slots[0].x.physicalLengthMillimeters)
        #expect(abs(width - 309.3) < 0.01)
        #expect(descriptor.usesReportIDs)
    }

    @Test func mouseInterfaceIsNotATouchScreen() throws {
        let mouse = try HIDReportDescriptor(bytes: Fixtures.bytes(Fixtures.ilitekMouseDescriptor))
        #expect(DigitizerLayout(descriptor: mouse) == nil)
        let pointerIDs = Set(mouse.inputFields.filter { field in
            !field.isConstant && field.collectionPath.contains { $0.usagePage == 0x01 && $0.usage == 0x02 }
        }.map(\.reportID))
        #expect(pointerIDs == [5])
    }

    @Test func parsesRealReports() throws {
        let layout = try #require(DigitizerLayout(descriptor: descriptor))
        let one = Fixtures.bytes(Fixtures.oneFingerReport)
        let parsed = one.withUnsafeBufferPointer { layout.parse(UnsafeBufferPointer(rebasing: $0.dropFirst())) }
        #expect(parsed.contactCount == 1)
        #expect(parsed.scanTime == 0x0004_0470)
        #expect(parsed.slots[0] .contactID == 0)
        #expect(parsed.slots[0].tip)
        #expect(parsed.slots[0].rawX == 0x117E)
        #expect(parsed.slots[0].rawY == 0x0CD7)
        #expect(abs(parsed.slots[0].x - 4478.0 / 9600) < 1e-9)

        let two = Fixtures.bytes(Fixtures.twoFingerReport)
        let parsed2 = two.withUnsafeBufferPointer { layout.parse(UnsafeBufferPointer(rebasing: $0.dropFirst())) }
        #expect(parsed2.contactCount == 2)
        #expect(parsed2.slots[1].contactID == 1)
        #expect(parsed2.slots[1].tip)
        #expect(parsed2.slots[1].rawX == 0x1318)
        #expect(parsed2.slots[1].rawY == 0x1AF5)
    }

    @Test func fieldWriteReadRoundTrip() throws {
        let layout = try #require(DigitizerLayout(descriptor: descriptor))
        var payload = [UInt8](repeating: 0, count: layout.reportLength)
        layout.slots[3].x.write(1234, into: &payload)
        layout.slots[3].contactID?.write(42, into: &payload)
        layout.slots[3].tip?.write(1, into: &payload)
        #expect(layout.slots[3].x.value(in: payload) == 1234)
        #expect(layout.slots[3].contactID?.value(in: payload) == 42)
        #expect(layout.slots[3].tip?.value(in: payload) == 1)
        #expect(layout.slots[2].x.value(in: payload) == 0)
    }

    /// 兩份 Finger 數量相同的觸控報告：一律選 report ID 較小的（不受 Dictionary 走訪順序影響）
    @Test func equalCandidateReportsPickLowestID() throws {
        func touchScreen(reportID: UInt8) -> [UInt8] {
            [0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x85, reportID,
             0x09, 0x22, 0xA1, 0x02,
             0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02, // Tip Switch
             0x75, 0x07, 0x81, 0x03,                                                 // 補位
             0x05, 0x01, 0x09, 0x30, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x81, 0x02,       // X
             0x09, 0x31, 0x81, 0x02,                                                 // Y
             0xC0, 0xC0]
        }
        for bytes in [touchScreen(reportID: 9) + touchScreen(reportID: 2), touchScreen(reportID: 2) + touchScreen(reportID: 9)] {
            let layout = try #require(DigitizerLayout(descriptor: try HIDReportDescriptor(bytes: bytes)))
            #expect(layout.reportID == 2)
            #expect(layout.slots.count == 1)
        }
    }
}

@Suite struct FrameTests {
    func contact(_ id: Int, tip: Bool = true, x: Int = 100, y: Int = 100) -> RawContact {
        RawContact(contactID: id, tip: tip, x: Double(x) / 9600, y: Double(y) / 9600, rawX: x, rawY: y)
    }

    @Test func hybridModeAssemblesAcrossReports() throws {
        var assembler = FrameAssembler()
        let first = ParsedTouchReport(contactCount: 3, scanTime: 1, slots: [contact(0), contact(1)])
        let partial = assembler.add(first, timestamp: 10)
        #expect(partial == nil)
        let second = ParsedTouchReport(contactCount: 0, scanTime: 1, slots: [contact(2), contact(9)])
        let completed = assembler.add(second, timestamp: 20)
        let frame = try #require(completed)
        #expect(frame.contacts.map(\.contactID) == [0, 1, 2])
        #expect(frame.timestamp == 10)
    }

    @Test func singleReportFrameUsesContactCount() throws {
        var assembler = FrameAssembler()
        let report = ParsedTouchReport(contactCount: 1, scanTime: nil, slots: [contact(5), contact(6)])
        let completed = assembler.add(report, timestamp: 1)
        let frame = try #require(completed)
        #expect(frame.contacts.map(\.contactID) == [5])
    }

    @Test func trackerPhases() {
        var tracker = ContactTracker()
        var next: UInt64 = 1
        func update(_ contacts: [RawContact]) -> [Touch] {
            tracker.update(contacts) {
                defer { next += 1 }
                return next
            }
        }
        let began = update([contact(0)])
        #expect(began.map(\.phase) == [.began])
        #expect(began[0].id == 1)
        #expect(update([contact(0)]).map(\.phase) == [.stationary])
        #expect(update([contact(0, x: 200)]).map(\.phase) == [.moved])

        let lifted = update([contact(0, tip: false, x: 0, y: 0), contact(1)])
        #expect(lifted.map(\.phase) == [.ended, .began])
        #expect(lifted[0].rawX == 200) // 放開時保留最後的有效位置
        #expect(lifted[1].id == 2)

        // 沒出現在 frame 的觸點視為放開
        #expect(update([]).map(\.phase) == [.ended])
        #expect(!tracker.hasActiveTouches)

        _ = update([contact(3), contact(4)])
        let cancelled = tracker.cancelAll()
        #expect(cancelled.map(\.phase) == [.cancelled, .cancelled])
        #expect(cancelled.map(\.id) == [3, 4])
    }

    @Test func contactIDReuseStartsNewTouch() {
        var tracker = ContactTracker()
        var next: UInt64 = 1
        let allocate: () -> UInt64 = {
            defer { next += 1 }
            return next
        }
        _ = tracker.update([contact(0)], allocateID: allocate)
        _ = tracker.update([contact(0, tip: false)], allocateID: allocate)
        let again = tracker.update([contact(0)], allocateID: allocate)
        #expect(again.map(\.phase) == [.began])
        #expect(again[0].id == 2)
    }
}

@Suite struct ProtocolTests {
    @Test func frameJSON() {
        let frame = TouchFrame(deviceID: 1, sequence: 7, timestamp: 123_456_789, scanTime: 80, touches: [
            Touch(id: 5, contactID: 0, phase: .began, x: 0.5, y: 0.25, rawX: 4800, rawY: 2400),
        ])
        #expect(TouchJSON.frame(frame) ==
            #"{"type":"frame","v":1,"device":1,"seq":7,"t":123456789,"scan":80,"touches":[{"id":5,"cid":0,"phase":"began","x":0.50000,"y":0.25000,"rx":4800,"ry":2400}]}"#)
    }

    @Test func jsonEscaping() {
        #expect(TouchJSON.escape("a\"b\\c\n") == #"a\"b\\c\n"#)
    }

    @Test func oscMessageEncoding() {
        let data = OSC.message("/a", [.int(1), .float(1), .string("hi")])
        let expected: [UInt8] = [
            0x2F, 0x61, 0, 0, // "/a"
            0x2C, 0x69, 0x66, 0x73, 0, 0, 0, 0, // ",ifs"
            0, 0, 0, 1, // int32 1
            0x3F, 0x80, 0, 0, // float32 1.0
            0x68, 0x69, 0, 0, // "hi"
        ]
        #expect([UInt8](data) == expected)
    }

    @Test func tuioBundleStructure() {
        var encoder = TUIOEncoder(source: "test")
        let touch = Touch(id: 9, contactID: 0, phase: .began, x: 0.5, y: 0.5, rawX: 0, rawY: 0)
        let data = encoder.encode(alive: [touch], updated: [touch], timestamp: 1)
        #expect(data.prefix(8) == Data("#bundle\0".utf8))
        // source、alive、set、fseq 四則訊息
        let text = String(decoding: data, as: UTF8.self)
        for word in ["source", "alive", "set", "fseq"] { #expect(text.contains(word)) }
    }

    @Test func screenMappingRotation() {
        let mapping = ScreenMapping(rotation: .degrees90)
        let p = mapping.orient(x: 0, y: 0)
        #expect(p.x == 1 && p.y == 0)
        let none = ScreenMapping().orient(x: 0.25, y: 0.75)
        #expect(none.x == 0.25 && none.y == 0.75)
    }
}

/// 2026-10-28 實機上的三台顯示器：SONY TV（主螢幕）、MF156LR（Sculptor 1920x1080）、另一台 Sculptor 1920x2160
@Suite struct DisplayTests {
    static func display(_ id: CGDirectDisplayID, _ name: String, vendor: UInt32, model: UInt32, serial: UInt32,
                        main: Bool, px: (Int, Int), hz: Double, mm: (Double, Double)) -> DisplayInfo {
        DisplayInfo(id: id, name: name, vendor: vendor, model: model, serial: serial, uuid: "UUID-\(id)", isMain: main,
                    isBuiltin: false, bounds: .zero, pixelWidth: px.0, pixelHeight: px.1, refreshRate: hz,
                    widthMillimeters: mm.0, heightMillimeters: mm.1, rotation: 0)
    }

    let displays = [
        display(3, "SONY TV", vendor: 0x4DD9, model: 0xF301, serial: 16_843_009, main: true, px: (1920, 1080), hz: 60, mm: (1625, 914)),
        display(1, "Sculptor (2)", vendor: 0x6474, model: 0xA2D5, serial: 4, main: false, px: (1920, 2160), hz: 100, mm: (290, 527)),
        display(2, "Sculptor (1)", vendor: 0x6474, model: 0xAA15, serial: 0, main: false, px: (1920, 1080), hz: 60, mm: (350, 200)),
    ]

    var panel: MultiTouchDeviceInfo {
        MultiTouchDeviceInfo(id: 1, vendorID: 0x222A, productID: 1, manufacturer: "ILITEK", product: "ILITEK-TP",
                             serialNumber: "", locationID: 0x0010_0000, maxContacts: 10, slotsPerReport: 10,
                             physicalWidthMillimeters: 309.3, physicalHeightMillimeters: 173.9, hasScanTime: true, exclusive: true)
    }

    func resolve(_ text: String, panel: MultiTouchDeviceInfo? = nil) -> CGDirectDisplayID? {
        DisplayLocator.resolve(DisplaySelector(text)!, panel: panel, displays: displays)?.display.id
    }

    @Test func automaticPicksPanelSizedDisplay() {
        #expect(resolve("auto", panel: panel) == 2)
        #expect(resolve("", panel: panel) == 2)
        // 沒有面板尺寸時退回主螢幕
        #expect(resolve("auto") == 3)
    }

    @Test func simulatedSourceMatchesSameDisplay() {
        // mtk-server／mtk-viewer --simulate 用模擬來源的面板尺寸，應與實機選到同一台
        #expect(resolve("auto", panel: SimulatedTouchSource.deviceInfo) == 2)
    }

    @Test func automaticFallbackExplainsReason() throws {
        let none = try #require(DisplayLocator.resolve(.automatic, panel: nil, displays: displays))
        #expect(none.display.id == 3)
        #expect(none.note.contains("還沒有觸控裝置"))

        var unknown = panel
        unknown.physicalWidthMillimeters = nil
        let noSize = try #require(DisplayLocator.resolve(.automatic, panel: unknown, displays: displays))
        #expect(noSize.display.id == 3)
        #expect(noSize.note.contains("沒有回報面板實體尺寸"))

        var tiny = panel
        tiny.physicalWidthMillimeters = 100
        tiny.physicalHeightMillimeters = 60
        let mismatch = try #require(DisplayLocator.resolve(.automatic, panel: tiny, displays: displays))
        #expect(mismatch.display.id == 3)
        #expect(mismatch.note.contains("30% 內"))
    }

    @Test func explicitSelectorsDistinguishSameName() {
        #expect(resolve("edid:6474:aa15") == 2)
        #expect(resolve("edid:0x6474:0xA2D5") == 1)
        #expect(resolve("edid:6474:a2d5:4") == 1)
        #expect(resolve("edid:6474:a2d5:5") == nil)
        #expect(resolve("name:sculptor,size:1920x1080") == 2)
        #expect(resolve("name:Sculptor,hz:100") == 1)
        #expect(resolve("main") == 3)
        #expect(resolve("id:1") == 1)
        #expect(resolve("2") == 2)
        #expect(resolve("uuid:uuid-2") == 2)
        // 多台符合時取第一台非主螢幕
        #expect(resolve("size:1920x1080") == 2)
    }

    @Test func rejectsMalformedSelectors() {
        for text in ["edid:6474", "edid:zz:1", "size:1920", "id:abc", "foo", "name:", "hz:x"] {
            #expect(DisplaySelector(text) == nil, "\(text)")
        }
    }

    @Test func helloIncludesDisplay() {
        let json = TouchJSON.hello(server: "mtk-server", devices: [], display: displays[2])
        #expect(json.contains("\"display\":{\"id\":2,\"name\":\"Sculptor (1)\",\"edid\":\"6474:aa15:0\""))
        #expect(json.contains("\"pixels\":[1920,1080],\"hz\":60}"))
    }

    @Test func displayMessageMatchesHelloDisplay() throws {
        let message = TouchJSON.display(displays[2])
        #expect(message == "{\"type\":\"display\",\"v\":1,\"display\":" + TouchJSON.displayObject(displays[2]) + "}")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "display")
        #expect(TouchJSON.display(nil) == "{\"type\":\"display\",\"v\":1,\"display\":null}")
    }
}

@Suite struct DescriptorLimitTests {
    @Test func hugeReportCountIsRejected() {
        // Usage Page (Generic Desktop), Usage (X), Report Size 8, Report Count 0xFFFFFFFF, Input
        let bytes: [UInt8] = [0x05, 0x01, 0x09, 0x30, 0x75, 0x08, 0x97, 0xFF, 0xFF, 0xFF, 0xFF, 0x81, 0x02]
        #expect(throws: HIDDescriptorError.self) { try HIDReportDescriptor(bytes: bytes) }
    }

    @Test func hugeReportSizeIsRejected() {
        let bytes: [UInt8] = [0x05, 0x01, 0x09, 0x30, 0x77, 0x00, 0x00, 0x01, 0x00, 0x95, 0x01, 0x81, 0x02]
        #expect(throws: HIDDescriptorError.self) { try HIDReportDescriptor(bytes: bytes) }
    }

    @Test func randomBytesNeverCrash() {
        var rng = SplitMix64(seed: 0x4D544B)
        for _ in 0..<2000 {
            let bytes = (0..<Int(rng.next() % 200)).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            _ = try? HIDReportDescriptor(bytes: bytes)
        }
    }

    @Test func realDescriptorStillParses() throws {
        #expect(try HIDReportDescriptor(bytes: Fixtures.bytes(Fixtures.ilitekTouchDescriptor)).fields.count > 0)
    }
}

/// 可重現的亂數（測試用）
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct ManagerLifetimeTests {
    /// 不存在的 VID：不會開啟任何裝置
    func makeManager() throws -> MultiTouchManager {
        var configuration = MultiTouchManager.Configuration()
        configuration.vendorID = 0xFFFF
        configuration.productID = 0xFFFF
        let manager = MultiTouchManager(configuration: configuration)
        try manager.start()
        return manager
    }

    @Test(.timeLimit(.minutes(1))) func releasedWithoutStopOffQueue() throws {
        weak var weakManager: MultiTouchManager?
        do {
            let manager = try makeManager()
            weakManager = manager
            #expect(manager.isRunning)
        }
        #expect(weakManager == nil)
    }

    @Test(.timeLimit(.minutes(1))) func releasedWithoutStopOnItsOwnQueue() throws {
        var manager: MultiTouchManager? = try makeManager()
        let queue = manager!.queue
        weak let weakManager = manager
        // 最後一個參照在 queue 上釋放：deinit 不可 queue.sync 自己（死結）
        queue.sync { manager = nil }
        #expect(weakManager == nil)
    }
}
