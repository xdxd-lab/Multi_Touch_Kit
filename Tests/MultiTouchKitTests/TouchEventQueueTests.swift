import Foundation
import Testing
@testable import MultiTouchKit

struct TestEvent: QueuedTouchEvent, Equatable {
    var id: UInt64
    var phase: TouchPhase
    var x: Double = 0
    var queuedTouchID: UInt64 { id }
    var queuedPhase: TouchPhase { phase }
    func withQueuedPhase(_ phase: TouchPhase) -> TestEvent { TestEvent(id: id, phase: phase, x: x) }
}

/// 2026-10-28：Unity 失去焦點時停止輪詢，佇列溢位丟掉 ended，觸點永遠留在畫面上
@Suite struct TouchEventQueueTests {
    /// 模擬 Unity 的 ActiveTouches：依取出的事件維護「仍在螢幕上」的集合
    struct Consumer {
        var active: [UInt64: Double] = [:]
        mutating func apply(_ events: [TestEvent]) {
            for e in events {
                if e.phase.isTerminal { active[e.id] = nil } else { active[e.id] = e.x }
            }
        }
    }

    @Test func normalOrder() {
        var q = TouchEventQueue<TestEvent>(capacity: 8)
        q.push(TestEvent(id: 1, phase: .began))
        q.push(TestEvent(id: 1, phase: .ended))
        #expect(q.pop(limit: 10).map(\.phase) == [.began, .ended])
        #expect(q.isEmpty)
        #expect(q.dropped == 0)
    }

    @Test func overflowNeverLeavesStuckTouches() {
        var q = TouchEventQueue<TestEvent>(capacity: 16)
        var consumer = Consumer()
        // 使用者看到 1、2 按下
        q.push(TestEvent(id: 1, phase: .began, x: 0.1))
        q.push(TestEvent(id: 2, phase: .began, x: 0.2))
        consumer.apply(q.pop(limit: 100))
        // 停止輪詢期間：線材造成大量閃爍觸點，1 離開、2 移動、3 按著
        for i in 0..<200 {
            let id = UInt64(100 + i)
            q.push(TestEvent(id: id, phase: .began, x: 0.5))
            q.push(TestEvent(id: id, phase: .ended, x: 0.5))
        }
        q.push(TestEvent(id: 1, phase: .ended, x: 0.1))
        q.push(TestEvent(id: 2, phase: .moved, x: 0.25))
        q.push(TestEvent(id: 3, phase: .began, x: 0.3))
        for _ in 0..<20 { q.push(TestEvent(id: 3, phase: .moved, x: 0.31)) }
        #expect(q.dropped > 0)
        // 恢復輪詢：先重新同步，再接續事件
        consumer.apply(q.pop(limit: 4))      // 小緩衝區也不會漏
        while !q.isEmpty { consumer.apply(q.pop(limit: 4)) }
        #expect(consumer.active.keys.sorted() == [2, 3])
        #expect(consumer.active[2] == 0.25)
        #expect(consumer.active[3] == 0.31)
        #expect(q.resyncs == 1)
        // 之後正常
        q.push(TestEvent(id: 2, phase: .ended))
        q.push(TestEvent(id: 3, phase: .ended))
        consumer.apply(q.pop(limit: 10))
        #expect(consumer.active.isEmpty)
    }

    @Test func resyncEventsAreCancelledBeganMoved() {
        var q = TouchEventQueue<TestEvent>(capacity: 4)
        q.push(TestEvent(id: 1, phase: .began))
        q.push(TestEvent(id: 2, phase: .began))
        _ = q.pop(limit: 10)
        q.push(TestEvent(id: 1, phase: .ended))
        q.push(TestEvent(id: 3, phase: .began))
        for _ in 0..<5 { q.push(TestEvent(id: 2, phase: .moved)) }   // 溢位
        let out = q.pop(limit: 10)
        #expect(Array(out.prefix(3)) == [TestEvent(id: 1, phase: .cancelled), TestEvent(id: 2, phase: .moved),
                                         TestEvent(id: 3, phase: .began)])
    }

    @Test func requestedResyncReconcilesWithoutOverflow() {
        var q = TouchEventQueue<TestEvent>(capacity: 64)
        q.push(TestEvent(id: 1, phase: .began, x: 0.1))
        _ = q.pop(limit: 10)
        q.push(TestEvent(id: 1, phase: .moved, x: 0.4))
        q.requestResync()
        #expect(q.pop(limit: 10) == [TestEvent(id: 1, phase: .moved, x: 0.4)])
        #expect(q.isEmpty)
    }

    @Test func secondOverflowBeforeResyncDelivered() {
        var q = TouchEventQueue<TestEvent>(capacity: 4)
        var consumer = Consumer()
        for i in 0..<10 { q.push(TestEvent(id: UInt64(i % 3 + 1), phase: i < 3 ? .began : .moved)) }
        consumer.apply(q.pop(limit: 1))                 // 只取出一部分重新同步事件
        for _ in 0..<10 { q.push(TestEvent(id: 2, phase: .moved)) }   // 再次溢位
        q.push(TestEvent(id: 1, phase: .ended))
        while !q.isEmpty { consumer.apply(q.pop(limit: 2)) }
        #expect(consumer.active.keys.sorted() == [2, 3])
    }

    /// C API 用的 pop(into:) 與 pop(limit:) 結果相同（含溢位後的重新同步，以及 buffer 比事件少的情況）
    @Test func popIntoMatchesPopLimit() {
        var a = TouchEventQueue<TestEvent>(capacity: 4)
        var b = a
        for id: UInt64 in 1...3 { a.push(TestEvent(id: id, phase: .began)); b.push(TestEvent(id: id, phase: .began)) }
        #expect(a.pop(limit: 2) == popInto(&b, 2))
        for id: UInt64 in 4...9 { a.push(TestEvent(id: id, phase: .moved)); b.push(TestEvent(id: id, phase: .moved)) }
        for limit in [1, 2, 3, 100] { #expect(a.pop(limit: limit) == popInto(&b, limit)) }
        #expect(a.isEmpty && b.isEmpty)
    }

    func popInto(_ q: inout TouchEventQueue<TestEvent>, _ capacity: Int) -> [TestEvent] {
        var buffer = [TestEvent](repeating: TestEvent(id: 0, phase: .began), count: capacity)
        let n = buffer.withUnsafeMutableBufferPointer { q.pop(into: $0) }
        return Array(buffer.prefix(n))
    }
}
