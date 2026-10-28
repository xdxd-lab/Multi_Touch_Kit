import Foundation
import Testing
@testable import MultiTouchKit

/// 熱路徑微基準（平常略過）。執行：`MTK_BENCH=1 ./scripts/test.sh -c release --filter HotPathBenchmarks`
///
/// 緊密迴圈的快取是熱的，只適合前後對照；整個程序的實際成本請用 rusage（見 docs/reviews/2026-10-code-review.md）：
/// `/usr/bin/time -p perl -e 'alarm 15; exec @ARGV' .build/release/mtk-server --simulate`
@Suite struct HotPathBenchmarks {
    static let enabled = ProcessInfo.processInfo.environment["MTK_BENCH"] != nil

    func frames(fingers n: Int) -> [TouchFrame] {
        (0..<1000).map { s in
            TouchFrame(deviceID: 1, sequence: UInt64(s), timestamp: UInt64(s) * 8_000_000, scanTime: nil, touches: (0..<n).map { i in
                Touch(id: UInt64(i + 1), contactID: i, phase: .moved, x: 0.1 + 0.07 * Double(i) + Double(s % 100) * 1e-4,
                      y: 0.5, rawX: 1000 + i + s % 7, rawY: 2000)
            })
        }
    }

    func measure(_ label: String, iterations: Int = 20_000, _ body: (Int) -> Int) {
        var sink = 0
        let elapsed = ContinuousClock().measure { for i in 0..<iterations { sink &+= body(i) } }
        let ns = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
        print(String(format: "BENCH %-22@ %7.2f µs/frame（sink %d）", label, ns / Double(iterations) / 1000, sink & 1))
    }

    @Test(.enabled(if: enabled)) func encoders() {
        for n in [3, 10] {
            let frames = frames(fingers: n)
            measure("TouchJSON.frame \(n)指") { TouchJSON.frame(frames[$0 % 1000]).utf8.count }
            var json: [UInt8] = []
            measure("TouchJSON.frameBytes \(n)指") { i in
                json.removeAll(keepingCapacity: true)
                TouchJSON.frameBytes(frames[i % 1000], into: &json)
                return json.count
            }
            var tuio = TUIOEncoder(source: "MultiTouchKit@host")
            measure("TUIO encode \(n)指") { let f = frames[$0 % 1000]; return tuio.encode(alive: f.touches, updated: f.touches, timestamp: f.timestamp).count }
            var osc: [UInt8] = []
            measure("TUIO encode(into:) \(n)指") { i in
                let f = frames[i % 1000]
                tuio.encode(alive: f.touches, updated: f.touches, onlyChanged: true, timestamp: f.timestamp, into: &osc)
                return osc.count
            }
        }
    }

    @Test(.enabled(if: enabled)) func tracker() {
        for n in [3, 10] {
            var tracker = ContactTracker()
            tracker.stalePolicy.timeout = 30
            var id: UInt64 = 0
            let raws = (0..<1000).map { s in
                (0..<n).map { i in RawContact(contactID: i, tip: true, x: 0.1 * Double(i) + Double(s % 7) * 1e-3, y: 0.5, rawX: i * 100 + s % 7, rawY: 5) }
            }
            measure("ContactTracker \(n)指") { i in
                tracker.update(raws[i % 1000], at: UInt64(i + 1) * 8_000_000) { id += 1; return id }.count
            }
        }
    }
}
