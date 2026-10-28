import Foundation

/// TouchEventQueue 存放的事件（C API 的 MTKTouchEvent 等）
public protocol QueuedTouchEvent: Sendable {
    var queuedTouchID: UInt64 { get }
    var queuedPhase: TouchPhase { get }
    /// 同一個觸點、改成指定階段的事件（重新同步時使用）
    func withQueuedPhase(_ phase: TouchPhase) -> Self
}

/// 給「輪詢」使用者（Unity NativeTransport、Python、C）的固定容量事件佇列，**溢位時不會遺失觸點狀態**。
///
/// 使用者停止輪詢（例如 Unity 編輯器失去焦點）時佇列會滿。單純丟掉最舊的事件會遺失 ended，
/// 觸點就永遠留在使用者的「仍在螢幕上」清單裡。所以溢位時改為：丟棄佇列內容，下次 `pop` 時先送出
/// 重新同步：使用者以為還在、實際已離開的觸點送 cancelled；仍在螢幕上的觸點送 began（使用者還不知道的）
/// 或 moved（目前位置），之後再接續新的事件。
public struct TouchEventQueue<Event: QueuedTouchEvent>: Sendable {
    public let capacity: Int
    private var ring: [Event?]
    private var head = 0
    private(set) public var count = 0
    /// 溢位或重新同步時丟棄的事件總數
    private(set) public var dropped: UInt64 = 0
    /// 重新同步的次數
    private(set) public var resyncs: UInt64 = 0
    /// 每個仍在螢幕上的觸點的最新事件（不論是否已被取出）
    private var current: [UInt64: Event] = [:]
    /// 使用者已取出 began、尚未取出 ended／cancelled 的觸點（與最後取出的事件）
    private var announced: [UInt64: Event] = [:]
    private var needsResync = false
    /// 重新同步產生、尚未被取出的事件（比 ring 內的事件早）
    private var resyncEvents: [Event] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        ring = Array(repeating: nil, count: self.capacity)
    }

    public var isEmpty: Bool { count == 0 && !needsResync && resyncEvents.isEmpty }

    public mutating func push(_ event: Event) {
        if event.queuedPhase.isTerminal {
            current[event.queuedTouchID] = nil
        } else {
            current[event.queuedTouchID] = event
        }
        if count == capacity {
            dropped += UInt64(count)
            clearRing()
            needsResync = true
        }
        ring[(head + count) % capacity] = event
        count += 1
    }

    /// 要求下次 `pop` 先重新同步（例如 Unity 重新取得焦點時對帳）
    public mutating func requestResync() {
        needsResync = true
    }

    /// 依時間順序取出最多 `limit` 個事件
    public mutating func pop(limit: Int) -> [Event] {
        guard limit > 0 else { return [] }
        var out: [Event] = []
        out.reserveCapacity(min(limit, count + resyncEvents.count + (needsResync ? current.count + announced.count : 0)))
        drain(limit: limit) { out.append($0) }
        return out
    }

    /// 依時間順序直接寫入 `buffer`（不配置陣列），回傳寫入的數量。C API 的 mtk_poll_events 使用
    package mutating func pop(into buffer: UnsafeMutableBufferPointer<Event>) -> Int {
        var n = 0
        drain(limit: buffer.count) { event in
            buffer[n] = event
            n += 1
        }
        return n
    }

    private mutating func drain(limit: Int, _ sink: (Event) -> Void) {
        guard limit > 0 else { return }
        if needsResync {
            needsResync = false
            resyncs += 1
            // 佇列裡的事件都比 current 舊：丟棄，改送目前狀態
            dropped += UInt64(count)
            clearRing()
            resyncEvents = []
            for (id, last) in announced.sorted(by: { $0.key < $1.key }) where current[id] == nil {
                resyncEvents.append(last.withQueuedPhase(.cancelled))
            }
            for (id, event) in current.sorted(by: { $0.key < $1.key }) {
                resyncEvents.append(event.withQueuedPhase(announced[id] == nil ? .began : .moved))
            }
        }
        // 取出時才算「已交給使用者」（下次重新同步依此判斷）
        let fromResync = min(limit, resyncEvents.count)
        for e in resyncEvents.prefix(fromResync) {
            note(e)
            sink(e)
        }
        resyncEvents.removeFirst(fromResync)
        let n = min(limit - fromResync, count)
        for _ in 0..<n {
            let event = ring[head]!
            ring[head] = nil
            head = (head + 1) % capacity
            count -= 1
            note(event)
            sink(event)
        }
    }

    private mutating func note(_ event: Event) {
        if event.queuedPhase.isTerminal {
            announced[event.queuedTouchID] = nil
        } else {
            announced[event.queuedTouchID] = event
        }
    }

    private mutating func clearRing() {
        for i in 0..<capacity { ring[i] = nil }
        head = 0
        count = 0
    }
}
