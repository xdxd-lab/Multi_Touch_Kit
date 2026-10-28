import Foundation

/// 以 NSLock 保護的值：讓 handler、裝置清單等「任何執行緒都可讀寫」的屬性不必各自寫一組鎖與底線欄位。
/// （`Synchronization.Mutex` 需要 macOS 15，部署目標是 13。）
package final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    package init(_ value: Value) {
        self.value = value
    }

    package var wrapped: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// 在鎖內讀取或修改（需要「讀取後再寫入」保持一致時使用）
    package func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&value) }
    }
}
