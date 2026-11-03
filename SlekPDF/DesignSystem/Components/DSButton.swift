import SwiftUI

/// Figma "Button" (86:390): text buttons are pills (Radius/Full).
/// Style = Primary / Secondary / Plain / Destructive; Size = Regular / Small.
struct DSButton: View {
    enum Style { case primary, secondary, plain, destructive }
    enum Size { case regular, small }

    /// A copy key, or text already in the interface language (file names, composed messages).
    enum Title {
        case key(CopyKey)
        case text(String)
    }

    let title: Title
    var icon: DSIcon?
    var style: Style = .secondary
    var size: Size = .regular
    var fullWidth = false
    let action: () -> Void
    @Environment(\.appLanguage) private var language

    init(_ title: CopyKey, icon: DSIcon? = nil, style: Style = .secondary, size: Size = .regular,
         fullWidth: Bool = false, action: @escaping () -> Void = {}) {
        self.init(title: .key(title), icon: icon, style: style, size: size, fullWidth: fullWidth, action: action)
    }

    init(text: String, icon: DSIcon? = nil, style: Style = .secondary, size: Size = .regular,
         fullWidth: Bool = false, action: @escaping () -> Void = {}) {
        self.init(title: .text(text), icon: icon, style: style, size: size, fullWidth: fullWidth, action: action)
    }

    private init(title: Title, icon: DSIcon?, style: Style, size: Size, fullWidth: Bool, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.size = size
        self.fullWidth = fullWidth
        self.action = action
    }

    private var titleText: String {
        switch title {
        case let .key(key): CopyCatalog.shared.string(key, language)
        case let .text(text): text
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpace.s6) {
                if let icon { icon.image() }
                Text(titleText).dsText(size == .regular ? .label : .labelSmall)
                    .lineLimit(1)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(DSButtonStyle(style: style, size: size))
    }
}

struct DSButtonStyle: ButtonStyle {
    let style: DSButton.Style
    let size: DSButton.Size
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(foreground)
            .padding(.horizontal, size == .regular ? DSSpace.s16 : DSSpace.s12)
            .frame(minHeight: size == .regular ? 32 : 24)  // Figma Button: Regular 32 / Small 24
            .background(Capsule().fill(background(pressed: configuration.isPressed)))
            .overlay(Capsule().inset(by: DSStroke.default / 2).stroke(border, lineWidth: DSStroke.default))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary, .destructive: return DSColor.textOnAccent
        case .secondary, .plain: return DSColor.textPrimary
        }
    }

    private func background(pressed: Bool) -> Color {
        let isHovered = isHovered && isEnabled
        switch style {
        case .primary: return pressed ? DSColor.accentPressed : isHovered ? DSColor.accentHover : DSColor.accentDefault
        case .destructive: return pressed ? DSColor.statusDangerPressed : isHovered ? DSColor.statusDangerHover : DSColor.statusDangerFill
        case .secondary: return pressed ? DSColor.backgroundPressed : isHovered ? DSColor.backgroundHover : DSColor.backgroundSurface
        case .plain: return pressed ? DSColor.backgroundPressed : isHovered ? DSColor.backgroundHover : .clear
        }
    }

    private var border: Color {
        style == .secondary ? DSColor.borderDefault : .clear
    }
}

/// Figma "Icon Button" (86:511): icon-only buttons are rounded squares.
struct DSIconButton: View {
    let icon: DSIcon
    var size: CGFloat = 28
    var iconSize: CGFloat = 16
    let action: () -> Void

    init(_ icon: DSIcon, size: CGFloat = 28, iconSize: CGFloat = 16, action: @escaping () -> Void = {}) {
        self.icon = icon
        self.size = size
        self.iconSize = iconSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon.image(size: iconSize)
                .foregroundColor(DSColor.textPrimary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(DSIconButtonStyle())
    }
}

private struct DSIconButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DSRadius.sm)
                    .fill(configuration.isPressed ? DSColor.backgroundPressed : isHovered ? DSColor.backgroundHover : .clear)
            )
            .onHover { isHovered = $0 }
    }
}
