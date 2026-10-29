import CoreGraphics
import Foundation

/// 品牌色彩系統（v1 定版）：五根手指各一個色相（mtk-viewer 的「觸點 id × 37°」，取 id 1、3、5、7、9），
/// 依背景調整明度；色相不變，所以各處看起來是同一套顏色。
///
/// 只有兩級：`.dark` 是深色底上的鮮豔色階（圖示、README banner 的深色底板、網頁深色主題），
/// `.light` 是白底上的色階（網頁淺色主題）。README banner 自帶深色底板，不依賴 GitHub 的深淺色主題，
/// 所以不需要在兩種背景上都可讀的中明度折衷。
public enum BrandPalette {
    public enum Finger: Int, CaseIterable, Sendable {
        case thumb, index, middle, ring, little

        /// mtk-viewer 的觸點 id（色相 = id × 37°）：拇指橘、食指綠、中指青、無名指紫、小指粉
        public var touchID: Int { rawValue * 2 + 1 }
        public var name: String { ["拇指", "食指", "中指", "無名指", "小指"][rawValue] }
    }

    public enum Theme: Sendable, CaseIterable {
        /// 深色底（#0d1117 或更暗）：鮮豔、高明度，對比 ≥ 4.5:1
        case dark
        /// 白底：飽和、較深，對比 ≥ 4.5:1
        case light

        public var foreground: String { self == .dark ? "#F0F3F6" : "#1F2328" }
        public var muted: String { self == .dark ? "#9198A1" : "#59636E" }
    }

    static let white = BrandIcon.RGB(0xFF, 0xFF, 0xFF)
    static let githubDark = BrandIcon.RGB(0x0D, 0x11, 0x17)
    /// 五指的飽和度
    static let saturation = 0.75
    static let minimumContrast = 4.5

    public static func hue(_ finger: Finger) -> CGFloat { BrandIcon.hue(finger.touchID) }

    /// 這根手指在該背景的顏色
    static func color(_ finger: Finger, _ theme: Theme) -> BrandIcon.RGB {
        color(hue: hue(finger), theme)
    }

    /// 任意色相在該背景的顏色（Kit 的漸層也用它，所以與五指同樣達到 4.5:1）
    static func color(hue: CGFloat, _ theme: Theme, saturation: Double = saturation) -> BrandIcon.RGB {
        switch theme {
        case .dark:
            // 從 L 0.58 往亮調到對 #0d1117 達 4.5:1
            var l = 0.58
            var c = BrandIcon.hsl(hue, saturation, l)
            while contrast(c, githubDark) < minimumContrast, l < 0.85 {
                l += 0.01
                c = BrandIcon.hsl(hue, saturation, l)
            }
            return c
        case .light:
            // 從 L 0.5 往暗調到對白底達 4.5:1
            var l = 0.5
            var c = BrandIcon.hsl(hue, saturation, l)
            while contrast(c, white) < minimumContrast, l > 0.15 {
                l -= 0.01
                c = BrandIcon.hsl(hue, saturation, l)
            }
            return c
        }
    }

    /// Kit 漸層的色階
    static func kitColors(_ theme: Theme) -> [BrandIcon.RGB] {
        Wordmark.kitHues.map { color(hue: $0, theme, saturation: Wordmark.kitSaturation) }
    }

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

    /// 網頁用的 CSS 變數（Examples/web/brand.css）：五指色與 Kit 漸層，依 prefers-color-scheme 切換
    public static func css() -> String {
        func block(_ theme: Theme) -> String {
            let fingers = Finger.allCases.map { "--mtk-\(["thumb", "index", "middle", "ring", "little"][$0.rawValue]): \(color($0, theme).hex);" }
            let kit = kitColors(theme).map(\.hex)
            return (fingers + ["--mtk-kit: linear-gradient(90deg, \(kit.joined(separator: ", ")));"]).map { "    " + $0 }.joined(separator: "\n")
        }
        return """
        /* 由 mtk-art 產生（scripts/generate-art.sh），請勿手動修改：MultiTouchKit 品牌色彩（BrandPalette，v1 定版）。
           深色主題用深色底的鮮豔色階，淺色主題用白底色階，兩者對各自背景都 ≥ 4.5:1。 */
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

    /// WCAG 對比表（mtk-art 輸出）：banner 對深色底板最亮處、網頁淺色主題對白底
    public static func contrastReport() -> String {
        let plate = BrandIcon.bannerPlateBrightest
        var lines = ["| 元素 | banner／網頁深色 | 對 banner 底板最亮處 \(plate.hex) | 對 #0d1117 | 網頁淺色 | 對白底 |", "|---|---|---|---|---|---|"]
        var worstBanner = Double.infinity, worstLight = Double.infinity
        func row(_ name: String, _ d: BrandIcon.RGB, _ l: BrandIcon.RGB?) {
            let onPlate = contrast(d, plate)
            worstBanner = min(worstBanner, onPlate)
            var line = String(format: "| %@ | %@ | %.2f | %.2f |", name, d.hex, onPlate, contrast(d, githubDark))
            if let l {
                worstLight = min(worstLight, contrast(l, white))
                line += String(format: " %@ | %.2f |", l.hex, contrast(l, white))
            } else {
                line += " — | — |"
            }
            lines.append(line)
        }
        for (letter, finger) in Wordmark.coloredLetters {
            row("\(letter)（\(finger.name)）", color(finger, .dark), color(finger, .light))
        }
        for (i, (d, l)) in zip(kitColors(.dark), kitColors(.light)).enumerated() {
            row("Kit 漸層色階 \(i + 1)", d, l)
        }
        row("副標題", rgb(hex: Theme.dark.muted), nil)
        lines.append("")
        lines.append(String(format: "最低值：banner 對底板 %.2f、網頁淺色對白底 %.2f", worstBanner, worstLight))
        return lines.joined(separator: "\n")
    }
}
