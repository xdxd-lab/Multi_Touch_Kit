import Foundation

/// 「MultiTouchKit」字標：單線圓角筆畫的幾何字形（以路徑繪製，不使用字型：沒有授權問題，各平台呈現一致）。
///
/// 概念：「MultiTouch」10 個字母 = 10 根手指。Multi = 左手（M 小指 → i 拇指），Touch = 右手（T 拇指 → h 小指），
/// 左右鏡像同色：M↔h 小指、u↔c 無名指、l↔u 中指、t↔o 食指、i↔T 拇指，顏色與圖示的五個指尖相同（BrandPalette）。
/// 右手食指的「o」帶一點點擊光暈，呼應圖示中按下的那根食指。
/// 「Kit」用中性前景色；唯一例外是 i 上方的點：帶透明感的虹彩光點，象徵節奏遊戲中點下去的那一擊。
///
/// 座標：字母頂端 y = 0、基線 y = 100、x 字高頂端 y = 34，筆畫寬 14、圓頭圓角。
enum Wordmark {
    static let stroke = 14.0
    static let gap = 22.0

    struct Glyph {
        var letter: String
        var width: Double
        /// 路徑（以字母左緣為 x = 0）
        var paths: [String]
        /// i 的點（圓心 x、半徑）
        var dot: (x: Double, radius: Double)?
    }

    static let glyphs: [String: Glyph] = [
        "M": Glyph(letter: "M", width: 64, paths: ["M0 100V0L32 66L64 0V100"]),
        "u": Glyph(letter: "u", width: 44, paths: ["M0 34V78A22 22 0 0 0 44 78V34", "M44 34V100"]),
        "l": Glyph(letter: "l", width: 0, paths: ["M0 0V100"]),
        "t": Glyph(letter: "t", width: 30, paths: ["M10 6V84A16 16 0 0 0 26 100H30", "M0 34H30"]),
        "i": Glyph(letter: "i", width: 0, paths: ["M0 34V100"], dot: (0, 9)),
        "T": Glyph(letter: "T", width: 64, paths: ["M0 0H64", "M32 0V100"]),
        "o": Glyph(letter: "o", width: 56, paths: ["M56 67A28 33 0 1 0 0 67A28 33 0 1 0 56 67Z"]),
        "c": Glyph(letter: "c", width: 50, paths: ["M49.45 45.79A28 33 0 1 0 49.45 88.21"]),
        "h": Glyph(letter: "h", width: 44, paths: ["M0 0V100", "M0 56A22 22 0 0 1 44 56V100"]),
        "K": Glyph(letter: "K", width: 54, paths: ["M0 0V100", "M50 0L4 60", "M22 38L54 100"]),
    ]

    /// 「MultiTouch」每個字母對應的手指（鏡像配色）
    static let coloredLetters: [(String, BrandPalette.Finger)] = [
        ("M", .little), ("u", .ring), ("l", .middle), ("t", .index), ("i", .thumb),
        ("T", .thumb), ("o", .index), ("u", .middle), ("c", .ring), ("h", .little),
    ]

    /// 虹彩光點的漸層色（依背景調整明度，淺色背景用較深的色階才看得清楚）
    static func magicStops(_ theme: BrandPalette.Theme) -> [String] {
        theme == .dark ? ["#FF7AD9", "#B794FF", "#6EE7F2", "#FFE27A"] : ["#D6339F", "#7C4DDB", "#0E8FA3", "#B8860B"]
    }

    /// 字標的寬度（單位同字形座標）
    static var width: Double {
        let letters = coloredLetters.map(\.0) + ["K", "i", "t"]
        return letters.map { glyphs[$0]!.width }.reduce(0, +) + gap * Double(letters.count - 1)
    }

