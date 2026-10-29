import CoreGraphics
import Foundation

/// 「MultiTouchKit」字標：單線圓角筆畫的幾何字形（以路徑繪製，不使用字型：沒有授權問題，各平台呈現一致）。
///
/// 概念：「MultiTouch」10 個字母 = 10 根手指。Multi = 左手（M 小指 → i 拇指），Touch = 右手（T 拇指 → h 小指），
/// 左右鏡像同色：M↔h 小指、u↔c 無名指、l↔u 中指、t↔o 食指、i↔T 拇指，顏色與圖示的五個指尖相同（BrandPalette）。
/// 右手食指的「o」帶一點點擊光暈，呼應圖示中按下的那根食指。
/// 「Kit」使用暖色魔法漸層（與魔法棒光點同一組色），i 是魔法棒：棒身加上尖端的虹彩光球與星芒，象徵節奏遊戲中點下去的那一擊。
/// 顏色依背景取 BrandPalette 的深色或淺色色階。
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

    /// Kit 暖色魔法漸層的色相（琥珀金 → 珊瑚 → 洋紅 → 紫），從 K 到 t 明顯變化。
    /// 起點用琥珀金：緊鄰的 h 是小指粉，K 若從粉紅系起始，h 與 K 會糊成一塊、看不出 MultiTouch 與 Kit 的分界
    static let kitHues: [CGFloat] = [42, 10, 325, 278]
    /// Kit 漸層比五指更飽和，讓魔法感更強烈
    static let kitSaturation = 0.9
    /// MultiTouch 與 Kit 之間額外的字距
    static let kitSpacing = 6.0

    /// 字標的寬度（單位同字形座標）
    static var width: Double {
        let letters = coloredLetters.map(\.0) + ["K", "i", "t"]
        return letters.map { glyphs[$0]!.width }.reduce(0, +) + gap * Double(letters.count - 1) + kitSpacing
    }

    /// 把絕對座標的路徑資料（M、L、H、V、A、Z）水平平移 dx
    static func offset(_ path: String, by dx: Double) -> String {
        var out = ""
        var command: Character = "M"
        var argument = 0
        var number = ""
        func flush() {
            guard !number.isEmpty, let v = Double(number) else { return }
            // 各指令中的 x 參數：M／L 的第 1 個、H 的唯一一個、A 的第 6 個（每組 7 個）
            let isX: Bool
            switch command {
            case "M", "L": isX = argument % 2 == 0
            case "H": isX = true
            case "A": isX = argument % 7 == 5
            default: isX = false
            }
            out += (out.last.map { $0.isLetter } ?? true ? "" : " ") + fmt(isX ? v + dx : v)
            argument += 1
            number = ""
        }
        for ch in path {
            if ch.isLetter {
                flush()
                command = ch
                argument = 0
                out.append(ch)
            } else if ch == " " || ch == "," {
                flush()
            } else if ch == "-" && !number.isEmpty {
                flush()
                number.append(ch)
            } else {
                number.append(ch)
            }
        }
        flush()
        return out
    }

    /// 四芒星（星芒）：長半徑 r、腰半徑 w
    static func sparkle(_ cx: Double, _ cy: Double, _ r: Double, _ w: Double) -> String {
        "M\(fmt(cx)) \(fmt(cy - r))L\(fmt(cx + w)) \(fmt(cy - w))L\(fmt(cx + r)) \(fmt(cy))L\(fmt(cx + w)) \(fmt(cy + w))"
            + "L\(fmt(cx)) \(fmt(cy + r))L\(fmt(cx - w)) \(fmt(cy + w))L\(fmt(cx - r)) \(fmt(cy))L\(fmt(cx - w)) \(fmt(cy - w))Z"
    }

    /// 字標的 SVG 片段（左上角在 (0, 0)，高 100）；`id` 讓深淺兩份 SVG 的 defs 不衝突
    static func svg(_ theme: BrandPalette.Theme, id: String) -> String {
        let kit = BrandPalette.kitColors(theme).map(\.hex)
        // Kit 三個字母的位置（漸層橫跨整個 Kit）
        let kitStart = coloredLetters.map { glyphs[$0.0]!.width + gap }.reduce(0, +) + kitSpacing
        let kitEnd = kitStart + glyphs["K"]!.width + gap + glyphs["i"]!.width + gap + glyphs["t"]!.width
        var defs = """
        <linearGradient id="\(id)-kit" gradientUnits="userSpaceOnUse" x1="\(fmt(kitStart - 7))" y1="0" x2="\(fmt(kitEnd + 7))" y2="0">
          <stop offset="0.05" stop-color="\(kit[0])"/><stop offset="0.37" stop-color="\(kit[1])"/>
          <stop offset="0.68" stop-color="\(kit[2])"/><stop offset="0.95" stop-color="\(kit[3])"/>
        </linearGradient>
        <radialGradient id="\(id)-orb" cx="0.38" cy="0.32" r="0.75">
          <stop offset="0" stop-color="#FFFFFF"/><stop offset="0.25" stop-color="\(kit[0])"/>
          <stop offset="0.6" stop-color="\(kit[1])"/><stop offset="1" stop-color="\(kit[2])"/>
        </radialGradient>
        <radialGradient id="\(id)-halo">
          <stop offset="0" stop-color="\(kit[0])" stop-opacity="0.5"/><stop offset="0.55" stop-color="\(kit[2])" stop-opacity="0.18"/>
          <stop offset="1" stop-color="\(kit[3])" stop-opacity="0"/>
        </radialGradient>
        <filter id="\(id)-glow" x="-1" y="-1" width="3" height="3"><feGaussianBlur stdDeviation="6"/></filter>

        """
        var body = ""
        var x = 0.0
        let letters: [(String, String?)] = coloredLetters.map { ($0.0, BrandPalette.color($0.1, theme).hex) } + [("K", nil), ("i", nil), ("t", nil)]
        for (index, (letter, color)) in letters.enumerated() {
            let glyph = glyphs[letter]!
            let stroke = color ?? "url(#\(id)-kit)"
            let isWand = index == letters.count - 2
            if letter == "o", let color {
                // 右手食指：克制的點擊光暈。只在筆畫外側（模糊的筆畫＋一圈淡漣漪），字母內部保持乾淨、不影響閱讀
                body += "<ellipse cx=\"\(fmt(x + 28))\" cy=\"67\" rx=\"28\" ry=\"33\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(fmt(Self.stroke))\" stroke-opacity=\"0.45\" filter=\"url(#\(id)-glow)\"/>\n"
                body += "<ellipse cx=\"\(fmt(x + 28))\" cy=\"67\" rx=\"45\" ry=\"50\" fill=\"none\" stroke=\"\(color)\" stroke-opacity=\"0.35\" stroke-width=\"2.5\"/>\n"
            }
            if isWand {
                // Kit 的 i = 魔法棒：略向右傾的棒身，尖端是虹彩光球、四芒星芒與兩顆小星（點下去的神奇一擊）。
                // 棒身仍在 x 字高範圍、光球在 i 點的位置，所以一眼仍讀成 i
                body += "<path d=\"M\(fmt(x - 4)) 100L\(fmt(x + 4)) 36\" fill=\"none\" stroke=\"\(stroke)\" stroke-width=\"\(fmt(Self.stroke))\" stroke-linecap=\"round\"/>\n"
                let cx = x + 6, cy = 10.0
                body += "<circle cx=\"\(fmt(cx))\" cy=\"\(fmt(cy))\" r=\"32\" fill=\"url(#\(id)-halo)\"/>\n"
                body += "<path d=\"\(sparkle(cx, cy, 30, 3.2))\" fill=\"\(kit[0])\" fill-opacity=\"0.9\"/>\n"
                body += "<circle cx=\"\(fmt(cx))\" cy=\"\(fmt(cy))\" r=\"13.5\" fill=\"url(#\(id)-orb)\"/>\n"
                body += "<circle cx=\"\(fmt(cx))\" cy=\"\(fmt(cy))\" r=\"13.5\" fill=\"none\" stroke=\"\(kit[1])\" stroke-width=\"1.5\"/>\n"
                body += "<circle cx=\"\(fmt(cx - 4))\" cy=\"\(fmt(cy - 4))\" r=\"3.5\" fill=\"#FFFFFF\" fill-opacity=\"0.9\"/>\n"
                body += "<path d=\"\(sparkle(cx + 24, cy - 18, 7, 1.6))\" fill=\"\(kit[1])\"/>\n"
                body += "<path d=\"\(sparkle(cx - 19, cy - 20, 5, 1.2))\" fill=\"\(kit[3])\"/>\n"
            } else {
                let attributes = "fill=\"none\" stroke=\"\(stroke)\" stroke-width=\"\(fmt(Self.stroke))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
                if color == nil {
                    // Kit 的漸層以字標座標（userSpaceOnUse）定義，而 transform 會改變該座標系：直接平移路徑資料，
                    // 三個字母才會共用同一段連續的漸層
                    body += "<g \(attributes)>" + glyph.paths.map { "<path d=\"\(offset($0, by: x))\"/>" }.joined()
                } else {
                    body += "<g transform=\"translate(\(fmt(x)) 0)\" \(attributes)>" + glyph.paths.map { "<path d=\"\($0)\"/>" }.joined()
                }
                body += "</g>\n"
                if let dot = glyph.dot {
                    body += "<circle cx=\"\(fmt(x + dot.x))\" cy=\"10\" r=\"\(fmt(dot.radius))\" fill=\"\(color ?? kit[1])\"/>\n"
                }
            }
            x += glyph.width + gap
            if index == coloredLetters.count - 1 { x += kitSpacing }
        }
        defs = "<defs>\n" + defs + "</defs>\n"
        return defs + body
    }

    static func fmt(_ v: Double) -> String { BrandIcon.fmt(CGFloat(v)) }
}
