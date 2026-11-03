import SwiftUI

/// 1px divider using Border/Subtle.
struct DSDivider: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(DSColor.borderSubtle)
            .frame(width: axis == .vertical ? DSStroke.default : nil, height: axis == .horizontal ? DSStroke.default : nil)
    }
}

/// Figma "Search Field" (142:76): a pill with a ⌘K badge when empty; while searching it shows the
/// match count, previous/next and clear (State=Results), or a red "No results" (State=No results).
struct DSSearchField: View {
    @Binding var text: String
    var placeholder: CopyKey = .search
    var matchLabel: String?
    var noResults = false
    var focusRequest = 0
    /// The ⌘K hint (Search Field "Show shortcut"); off where ⌘K doesn't focus this field.
    var showsShortcutHint = true
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onSubmit: () -> Void = {}
    @Environment(\.appLanguage) private var language
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: DSSpace.s8) {
            DSIcon.search.image(size: 20).foregroundColor(DSColor.textSecondary)
            TextField(CopyCatalog.shared.string(placeholder, language), text: $text)
                .textFieldStyle(.plain)
                .dsText(.body)
                .focused($isFocused)
                .onSubmit(onSubmit)
            if text.isEmpty, showsShortcutHint {
                Text("⌘K")
                    .font(.custom("Inter-SemiBold", fixedSize: 11))
                    .foregroundColor(DSColor.textPrimary)
                    .padding(.horizontal, DSSpace.s6)
                    .padding(.vertical, DSSpace.s2)
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.xs).strokeBorder(DSColor.textPrimary, lineWidth: DSStroke.default))
                    .padding(.trailing, DSSpace.s8)
            } else if !text.isEmpty {
                if noResults {
                    DSLabel(.noResults, style: .caption).foregroundColor(DSColor.statusDanger).fixedSize()
                } else if let matchLabel {
                    Text(matchLabel).dsText(.caption).foregroundColor(DSColor.textSecondary).fixedSize()
                    DSIconButton(.up, size: 24, action: onPrevious).dsTooltip(.previousMatch, shortcut: "⇧⌘G")
                    DSIconButton(.down, size: 24, action: onNext).dsTooltip(.nextMatch, shortcut: "⌘G")
                }
                DSIconButton(.close, size: 24) { text = "" }.dsTooltip(.clearSearch)
            }
        }
        .padding(.leading, DSSpace.s12)
        .padding(.trailing, DSSpace.s4)
        .frame(height: 36)
        .background(Capsule().fill(DSColor.backgroundSurface))
        .overlay(Capsule().strokeBorder(noResults ? DSColor.statusDanger : DSColor.borderDefault, lineWidth: DSStroke.default))
        .onChange(of: focusRequest) { _ in isFocused = true }
    }
}

/// Figma "Checkbox" (95:49): 16 pt box, radius 4; On = Accent fill with a white check.
struct DSCheckbox: View {
    let label: CopyKey?
    /// A label already in the interface language (e.g. “Table 1 · page 1”).
    var text: String?
    @Binding var isOn: Bool

    init(label: CopyKey, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    init(text: String, isOn: Binding<Bool>) {
        label = nil
        self.text = text
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: DSSpace.s8) {
                ZStack {
                    RoundedRectangle(cornerRadius: DSRadius.xs).fill(isOn ? DSColor.accentDefault : DSColor.backgroundSurface)
                    if isOn {
                        DSIcon.check.image(size: 12).foregroundColor(DSColor.textOnAccent)
                    } else {
                        RoundedRectangle(cornerRadius: DSRadius.xs).strokeBorder(DSColor.borderStrong, lineWidth: DSStroke.default)
                    }
                }
                .frame(width: 16, height: 16)
                if let label {
                    DSLabel(label, style: .body).foregroundColor(DSColor.textPrimary)
                } else {
                    Text(text ?? "").dsText(.body).foregroundColor(DSColor.textPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Figma "Language Switch" (179:633). Labels are fixed: ខ្មែរ is always Khmer, English always English.
struct LanguageSwitch: View {
    @Binding var language: AppLanguage

    var body: some View {
        HStack(spacing: DSSpace.s2) {
            segment(.km, label: "ខ្មែរ", font: "NotoSansKhmer-Medium")
            segment(.en, label: "English", font: "Inter-Medium")
        }
        .padding(DSSpace.s2)
        .background(Capsule().fill(DSColor.backgroundHover))
    }

    private func segment(_ value: AppLanguage, label: String, font: String) -> some View {
        Button { language = value } label: {
            Text(label)
                .font(.custom(font, fixedSize: 11))
                .foregroundColor(value == .km ? DSLanguageColor.controlLanguageKhmerLabel(language) : DSLanguageColor.controlLanguageEnglishLabel(language))
                .padding(.horizontal, DSSpace.s8)
                .frame(height: 24)
                .background(Capsule().fill(value == .km ? DSLanguageColor.controlLanguageKhmerSegment(language) : DSLanguageColor.controlLanguageEnglishSegment(language)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Figma "Theme Switch" (179:606): light / dark segments.
struct ThemeSwitch: View {
    @Binding var appearance: AppearancePreference
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: DSSpace.s2) {
            segment(.light, icon: .sun, fill: DSColor.controlThemeLightSegment)
            segment(.dark, icon: .moon, fill: DSColor.controlThemeDarkSegment)
        }
        .padding(DSSpace.s2)
        .background(Capsule().fill(DSColor.backgroundHover))
    }

    private func segment(_ value: AppearancePreference, icon: DSIcon, fill: Color) -> some View {
        Button { appearance = value } label: {
            icon.image(size: 14)
                .foregroundColor(DSColor.textPrimary)
                .frame(width: 28, height: 24)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Figma "Toggle Icon Button" (123:36): 28 pt on/off formatting control (bold, italic, underline, alignment).
/// On = Background/Selected with an accent icon. Alignment toggles are used as a radio group by the caller.
struct DSToggleIconButton: View {
    let icon: DSIcon
    let label: CopyKey
    let isOn: Bool
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            icon.image(size: 16)
                .foregroundColor(isOn ? DSColor.textAccent : DSColor.textPrimary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: DSRadius.sm)
                    .fill(isOn ? DSColor.backgroundSelected : isHovered && isEnabled ? DSColor.backgroundHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .dsTooltip(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Figma "Color Swatch" (123:62): 24 pt document colour with a Border/Subtle edge; Selected = 2 pt accent ring.
/// Always named (tooltip and VoiceOver), never colour alone.
struct DSColorSwatch: View {
    let color: Color
    let name: CopyKey
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Circle().fill(color)
                .overlay(Circle().strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(DSColor.accentDefault, lineWidth: DSStroke.focus).padding(-4).opacity(isSelected ? 1 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .dsTooltip(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
