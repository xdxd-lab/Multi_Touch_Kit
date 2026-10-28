import AppKit

extension BrandIcon {
    /// Dock 等處使用的 NSImage（512 × 512 點，內含 1024 像素的版本）
    @MainActor
    public static var applicationIcon: NSImage {
        let image = NSImage(size: NSSize(width: 512, height: 512))
        for pixels in [512, 1024] {
            if let cgImage = BrandIcon.image(size: pixels) {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                rep.size = image.size
                image.addRepresentation(rep)
            }
        }
        return image
    }
}
