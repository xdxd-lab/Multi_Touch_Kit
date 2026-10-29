import AppKit
import MultiTouchKit

/// mtk-viewer --calibrate 的畫面：9 個十字同時顯示，使用者任意點擊，靠近某個十字的觸碰就歸給它（TouchCalibrationCollector）。
/// 畫面即時顯示每個十字的點擊數與殘差，以及以目前擬合結果校正後的觸點，讓使用者自己判斷是否滿意後按 Enter 儲存。
@MainActor
final class CalibrationView: NSView {
    struct Context {
        /// 校正的裝置（存檔用）
        var device: MultiTouchDeviceInfo
        /// 觸控螢幕所在的顯示器（只供紀錄）
        var display: DisplayInfo?
        /// 「透過常駐 mtk-server」或「直接讀取觸控螢幕」
        var sourceDescription: String
    }

    private static let targetNames = ["左上", "上", "右上", "左", "中", "右", "左下", "下", "右下"]

    private let context: Context
    private let store = TouchCalibrationStore()
    /// 正規化座標（面板）→ 這個 view 的座標
    var toView: (Double, Double) -> CGPoint = { _, _ in .zero }
    private var collector: TouchCalibrationCollector
    private var fit: TouchCalibration.Fit?
    private var tapMarks: [(position: TouchCalibration.Point, target: Int?)] = []
    private var live: [UInt64: TouchCalibration.Point] = [:]
    private var ripples: [(point: TouchCalibration.Point, start: CFTimeInterval, id: UInt64)] = []
    private var timer: Timer?
    private var message = ""
    var status = "" { didSet { needsDisplay = true } }

    init(context: Context) {
        self.context = context
        collector = TouchCalibrationCollector(panelWidthMillimeters: context.device.physicalWidthMillimeters,
                                              panelHeightMillimeters: context.device.physicalHeightMillimeters)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    var summary: String {
        "mtk-viewer 校正：\(collector.samples.count)/9 個十字、\(collector.taps.map(\.count).reduce(0, +)) 次點擊、未採用 \(collector.ignored) 次"
    }

    // MARK: - 輸入

    func apply(_ frame: TouchFrame) {
        for tap in collector.process(frame) {
            tapMarks.append((tap.position, tap.target))
        }
        fit = collector.fit
        for touch in frame.touches {
            let raw = TouchCalibration.Point(x: touch.uncalibratedX ?? touch.x, y: touch.uncalibratedY ?? touch.y)
            if touch.phase.isTerminal {
                live[touch.id] = nil
            } else {
                live[touch.id] = raw
            }
            if touch.phase == .began { ripples.append((raw, CACurrentMediaTime(), touch.id)) }
        }
        startAnimating()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (event.keyCode, key) {
        case (36, _), (76, _), (_, "s"): save()
        case (_, "r"):
            collector.reset()
            fit = nil
            tapMarks.removeAll()
            message = "已清除，重新開始點擊"
        case (53, _), (_, "q"):
            NSApp.terminate(nil)
        default:
            return
        }
        needsDisplay = true
    }

    private func save() {
        guard let fit else {
            message = "至少需要 3 個十字有點擊才能儲存（建議 9 個都點）"
            return
        }
        if let problem = fit.problem {
            message = "無法儲存：\(problem)。按 R 清除後重來"
            return
        }
        let errors = collector.meanErrors(fit)
        let entry = TouchCalibrationStore.Entry(
            device: .init(context.device), displayEDID: context.display?.edid, displayName: context.display?.name,
            calibration: fit.calibration, samples: collector.samples, errorBefore: errors.before, errorAfter: errors.after ?? 0)
        do {
            try store.save(entry)
            let few = fewTapsTargets
            message = String(format: "已儲存：%@（平均誤差 %.1f → %.1f mm）。執行中的 mtk-server 會在 2 秒內套用", store.url.path,
                             errors.before, errors.after ?? 0)
                + (few.isEmpty ? "" : "。提示：\(few) 點擊少於 3 次，可再點幾次後重新儲存")
            print(message)
        } catch {
            message = "儲存失敗：\(error.localizedDescription)"
        }
    }

    private var fewTapsTargets: String {
        collector.taps.indices.filter { collector.taps[$0].count < 3 }.map { Self.targetNames[$0] }.joined(separator: "、")
    }

    // MARK: - 繪製

    private func startAnimating() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        ripples.removeAll { now - $0.start > 0.35 }
        if ripples.isEmpty {
            timer?.invalidate()
            timer = nil
        }
        needsDisplay = true
    }

    /// 以目前擬合結果校正後的位置（還沒有擬合時為原始位置）
    private func preview(_ p: TouchCalibration.Point) -> CGPoint {
        let q = fit?.calibration.apply(x: p.x, y: p.y) ?? (x: p.x, y: p.y)
        return toView(q.x, q.y)
    }