    /// 字標的 SVG 片段（左上角在 (0, 0)，高 100）；`id` 讓深淺兩份 SVG 的 defs 不衝突
    static func svg(_ theme: BrandPalette.Theme, id: String) -> String {
        let neutral = theme.foreground
        let stops = magicStops(theme)
        var defs = """
        <radialGradient id="\(id)-magic" cx="0.35" cy="0.3" r="0.8">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.95"/>
          <stop offset="0.25" stop-color="\(stops[0])"/>
          <stop offset="0.55" stop-color="\(stops[1])"/>
          <stop offset="0.8" stop-color="\(stops[2])"/>
          <stop offset="1" stop-color="\(stops[3])"/>
        </radialGradient>
        <radialGradient id="\(id)-halo">
          <stop offset="0" stop-color="\(stops[1])" stop-opacity="\(theme == .dark ? "0.55" : "0.35")"/>
          <stop offset="0.6" stop-color="\(stops[2])" stop-opacity="\(theme == .dark ? "0.18" : "0.12")"/>
          <stop offset="1" stop-color="\(stops[2])" stop-opacity="0"/>
        </radialGradient>
        <filter id="\(id)-glow" x="-1" y="-1" width="3" height="3"><feGaussianBlur stdDeviation="6"/></filter>

        """
        var body = ""
        var x = 0.0
        let letters: [(String, String?)] = coloredLetters.map { ($0.0, BrandPalette.color($0.1, theme).hex) } + [("K", nil), ("i", nil), ("t", nil)]
        for (index, (letter, color)) in letters.enumerated() {
            let glyph = glyphs[letter]!
            let fill = color ?? neutral
            let isKitI = index == letters.count - 2
            if letter == "o", let color {
                // 右手食指：克制的點擊光暈。只在筆畫外側（模糊的筆畫＋一圈淡漣漪），字母內部保持乾淨、不影響閱讀
                body += "<ellipse cx=\"\(fmt(x + 28))\" cy=\"67\" rx=\"28\" ry=\"33\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(fmt(stroke))\" stroke-opacity=\"\(theme == .dark ? "0.6" : "0.4")\" filter=\"url(#\(id)-glow)\"/>\n"
                body += "<ellipse cx=\"\(fmt(x + 28))\" cy=\"67\" rx=\"45\" ry=\"50\" fill=\"none\" stroke=\"\(color)\" stroke-opacity=\"\(theme == .dark ? "0.3" : "0.25")\" stroke-width=\"2.5\"/>\n"
            }
            body += "<g transform=\"translate(\(fmt(x)) 0)\" fill=\"none\" stroke=\"\(fill)\" stroke-width=\"\(fmt(stroke))\" stroke-linecap=\"round\" stroke-linejoin=\"round\">"
            body += glyph.paths.map { "<path d=\"\($0)\"/>" }.joined()
            body += "</g>\n"
            if let dot = glyph.dot {
                let cx = x + dot.x
                if isKitI {
                    // Kit 的 i：虹彩光點（光暈 → 漸層球 → 細邊 → 高光）；比一般的 i 點大，讓「點下去的一擊」有存在感，但不碰到相鄰的 K、t
                    body += "<circle cx=\"\(fmt(cx))\" cy=\"10\" r=\"30\" fill=\"url(#\(id)-halo)\"/>\n"
                    body += "<circle cx=\"\(fmt(cx))\" cy=\"10\" r=\"13.5\" fill=\"url(#\(id)-magic)\" fill-opacity=\"0.92\"/>\n"
                    body += "<circle cx=\"\(fmt(cx))\" cy=\"10\" r=\"13.5\" fill=\"none\" stroke=\"\(stops[1])\" stroke-opacity=\"\(theme == .dark ? "0.5" : "0.55")\" stroke-width=\"1.5\"/>\n"
                    body += "<circle cx=\"\(fmt(cx - 4))\" cy=\"6\" r=\"3.5\" fill=\"#FFFFFF\" fill-opacity=\"0.9\"/>\n"
                } else {
                    body += "<circle cx=\"\(fmt(cx))\" cy=\"10\" r=\"\(fmt(dot.radius))\" fill=\"\(fill)\"/>\n"
                }
            }
            x += glyph.width + gap
        }
        defs = "<defs>\n" + defs + "</defs>\n"
        return defs + body
    }

    static func fmt(_ v: Double) -> String { BrandIcon.fmt(CGFloat(v)) }
}
