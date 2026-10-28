// mtk-probe：量測觸控面板的回報率、抖動、同時觸點數與連打表現。
import CoreGraphics
import Foundation
import MultiTouchKit

struct ProbeOptions {
    var seconds = 30.0
    var wait = 300.0
    var csvPath: String?
    var simulate = false
    var exclusive = true
    var staleTouchTimeout: Double?
    var calibration = true

    static let usage = """
    用法：mtk-probe [選項]
      --seconds N     第一次觸控後記錄 N 秒（預設 30）
      --wait N        最多等待第一次觸控 N 秒（預設 300）
      --csv PATH      輸出每個 frame 的原始資料
      --shared        不獨占裝置（系統游標仍會跟著動）
      --simulate      使用模擬觸控（不需要硬體）
      --stale-touch-timeout SEC  誤觸：觸點幾乎不動超過 SEC 秒就取消（預設 30，0 = 關閉）
      --no-calibration  不套用觸控校正（量測控制器的原始座標）
    """

    static func parse(_ arguments: [String]) -> ProbeOptions {
        var o = ProbeOptions()
        var args = CommandLineArguments(arguments, usage: usage)
        while let a = args.next() {
            switch a {
            case "--seconds": o.seconds = args.positive(for: a, "大於 0 的秒數")
            case "--wait": o.wait = args.positive(for: a, "大於 0 的秒數")
            case "--csv": o.csvPath = args.value(for: a, "檔案路徑")
            case "--shared": o.exclusive = false
            case "--simulate": o.simulate = true
            case "--stale-touch-timeout": o.staleTouchTimeout = args.staleTouchTimeout()
            case "--no-calibration": o.calibration = false
            default: args.unknown(a)
            }
        }
        return o
    }
}

@main
struct ProbeCommand {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let probe = Probe(options: ProbeOptions.parse(Array(CommandLine.arguments.dropFirst())))
        probe.run()
        withExtendedLifetime(probe) { dispatchMain() }
    }
}

/// 所有可變狀態都只在觸控來源的佇列上存取
final class Probe: @unchecked Sendable {
    let options: ProbeOptions
    private var source: TouchSource!
    private var queue: DispatchQueue { source.queue }
    private var signalSources: [DispatchSourceSignal] = []

    private var started = false
    private var finished = false
    private var startTime: UInt64 = 0
    private var lastTimestamp: UInt64 = 0
    private var lastActiveCount = 0
    private var lastScan: UInt32?
    private var lastAllUp: UInt64?
    private var intervals: [Double] = []
    private var intervalsByCount: [Int: [Double]] = [:]
    private var scanDeltas: [Double] = []
    private var downs: [UInt64] = []
    private var beganAt: [UInt64: UInt64] = [:]
    private var tapDurations: [Double] = []
    private var releaseGaps: [Double] = []
    private var maxSimultaneous = 0
    private var frames = 0
    private var cursorMoves = 0
    private var lastCursor: CGPoint?
    private var cursorTimer: DispatchSourceTimer?
    private var csv = "t_ms,device,seq,scan,touches(id:cid:phase:x:y)\n"

    init(options: ProbeOptions) {
        self.options = options
    }