    private static func hue(_ id: UInt64) -> CGFloat { CGFloat((id * 37) % 360) / 360 }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
                                                    .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        // 十字：歸屬範圍、十字線、點擊數與殘差
        let radius = collector.captureRadius * (toView(1, 0.5).x - toView(0, 0.5).x)
        for (i, target) in collector.targets.enumerated() {
            let center = toView(target.x, target.y)
            let count = collector.taps[i].count
            let residual = collector.residualMillimeters(target: i, fit: fit)
            let excluded = fit?.excluded.contains(collector.samples.firstIndex { $0.target == target } ?? -1) ?? false
            let color: NSColor = count == 0 ? NSColor(white: 1, alpha: 0.55)
                : excluded || (residual ?? 0) > 2 ? .systemRed
                : count < 3 ? .systemOrange : .systemGreen
            color.withAlphaComponent(0.12).setStroke()
            let area = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            area.lineWidth = 1
            area.stroke()
            color.setStroke()
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: center.x - 28, y: center.y)); cross.line(to: CGPoint(x: center.x + 28, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 28)); cross.line(to: CGPoint(x: center.x, y: center.y + 28))
            cross.lineWidth = 2
            cross.stroke()
            let label = count == 0 ? "尚未點擊" : residual.map { String(format: "%d 次 · %.1f mm", count, $0) } ?? "\(count) 次"
            let size = (label as NSString).size(withAttributes: small)
            (label as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - 52), withAttributes: small)
        }
        // 每次點擊的原始位置（灰色 = 離十字太遠，未採用）
        for mark in tapMarks {
            let p = toView(mark.position.x, mark.position.y)
            (mark.target.map { NSColor(hue: Self.hue(UInt64($0) + 1), saturation: 0.7, brightness: 0.95, alpha: 0.7) }
                ?? NSColor(white: 0.5, alpha: 0.5)).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
        }
        // 擴散圈與即時觸點：畫在校正後的位置（mtk-viewer 的觸控特效），原始位置以小圓環標示
        let now = CACurrentMediaTime()
        for r in ripples {
            let progress = CGFloat((now - r.start) / 0.35)
            let p = preview(r.point), radius = 40 + progress * 80
            NSColor(hue: Self.hue(r.id), saturation: 0.8, brightness: 1, alpha: 1 - progress).setStroke()
            let path = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            path.lineWidth = 4
            path.stroke()
        }
        let idStyle: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.white]
        for (id, raw) in live {
            let p = preview(raw), r = toView(raw.x, raw.y)
            NSColor(hue: Self.hue(id), saturation: 0.7, brightness: 0.95, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 45, y: p.y - 45, width: 90, height: 90)).fill()
            NSColor(white: 1, alpha: 0.6).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: r.x - 7, y: r.y - 7, width: 14, height: 14))
            ring.lineWidth = 1.5
            ring.stroke()
            let text = "\(id)" as NSString
            let size = text.size(withAttributes: idStyle)
            text.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: idStyle)
        }
        drawPanel()
    }

    /// 說明面板：放在第一、二列十字之間的正中央，不遮住任何十字
    private func drawPanel() {
        var lines = ["觸控校正（\(context.device.product)，\(context.sourceDescription)）",
                     "點擊任何十字的中心；靠近十字的觸碰會自動歸給它，可以任意順序、重複點。",
                     "Enter／S 儲存　R 清除重來　Esc 離開"]
        let errors = collector.meanErrors(fit)
        let total = collector.taps.map(\.count).reduce(0, +)
        var stats = "已點擊 \(collector.samples.count)/9 個十字（共 \(total) 次"
            + (collector.ignored > 0 ? "，未採用 \(collector.ignored) 次）" : "）")
        if let after = errors.after, let fit {
            stats += String(format: "　平均誤差：校正前 %.1f mm → 校正後 %.1f mm（%@）", errors.before, after,
                            fit.calibration.model == .quadratic ? "二次" : "仿射")
        }
        lines.append(stats)
        if let problem = fit?.problem { lines.append("⚠ \(problem)") }
        if let excluded = fit?.excluded.first, excluded < collector.samples.count,
           let index = collector.targets.firstIndex(of: collector.samples[excluded].target) {
            lines.append("⚠ \(Self.targetNames[index]) 的點擊與其他點不一致，暫不採用（可按 R 重來或多點幾次）")
        }
        if !message.isEmpty { lines.append(message) }
        if !status.isEmpty { lines.append(status) }
        let text = lines.joined(separator: "\n") as NSString
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium),
                                                    .foregroundColor: NSColor(white: 0.9, alpha: 1)]
        let size = text.boundingRect(with: CGSize(width: bounds.width * 0.7, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin], attributes: style).size
        let top = toView(0.5, 0.1).y, middle = toView(0.5, 0.5).y
        let origin = CGPoint(x: bounds.midX - size.width / 2, y: (top + middle) / 2 - size.height / 2)
        let box = NSRect(origin: origin, size: size).insetBy(dx: -18, dy: -14)
        NSColor(white: 0.12, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14).fill()
        text.draw(with: NSRect(origin: origin, size: size), options: [.usesLineFragmentOrigin], attributes: style)
    }
}
