import AppKit
import SwiftUI

/// One resolved Figma text style for one language.
struct DSTextSpec: Equatable, Sendable {
    let postScriptName: String
    let size: CGFloat
    /// Figma line height in points. Figma centres glyphs in this box (half the extra above, half below).
    let lineHeight: CGFloat

    var nsFont: NSFont {
        if let font = NSFont(name: postScriptName, size: size) { return font }
        assertionFailure("Font \(postScriptName) is not registered")
        return .systemFont(ofSize: size)
    }

    /// Natural line height of the font (ascender + descender + leading).
    var naturalLineHeight: CGFloat {
        let font = nsFont
        return ceil(font.ascender - font.descender + font.leading)
    }

    /// Extra space SwiftUI must add to reach the Figma line height.
    var extraLeading: CGFloat { lineHeight - naturalLineHeight }
}

private struct DSTextModifier: ViewModifier {
    let style: DSTextStyle
    @Environment(\.appLanguage) private var language

    func body(content: Content) -> some View {
        let spec = style.spec(for: language)
        let extra = spec.extraLeading
        // lineSpacing only adds space between lines; split the remainder above/below like Figma.
        // When the font is taller than the Figma box (extra < 0) keep the natural height so
        // Khmer stacked consonants and vowels are never clipped.
        content
            .font(.custom(spec.postScriptName, fixedSize: spec.size))
            .lineSpacing(max(0, extra))
            .padding(.vertical, max(0, extra) / 2)
    }
}

extension View {
    /// Applies a Figma text style for the current interface language.
    func dsText(_ style: DSTextStyle) -> some View {
        modifier(DSTextModifier(style: style))
    }
}

/// Localized, styled text: `Copy/<key>` in the current language with a Figma text style.
struct DSLabel: View {
    let key: CopyKey
    var style: DSTextStyle = .body
    @Environment(\.appLanguage) private var language

    init(_ key: CopyKey, style: DSTextStyle = .body) {
        self.key = key
        self.style = style
    }

    var body: some View {
        Text(CopyCatalog.shared.string(key, language)).dsText(style)
    }
}
