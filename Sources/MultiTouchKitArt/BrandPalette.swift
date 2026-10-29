import CoreGraphics
import Foundation

/// 品牌色彩系統：五根手指各一個色相（mtk-viewer 的「觸點 id × 37°」，取 id 1、3、5、7、9），
/// 依背景分別調整明度，讓圖示與字標在深色、淺色背景上都清楚。
///
/// 明度以程式搜尋：從基準值往「遠離背景」的方向調整，直到與背景的 WCAG 對比 ≥ `minimumContrast`
/// （大字的 AA 標準是 3:1，另留餘裕）。色相不變，所以深淺兩組看起來是同一套顏色。
public enum BrandPalette {
    public enum Finger: Int, CaseIterable, Sendable {
        case thumb, index, middle, ring, little

        /// mtk-viewer 的觸點 id（色相 = id × 37°）：拇指橘、食指綠、中指青、無名指紫、小指粉
        public var touchID: Int { rawValue * 2 + 1 }
        public var name: String { ["拇指", "食指", "中指", "無名指", "小指"][rawValue] }
    }

    public enum Theme: Sendable, CaseIterable {
        /// GitHub 深色背景 #0d1117；圖示的深色底也使用這組
        case dark
        /// GitHub 淺色背景 #ffffff
        case light

        var background: BrandIcon.RGB { self == .dark ? BrandIcon.RGB(0x0D, 0x11, 0x17) : BrandIcon.RGB(0xFF, 0xFF, 0xFF) }
        /// 中性前景（字標的 Kit、標題文字）
        public var foreground: String { self == .dark ? "#F0F3F6" : "#1F2328" }
        /// 次要文字（副標題）
        public var muted: String { self == .dark ? "#9198A1" : "#59636E" }
    }

    /// 對比門檻：大字標準 3:1 另留餘裕。深色背景提高到 4.5，讓暗色相（紫）的亮度與其他四色一致
    public static func minimumContrast(_ theme: Theme) -> Double { theme == .dark ? 4.5 : 3.4 }
    static let saturation = 0.72

    public static func hue(_ finger: Finger) -> CGFloat { BrandIcon.hue(finger.touchID) }

    /// 這根手指在該主題上的顏色
    static func color(_ finger: Finger, _ theme: Theme) -> BrandIcon.RGB {
        let background = theme.background
        // 深色背景：從 L 0.58 往亮調；淺色背景：從 L 0.46 往暗調
        var l = theme == .dark ? 0.58 : 0.46
        let step = theme == .dark ? 0.01 : -0.01
        var c = BrandIcon.hsl(hue(finger), saturation, l)
        while contrast(c, background) < minimumContrast(theme), l > 0.2, l < 0.85 {
            l += step
            c = BrandIcon.hsl(hue(finger), saturation, l)
        }
        return c
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

    /// 字標每個字母與背景的對比（mtk-art 輸出成表格）
    public static func contrastReport() -> String {
        var lines = ["| 字母 | 手指 | 深色 #0d1117 | 對比 | 淺色 #ffffff | 對比 |", "|---|---|---|---|---|---|"]
        for (letter, finger) in Wordmark.coloredLetters {
            let d = color(finger, .dark), l = color(finger, .light)
            lines.append(String(format: "| %@ | %@ | %@ | %.2f | %@ | %.2f |", letter, finger.name, d.hex,
                                contrast(d, Theme.dark.background), l.hex, contrast(l, Theme.light.background)))
        }
        for theme in Theme.allCases {
            let fg = rgb(hex: theme.foreground), muted = rgb(hex: theme.muted)
            lines.append(String(format: "| Kit／副標（%@） | 中性 | %@ / %@ | %.2f / %.2f | | |", theme == .dark ? "深色" : "淺色",
                                theme.foreground, theme.muted, contrast(fg, theme.background), contrast(muted, theme.background)))
        }
        for theme in Theme.allCases {
            let stops = Wordmark.magicStops(theme).map { rgb(hex: $0) }
            let values = stops.map { contrast($0, theme.background) }
            lines.append(String(format: "| Kit 的 i 點（%@） | 虹彩 | %@ | 最低 %.2f | | |", theme == .dark ? "深色" : "淺色",
                                Wordmark.magicStops(theme).joined(separator: " "), values.min() ?? 0))
        }
        return lines.joined(separator: "\n")
    }
}
