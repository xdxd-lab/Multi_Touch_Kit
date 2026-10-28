import CoreGraphics
import Foundation

/// MultiTouchKit 的品牌圖示：深色圓角方塊上的五個指尖觸點與擴散圈。
///
/// 視覺語言沿用 mtk-viewer 的觸控特效（使用者指定的基準）：觸點是半透明的彩色圓點，色相 = 觸點 id × 37°
/// （hsla(h, 70%, 55%, 0.85)），按下時的擴散圈為 hsla(h, 80%, 60%)。
/// 同一份幾何同時輸出 CoreGraphics（PNG、.icns、mtk-viewer 的 Dock 圖示）與 SVG（README、favicon），兩者保持一致。
/// 座標以 1024 × 1024 的畫布為準（y 向下），繪製時再縮放。
public enum BrandIcon {
    /// 圖示本體：macOS 圖示格線中 824 × 824 的圓角方塊，四周保留陰影空間
    public static let canvas: CGFloat = 1024
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)

    /// 一個觸點：位置、半徑、mtk-viewer 的觸點 id（決定色相）、擴散圈數
    struct Contact {
        var center: CGPoint
        var radius: CGFloat
        var id: Int
        var rings: Int
    }

    /// 五指輕觸的排列：拇指在左下，其餘四指沿弧線排開、彼此不重疊；中指帶兩圈擴散（剛按下）。
    /// id 取奇數（1、3、5、7、9）：仍是 mtk-viewer 的「id × 37°」，色相分布到橘、綠、青、紫、粉
    static let contacts: [Contact] = [
        Contact(center: CGPoint(x: 284, y: 695), radius: 70, id: 1, rings: 0),
        Contact(center: CGPoint(x: 372, y: 501), radius: 66, id: 3, rings: 0),
        Contact(center: CGPoint(x: 512, y: 417), radius: 72, id: 5, rings: 2),
        Contact(center: CGPoint(x: 652, y: 501), radius: 66, id: 7, rings: 0),
        Contact(center: CGPoint(x: 744, y: 641), radius: 58, id: 9, rings: 0),
    ]

    /// 小尺寸（favicon、16–32 px）只畫三個較大的觸點，擴散圈省略
    static let compactContacts: [Contact] = [
        Contact(center: CGPoint(x: 318, y: 600), radius: 120, id: 1, rings: 0),
        Contact(center: CGPoint(x: 512, y: 400), radius: 120, id: 5, rings: 0),
        Contact(center: CGPoint(x: 706, y: 600), radius: 120, id: 9, rings: 0),
    ]

    // 深色背景：上方略亮的炭灰漸層
    static let backgroundTop = RGB(0x24, 0x26, 0x2E)
    static let backgroundBottom = RGB(0x0B, 0x0C, 0x10)

    struct RGB {
        var r: CGFloat, g: CGFloat, b: CGFloat
        init(_ r: Int, _ g: Int, _ b: Int) {
            self.r = CGFloat(r) / 255
            self.g = CGFloat(g) / 255
            self.b = CGFloat(b) / 255
        }
        init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r
            self.g = g
            self.b = b
        }
        var hex: String { String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
    }

    /// mtk-viewer 的色相：(id × 37) mod 360
    static func hue(_ id: Int) -> CGFloat { CGFloat((id * 37) % 360) }

    /// CSS 的 hsl() → RGB（s、l 為 0...1）
    static func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat) -> RGB {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return RGB(r: r + m, g: g + m, b: b + m)
    }

    static func fillColor(_ id: Int) -> RGB { hsl(hue(id), 0.70, 0.55) }
    static func ringColor(_ id: Int) -> RGB { hsl(hue(id), 0.80, 0.60) }

    /// 擴散圈 k（從 1 起）的半徑與透明度：越外圈越淡
    static func ring(_ k: Int, of contact: Contact) -> (radius: CGFloat, alpha: CGFloat) {
        (contact.radius * (1.0 + 0.62 * CGFloat(k)), 0.62 - 0.22 * CGFloat(k))
    }

    // MARK: - CoreGraphics

    /// 以 `size` × `size` 像素繪製（透明背景、sRGB、預乘 alpha）。`compact` 用於 16–32 px
    public static func image(size: Int, compact: Bool = false) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(in: context, size: CGFloat(size), compact: compact)
        return context.makeImage()
    }

    /// 在 context 的 (0, 0)–(size, size) 繪製（context 為 CoreGraphics 預設的 y 向上座標）
    public static func draw(in context: CGContext, size: CGFloat, compact: Bool = false) {
        context.saveGState()
        // 轉成 y 向下、1024 單位的座標，與 SVG 相同
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: size / canvas, y: -size / canvas)

        let bodyPath = bodyPath()
        // 圖示下方的柔和陰影（Apple 圖示範本；macOS 26 也接受，並另外加上玻璃邊緣）
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 14), blur: 36, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(bodyPath)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(bodyPath)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            cgColor(backgroundTop, 1), cgColor(backgroundBottom, 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
        // 先畫所有擴散圈，再畫圓點：擴散圈在其他觸點的下方
        let list = compact ? compactContacts : contacts
        for contact in list {
            for k in stride(from: contact.rings, through: 1, by: -1) {
                let ring = ring(k, of: contact)
                context.setStrokeColor(cgColor(ringColor(contact.id), ring.alpha))
                context.setLineWidth(9)
                context.strokeEllipse(in: circle(contact.center, ring.radius))
            }
        }
        for contact in list {
            let color = fillColor(contact.id)
            context.saveGState()
            context.setShadow(offset: .zero, blur: contact.radius * 0.6, color: cgColor(color, 0.45))
            context.setFillColor(cgColor(color, 0.85))
            context.fillEllipse(in: circle(contact.center, contact.radius))
            context.restoreGState()
        }
        context.restoreGState()

        // 內緣細線：深色 Dock 背景上仍看得出輪廓
        context.addPath(Self.bodyPath(inset: 1.5))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        context.setLineWidth(3)
        context.strokePath()
        context.restoreGState()
    }

    /// 圖示外形：Apple 圖示範本的圓角方塊（824、圓角 185.4）。macOS 26 依外形判斷舊式圖示：輪廓與系統遮罩相符才直接顯示，
    /// 否則放進灰色外框。曾改用 superellipse（n=5）就被加上外框；以只有 .icns 的第三方 App 實測，系統遮罩的輪廓與半徑 185 的圓角相差不到 2 px
    static let cornerRadius: CGFloat = 185.4

    static func bodyPath(inset: CGFloat = 0) -> CGPath {
        CGPath(roundedRect: body.insetBy(dx: inset, dy: inset), cornerWidth: cornerRadius - inset, cornerHeight: cornerRadius - inset, transform: nil)
    }

    static func bodySVGRect(inset: CGFloat = 0) -> String {
        let r = body.insetBy(dx: inset, dy: inset)
        return "x=\"\(fmt(r.minX))\" y=\"\(fmt(r.minY))\" width=\"\(fmt(r.width))\" height=\"\(fmt(r.height))\" rx=\"\(fmt(cornerRadius - inset))\""
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    static func cgColor(_ c: RGB, _ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    // MARK: - SVG

    /// 圖示本體的 SVG 片段（座標 0–1024）；`idPrefix` 讓同一份 SVG 中可以放多個圖示而不衝突
    static func svgBody(compact: Bool = false, idPrefix: String = "mtk") -> String {
        var s = """
        <defs>
          <linearGradient id="\(idPrefix)-bg" x1="0" y1="\(Int(body.minY))" x2="0" y2="\(Int(body.maxY))" gradientUnits="userSpaceOnUse">
            <stop offset="0" stop-color="\(backgroundTop.hex)"/><stop offset="1" stop-color="\(backgroundBottom.hex)"/>
          </linearGradient>
          <clipPath id="\(idPrefix)-clip"><rect \(bodySVGRect())/></clipPath>

        """
        let list = compact ? compactContacts : contacts
        for c in list {
            s += """
              <filter id="\(idPrefix)-glow\(c.id)" x="-1" y="-1" width="3" height="3"><feGaussianBlur stdDeviation="\(fmt(c.radius * 0.3))"/></filter>

            """
        }
        s += "</defs>\n"
        s += """
        <rect \(bodySVGRect()) fill="url(#\(idPrefix)-bg)"/>
        <g clip-path="url(#\(idPrefix)-clip)">

        """
        for c in list {
            for k in stride(from: c.rings, through: 1, by: -1) {
                let r = ring(k, of: c)
                s += "  <circle cx=\"\(fmt(c.center.x))\" cy=\"\(fmt(c.center.y))\" r=\"\(fmt(r.radius))\" fill=\"none\" stroke=\"\(ringColor(c.id).hex)\" stroke-opacity=\"\(fmt(r.alpha))\" stroke-width=\"9\"/>\n"
            }
        }
        for c in list {
            let fill = fillColor(c.id).hex
            s += "  <circle cx=\"\(fmt(c.center.x))\" cy=\"\(fmt(c.center.y))\" r=\"\(fmt(c.radius))\" fill=\"\(fill)\" fill-opacity=\"0.45\" filter=\"url(#\(idPrefix)-glow\(c.id))\"/>\n"
            s += "  <circle cx=\"\(fmt(c.center.x))\" cy=\"\(fmt(c.center.y))\" r=\"\(fmt(c.radius))\" fill=\"\(fill)\" fill-opacity=\"0.85\"/>\n"
        }
        s += "</g>\n"
        s += "<rect \(bodySVGRect(inset: 1.5)) fill=\"none\" stroke=\"#FFFFFF\" stroke-opacity=\"0.10\" stroke-width=\"3\"/>\n"
        return s
    }

    /// 獨立的 SVG 圖示（README logo、favicon）
    public static func svg(compact: Bool = false) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
        <title>MultiTouchKit</title>
        \(svgBody(compact: compact))</svg>

        """
    }

    /// README 頂部的 banner：左側圖示、右側字標與說明。`dark` 決定文字顏色（背景透明，配合 GitHub 的深淺色主題）
    public static func bannerSVG(dark: Bool) -> String {
        let title = dark ? "#F0F3F6" : "#1F2328"
        let subtitle = dark ? "#9198A1" : "#59636E"
        // 字標的強調色 = 圖示主角（中指、帶擴散圈）的色相；淺色背景用較深的亮度以維持對比
        let hero = contacts.first { $0.rings > 0 }!.id
        let accent = (dark ? fillColor(hero) : hsl(hue(hero), 0.70, 0.40)).hex
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 320" width="1280" height="320">
        <title>MultiTouchKit</title>
        <g transform="translate(40 32) scale(0.25)">
        \(svgBody(idPrefix: dark ? "d" : "l"))</g>
        <g font-family="-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', 'PingFang TC', 'Noto Sans TC', Helvetica, Arial, sans-serif">
          <text x="336" y="150" font-size="88" font-weight="700" letter-spacing="-1.5" fill="\(title)">Multi<tspan fill="\(accent)">Touch</tspan>Kit</text>
          <text x="340" y="212" font-size="30" font-weight="500" fill="\(subtitle)">macOS 10 點觸控螢幕 · Swift · C · Unity · WebSocket</text>
        </g>
        </svg>

        """
    }

    static func fmt(_ v: CGFloat) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(format: "%g", Double(r))
    }
}
