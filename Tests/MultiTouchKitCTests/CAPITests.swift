import CMultiTouchKit
import Foundation
import MultiTouchKit
import Testing
@testable import MultiTouchKitC

/// C API 的測試。CRuntime 是整個程序共用的單例，所以序列化執行；不呼叫 mtk_start（不碰硬體）。
@Suite(.serialized) struct CAPITests {
    init() { CRuntime.shared.resetForTesting() }

    func frame(_ phase: TouchPhase, id: UInt64 = 1, seq: UInt64 = 1) -> TouchFrame {
        TouchFrame(deviceID: 1, sequence: seq, timestamp: seq * 8_000_000, scanTime: nil,
                   touches: [Touch(id: id, contactID: 0, phase: phase, x: 0.25, y: 0.75, rawX: 1, rawY: 2)])
    }

    func poll(_ capacity: Int = 64) -> [MTKTouchEvent] {
        var buffer = [MTKTouchEvent](repeating: MTKTouchEvent(), count: capacity)
        let n = buffer.withUnsafeMutableBufferPointer { mtkPollEvents($0.baseAddress, Int32(capacity)) }
        return Array(buffer.prefix(Int(n)))
    }

    func logs() -> [String] {
        var out: [String] = []
        var buffer = [CChar](repeating: 0, count: 1024)
        while mtkPollLog(&buffer, Int32(buffer.count)) > 0 { out.append(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        return out
    }

    @Test func structSizesMatchHeader() {
        #expect(MemoryLayout<MTKConfig>.size == 32)
        #expect(MemoryLayout<MTKTouchEvent>.size == 56)
        #expect(MemoryLayout<MTKDeviceInfo>.size == 160)
        #expect(mtkAPIVersion() == MTK_API_VERSION)
        #expect(String(cString: mtkVersion()) == MultiTouchKitVersion.string)
    }

    @Test func defaultConfig() {
        var config = MTKConfig()
        mtkDefaultConfig(&config)
        #expect(config.struct_size == 32)
        #expect(config.exclusive == 1 && config.init_multitouch == 1)
        #expect(config.report_stationary == 0 && config.queue_capacity == 0 && config.stale_timeout_ms == 0)
    }

    @Test func startRejectsSmallStruct() {
        var config = MTKConfig()
        mtkDefaultConfig(&config)
        config.struct_size = 16
        #expect(mtkStart(&config) == MTK_ERR_INVALID_ARGUMENT)
        #expect(mtkIsRunning() == 0)
    }

    @Test func pollConvertsAndSkipsStationary() {
        CRuntime.shared.enqueue(frame(.began))
        CRuntime.shared.enqueue(frame(.stationary, seq: 2))
        CRuntime.shared.enqueue(frame(.ended, seq: 3))
        let events = poll()
        #expect(events.map(\.phase) == [MTK_PHASE_BEGAN, MTK_PHASE_ENDED])
        #expect(events[0].x == 0.25 && events[0].y == 0.75 && events[0].pressure == -1)
        #expect(events[0].timestamp_ns == 8_000_000 && events[0].frame_seq == 1)
        #expect(mtkPollEvents(nil, 10) == 0)
    }

    @Test func overflowResyncsAndLogs() {
        CRuntime.shared.resetForTesting(capacity: 4)
        CRuntime.shared.enqueue(frame(.began, id: 1))
        #expect(poll().count == 1)
        CRuntime.shared.enqueue(frame(.ended, id: 1, seq: 2))
        for s in 0..<6 { CRuntime.shared.enqueue(frame(.moved, id: 2, seq: UInt64(10 + s))) }
        let events = poll()
        // 1 已離開 → cancelled；2 使用者還不知道 → began
        #expect(events.map(\.touch_id) == [1, 2])
        #expect(events.map(\.phase) == [MTK_PHASE_CANCELLED, MTK_PHASE_BEGAN])
        #expect(mtkDroppedEventCount() > 0)
        #expect(logs().contains { $0.contains("重新同步") })
    }

    @Test func pollLogDoesNotSplitMultibyteCharacters() {
        CRuntime.shared.appendLog("觸控")
        var buffer = [CChar](repeating: 0x7F, count: 5)
        // 「觸」3 位元組＋結尾 0 = 4；「控」放不下，整個字元略過
        #expect(mtkPollLog(&buffer, 5) == 3)
        #expect(buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } == "觸")
    }

    // MARK: - 回呼

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var started = false
        var finished = false
        func update(_ body: (Box) -> Void) { lock.withLock { body(self) } }
        func read<T>(_ body: (Box) -> T) -> T { lock.withLock { body(self) } }
    }

    @Test func callbackReceivesEvents() {
        let box = Box()
        let context = Unmanaged.passUnretained(box).toOpaque()
        mtkSetEventCallback({ events, count, user in
            let box = Unmanaged<Box>.fromOpaque(user!).takeUnretainedValue()
            #expect(count == 1 && events?.pointee.touch_id == 7)
            box.update { $0.calls += 1 }
        }, context)
        CRuntime.shared.enqueue(frame(.began, id: 7))
        mtkSetEventCallback(nil, nil)
        CRuntime.shared.enqueue(frame(.ended, id: 7, seq: 2))
        #expect(box.read { $0.calls } == 1)
        #expect(poll().count == 2) // 回呼不影響佇列
    }

    @Test(.timeLimit(.minutes(1))) func setterInsideCallbackDoesNotDeadlock() {
        let box = Box()
        mtkSetEventCallback({ _, _, user in
            let box = Unmanaged<Box>.fromOpaque(user!).takeUnretainedValue()
            box.update { $0.calls += 1 }
            mtkSetEventCallback(nil, nil) // 重入：同一執行緒，立即生效
        }, Unmanaged.passUnretained(box).toOpaque())
        CRuntime.shared.enqueue(frame(.began))
        CRuntime.shared.enqueue(frame(.moved, seq: 2))
        #expect(box.read { $0.calls } == 1)
    }

    @Test(.timeLimit(.minutes(1))) func setterWaitsForInFlightCallback() {
        let box = Box()
        mtkSetEventCallback({ _, _, user in
            let box = Unmanaged<Box>.fromOpaque(user!).takeUnretainedValue()
            box.update { $0.started = true }
            Thread.sleep(forTimeInterval: 0.2)
            box.update { $0.finished = true }
        }, Unmanaged.passUnretained(box).toOpaque())
        let frame = frame(.began)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            CRuntime.shared.enqueue(frame)
            done.signal()
        }
        while !box.read({ $0.started }) { Thread.sleep(forTimeInterval: 0.001) }
        mtkSetEventCallback(nil, nil)
        // 返回時舊回呼一定已經結束，可以安全釋放 user_data
        #expect(box.read { $0.finished })
        done.wait()
    }
}

@Suite(.serialized) struct CalibrationCAPITests {
    @Test func calibrationFunctions() {
        mtkSetCalibrationEnabled(0)
        mtkSetCalibrationEnabled(1)
        #expect(mtkIsCalibrated(0) == MTK_ERR_OUT_OF_RANGE)  // 沒有啟動、沒有裝置
        #expect(mtkIsCalibrated(-1) == MTK_ERR_OUT_OF_RANGE)
    }
}
