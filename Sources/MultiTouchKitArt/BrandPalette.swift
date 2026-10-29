import CoreGraphics
import Foundation

/// 品牌色彩系統：五根手指各一個色相（mtk-viewer 的「觸點 id × 37°」，取 id 1、3、5、7、9），
/// 依用途調整明度；色相不變，所以各處看起來是同一套顏色。
///
/// README banner 的深色／淺色變體**都必須在兩種背景上可讀**：GitHub 依頁面主題與作業系統主題決定送出哪個
/// `<picture>` 變體，兩者不一致時，深色變體可能出現在白底上（實際發生過：Kit 的白字在淺色頁面幾乎看不見）。
/// 與白底（#ffffff）與 GitHub 深色底（#0d1117）都達到 3:1 的相對亮度 Y 只有 0.117–0.30 這一段，
/// 所以兩個變體都取中明度：深色變體 Y 0.24、淺色變體 Y 0.165（各自略偏向自己的背景）。
/// 圖示永遠在深色圖示底上，使用較鮮豔的一組（`.icon`）。
public enum BrandPalette {
    public enum Finger: Int, CaseIterable, Sendable {
        case thumb, index, middle, ring, little

        /// mtk-viewer 的觸點 id（色相 = id × 37°）：拇指橘、食指綠、中指青、無名指紫、小指粉
        public var touchID: Int { rawValue * 2 + 1 }
        public var name: String { ["拇指", "食指", "中指", "無名指", "小指"][rawValue] }
    }

    public enum Theme: Sendable, CaseIterable {
        /// banner 深色變體（主要給 #0d1117，白底上也可讀）
        case dark
        /// banner 淺色變體（主要給 #ffffff，深色底上也可讀）
        case light
        /// 圖示：深色圖示底上的鮮豔色階
        case icon

        /// 目標相對亮度（banner 變體）
        var targetLuminance: Double { self == .dark ? 0.24 : 0.165 }
    }

    static let white = BrandIcon.RGB(0xFF, 0xFF, 0xFF)
    static let githubDark = BrandIcon.RGB(0x0D, 0x11, 0x17)
    static let saturation = 0.75

    public static func hue(_ finger: Finger) -> CGFloat { BrandIcon.hue(finger.touchID) }

    /// 這根手指在該用途的顏色
    static func color(_ finger: Finger, _ theme: Theme) -> BrandIcon.RGB {
        color(hue: hue(finger), theme)
    }

    /// 任意色相在該用途的顏色（Kit 的虹彩漸層也用它，所以與五指同樣兩邊可讀）
    static func color(hue: CGFloat, _ theme: Theme) -> BrandIcon.RGB {
        switch theme {
        case .icon:
            // 深色圖示底：從 L 0.58 往亮調到對 #0d1117 達 4.5:1
            var l = 0.58
            var c = BrandIcon.hsl(hue, saturation, l)
            while contrast(c, githubDark) < 4.5, l < 0.85 {
                l += 0.01
                c = BrandIcon.hsl(hue, saturation, l)
            }
            return c
        case .dark, .light:
            // 二分搜尋明度，讓相對亮度等於目標值
            var low = 0.05, high = 0.95
            for _ in 0..<40 {
                let mid = (low + high) / 2
                if luminance(BrandIcon.hsl(hue, saturation, mid)) < theme.targetLuminance { low = mid } else { high = mid }
            }
            return BrandIcon.hsl(hue, saturation, (low + high) / 2)
        }
    }

    /// 副標題的中性灰（兩種背景都可讀；28 pt 屬大字）
    public static let subtitle = "#7D8590"

    /// WCAG 2.x 對比值
    static func contrast(_ a: BrandIcon.RGB, _ b: BrandIcon.RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ c: BrandIcon.RGB) -> Double {
        func channel(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func rgb(hex: String) -> BrandIcon.RGB {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        return BrandIcon.RGB((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    /// 網頁用的 CSS 變數（Examples/web/brand.css）：五指色與 Kit 漸層，依 prefers-color-scheme 切換兩個變體
    public static func css() -> String {
        func block(_ theme: Theme) -> String {
            let fingers = Finger.allCases.map { "--mtk-\(["thumb", "index", "middle", "ring", "little"][$0.rawValue]): \(color($0, theme).hex);" }
            let kit = Wordmark.kitHues.map { color(hue: $0, theme).hex }
            return (fingers + ["--mtk-kit: linear-gradient(135deg, \(kit.joined(separator: ", ")));"]).map { "    " + $0 }.joined(separator: "\n")
        }
        return """
        /* 由 mtk-art 產生（scripts/generate-art.sh），請勿手動修改：MultiTouchKit 品牌色彩（BrandPalette）。
           兩個變體都是中明度，在深淺兩種背景上都可讀。 */
        :root {
        \(block(.dark))
        }
        @media (prefers-color-scheme: light) {
          :root {
        \(block(.light).split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
          }
        }

        """
    }

    /// banner 兩個變體 × 兩種背景的 WCAG 對比（mtk-art 輸出）：每個字母、Kit 漸層的每個色階、魔法棒的星芒、副標題
    public static func contrastReport() -> String {
        var lines = ["| 元素 | 深色變體 | 對白底 | 對 #0d1117 | 淺色變體 | 對白底 | 對 #0d1117 |", "|---|---|---|---|---|---|---|"]
        var minimum: [String: Double] = [:]
        func row(_ name: String, _ d: BrandIcon.RGB, _ l: BrandIcon.RGB) {
            let values = [contrast(d, white), contrast(d, githubDark), contrast(l, white), contrast(l, githubDark)]
            for (key, v) in zip(["深色變體／白底", "深色變體／深色底", "淺色變體／白底", "淺色變體／深色底"], values) {
                minimum[key] = min(minimum[key] ?? .infinity, v)
            }
            lines.append(String(format: "| %@ | %@ | %.2f | %.2f | %@ | %.2f | %.2f |", name, d.hex, values[0], values[1], l.hex, values[2], values[3]))
        }
        for (letter, finger) in Wordmark.coloredLetters {
            row("\(letter)（\(finger.name)）", color(finger, .dark), color(finger, .light))
        }
        for (i, hue) in Wordmark.kitHues.enumerated() {
            row("Kit 漸層色階 \(i + 1)", color(hue: hue, .dark), color(hue: hue, .light))
        }
        row("魔法棒點綴（洋紅）", color(hue: Wordmark.sparkleHue, .dark), color(hue: Wordmark.sparkleHue, .light))
        row("副標題", rgb(hex: subtitle), rgb(hex: subtitle))
        lines.append("")
        lines.append("最低值：" + ["深色變體／白底", "深色變體／深色底", "淺色變體／白底", "淺色變體／深色底"]
            .map { String(format: "%@ %.2f", $0, minimum[$0] ?? 0) }.joined(separator: "、"))
        return lines.joined(separator: "\n")
    }
}
