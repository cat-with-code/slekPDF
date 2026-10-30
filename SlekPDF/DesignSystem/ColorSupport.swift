import AppKit

extension NSColor {
    /// sRGB colour from a 0xRRGGBBAA literal, as exported from Figma.
    convenience init(rgba: UInt32) {
        self.init(
            srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }

    /// Appearance-aware colour matching a Figma Light/Dark variable pair.
    /// Resolves against the drawing appearance, so it follows `NSApp.appearance` and per-view overrides.
    convenience init(name: String, light: UInt32, dark: UInt32) {
        let lightColor = NSColor(rgba: light)
        let darkColor = NSColor(rgba: dark)
        self.init(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}