    func run() {
        if options.simulate {
            source = SimulatedTouchSource()
            print("使用模擬觸控來源")
        } else {
            var configuration = MultiTouchManager.Configuration()
            configuration.exclusive = options.exclusive
            if let v = options.staleTouchTimeout { configuration.staleTouchTimeout = v }
            if !options.calibration { configuration.calibration = .disabled }
            let manager = MultiTouchManager(configuration: configuration)
            manager.logHandler = { print($0) }
            source = manager
        }
        source.frameHandler = { [self] in handle($0) }
        do {
            try source.start()
        } catch {
            print("啟動失敗：\(error)")
            exit(1)
        }
        if source.connectedDevices.isEmpty { print("目前沒有偵測到觸控螢幕，接上後會自動開始。") }
        print("已就緒，等待第一次觸控（最多 \(Int(options.wait)) 秒）…")
        queue.asyncAfter(deadline: .now() + options.wait) { [self] in
            if !started {
                print("等待逾時，未偵測到觸控。")
                finish()
            }
        }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let signalSource = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            signalSource.setEventHandler { [self] in finish() }
            signalSource.resume()
            signalSources.append(signalSource)
        }
    }

    private func handle(_ frame: TouchFrame) {
        guard !finished else { return }
        let active = frame.activeTouches.count
        if !started {
            guard frame.touches.contains(where: { $0.phase == .began }) else { return }
            started = true
            startTime = frame.timestamp
            print("偵測到觸控，開始記錄 \(Int(options.seconds)) 秒…")
            queue.asyncAfter(deadline: .now() + options.seconds) { [self] in finish() }
            startCursorSampling()
        }
        frames += 1
        if lastActiveCount > 0 {
            let interval = Double(frame.timestamp &- lastTimestamp) / 1e6
            intervals.append(interval)
            intervalsByCount[lastActiveCount, default: []].append(interval)
            if let scan = frame.scanTime, let previous = lastScan { scanDeltas.append(Double(scan &- previous)) }
        }
        for t in frame.touches {
            switch t.phase {
            case .began:
                downs.append(frame.timestamp)
                beganAt[t.id] = frame.timestamp
                if lastActiveCount == 0, let up = lastAllUp { releaseGaps.append(Double(frame.timestamp &- up) / 1e6) }
            case .ended, .cancelled:
                if let start = beganAt.removeValue(forKey: t.id) {
                    tapDurations.append(Double(frame.timestamp &- start) / 1e6)
                }
            default:
                break
            }
        }
        if active == 0 && lastActiveCount > 0 { lastAllUp = frame.timestamp }
        maxSimultaneous = max(maxSimultaneous, active)
        lastTimestamp = frame.timestamp
        lastActiveCount = active
        lastScan = frame.scanTime

        if options.csvPath != nil {
            let ms = Double(Int64(bitPattern: frame.timestamp &- startTime)) / 1e6
            let touches = frame.touches.map {
                "\($0.id):\($0.contactID):\($0.phase):" + String(format: "%.5f:%.5f", $0.x, $0.y)
            }.joined(separator: " ")
            csv += String(format: "%.3f", ms) + ",\(frame.deviceID),\(frame.sequence),\(frame.scanTime.map(String.init) ?? ""),\(touches)\n"
        }
    }

    /// 游標位置以 10 Hz 取樣：查詢游標是對 WindowServer 的 IPC，每個 frame（125 Hz）查一次會干擾量測本身
    private func startCursorSampling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [self] in
            guard let p = CGEvent(source: nil)?.location else { return }
            if let l = lastCursor, hypot(p.x - l.x, p.y - l.y) > 1 { cursorMoves += 1 }
            lastCursor = p
        }
        cursorTimer = timer
        timer.resume()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        cursorTimer?.cancel()
        source.stop()
        report()
        exit(0)
    }

    private func report() {
        guard started else { return }
        print("\n===== 量測結果 =====")
        print("Frame 數：\(frames)")
        if !intervals.isEmpty {
            let median = percentile(intervals, 0.5)
            print(String(format: "觸控中回報間隔：中位數 %.2f ms（約 %.0f Hz）、p95 %.2f ms、p99 %.2f ms、最大 %.2f ms",
                         median, 1000 / median, percentile(intervals, 0.95), percentile(intervals, 0.99), intervals.max()!))
            print("  間隔超過中位數 2 倍的次數：\(intervals.filter { $0 > median * 2 }.count) / \(intervals.count)")
            print("  依同時觸點數的間隔中位數：" + intervalsByCount.sorted { $0.key < $1.key }.map {
                String(format: "%d 指 %.1f ms（n=%d）", $0.key, percentile($0.value, 0.5), $0.value.count)
            }.joined(separator: "、"))
        }
        if !scanDeltas.isEmpty {
            let median = percentile(scanDeltas, 0.5)
            print(String(format: "  裝置 Scan Time 差值中位數：%.0f（若單位為 100 µs，即 %.2f ms）", median, median / 10))
        }
        print("\n最多同時觸點：\(maxSimultaneous)")
        print("按下次數：\(downs.count)，完成的點擊（按下→放開）：\(tapDurations.count)")
        if !tapDurations.isEmpty {
            print(String(format: "  按住時間：最短 %.1f ms、中位數 %.1f ms", tapDurations.min()!, percentile(tapDurations, 0.5)))
        }
        let sorted = downs.sorted()
        if let gap = zip(sorted.dropFirst(), sorted).map({ Double($0 &- $1) / 1e6 }).filter({ $0 > 0 }).min() {
            print(String(format: "  不同 frame 的兩次按下最短間隔：%.1f ms", gap))
        }
        var best = 0
        var low = 0
        for high in sorted.indices {
            while sorted[high] &- sorted[low] > 1_000_000_000 { low += 1 }
            best = max(best, high - low + 1)
        }
        print("  任意 1 秒內最多按下次數：\(best)")
        if !releaseGaps.isEmpty {
            print(String(format: "  全部放開→下一次按下：最短 %.1f ms、中位數 %.1f ms", releaseGaps.min()!, percentile(releaseGaps, 0.5)))
        }
        if !options.simulate {
            print("\n記錄期間游標移動次數（10 Hz 取樣）：\(cursorMoves)（獨占成功時應接近 0，除非你同時動了滑鼠）")
        }
        if let path = options.csvPath {
            do {
                try csv.write(toFile: path, atomically: true, encoding: .utf8)
                print("原始資料：\(path)")
            } catch {
                print("寫入 CSV 失敗：\(error)")
            }
        }
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let s = values.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
    }
}
