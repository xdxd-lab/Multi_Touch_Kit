// mtk-art：產生 MultiTouchKit 的品牌素材（開發用；由 scripts/generate-art.sh 執行，產出的檔案會 commit）。
// 所有素材都由 MultiTouchKitArt 的同一份幾何以程式繪製，不使用外部授權素材，可完全重現。
import CoreGraphics
import Foundation
import ImageIO
import MultiTouchKitArt
import UniformTypeIdentifiers

@main
struct ArtCommand {
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        guard let root = arguments.first else {
            print("用法：mtk-art 專案根目錄")
            exit(2)
        }
        let base = URL(fileURLWithPath: root)
        let brand = base.appendingPathComponent("Assets/Brand")
        let iconset = brand.appendingPathComponent("MultiTouchKit.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        // macOS .icns 需要的尺寸（iconutil 的命名規則）；32 px 以下改用精簡版，避免細節糊成一團
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let pixels = points * scale
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            // 16、32 pt（含 @2x）用小尺寸專屬版：系統設定的清單、Finder 列表顯示的就是這些尺寸
            try writePNG(BrandIcon.image(size: pixels, compact: points <= 32), to: iconset.appendingPathComponent(name))
        }
        try writePNG(BrandIcon.image(size: 1024), to: brand.appendingPathComponent("MultiTouchKit-1024.png"))
        try write(BrandIcon.svg(), to: brand.appendingPathComponent("MultiTouchKit.svg"))
        // README banner（自帶深色底板，單一檔案；改檔名可避開 GitHub 的圖片快取）
        try write(BrandIcon.bannerSVG(), to: brand.appendingPathComponent("banner.svg"))
        // 網頁範例的 favicon：分頁列只有 16–32 px，用小尺寸專屬版（五個點、無擴散圈）；PNG 給不支援 SVG favicon 的情況，
        // apple-touch-icon（180 px，加到 iOS 主畫面等）用完整版
        let web = base.appendingPathComponent("Examples/web")
        try write(BrandIcon.svg(compact: true), to: web.appendingPathComponent("favicon.svg"))
        try writePNG(BrandIcon.image(size: 16, compact: true), to: web.appendingPathComponent("favicon-16.png"))
        try writePNG(BrandIcon.image(size: 32, compact: true), to: web.appendingPathComponent("favicon-32.png"))
        try writePNG(BrandIcon.image(size: 180), to: web.appendingPathComponent("apple-touch-icon.png"))
        try write(BrandPalette.css(), to: web.appendingPathComponent("brand.css"))
        // Unity：MultiTouchKitManager 元件在 Inspector／Add Component 中的圖示
        try writePNG(BrandIcon.image(size: 128), to: base.appendingPathComponent(
            "Unity/com.xdxd-lab.multitouchkit/Editor/Icons/MultiTouchKitManager.png"))
        print("字標與背景的 WCAG 對比（目標 ≥ 4.5:1）：\n" + BrandPalette.contrastReport())
        print("已輸出 \(brand.path)（iconset、1024 PNG、SVG、banner）、Examples/web/favicon.svg、Unity 元件圖示")
    }

    static func writePNG(_ image: CGImage?, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
