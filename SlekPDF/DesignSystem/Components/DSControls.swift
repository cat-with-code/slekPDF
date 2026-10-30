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
            if text.isEmpty {
                Text("⌘K")
                    .font(.custom("Inter-SemiBold", fixedSize: 11))
                    .foregroundColor(DSColor.textPrimary)
                    .padding(.horizontal, DSSpace.s6)
                    .padding(.vertical, DSSpace.s2)
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.xs).strokeBorder(DSColor.textPrimary, lineWidth: DSStroke.default))
                    .padding(.trailing, DSSpace.s8)
            } else {
                if noResults {
                    DSLabel(.noResults, style: .caption).foregroundColor(DSColor.statusDanger).fixedSize()
                } else if let matchLabel {
                    Text(matchLabel).dsText(.caption).foregroundColor(DSColor.textSecondary).fixedSize()
                    DSIconButton(.up, size: 24, action: onPrevious).help(CopyCatalog.shared.string(.previousMatch, language))
                    DSIconButton(.down, size: 24, action: onNext).help(CopyCatalog.shared.string(.nextMatch, language))
                }
                DSIconButton(.close, size: 24) { text = "" }.help(CopyCatalog.shared.string(.clearSearch, language))
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
    let label: CopyKey
    @Binding var isOn: Bool

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
                DSLabel(label, style: .body).foregroundColor(DSColor.textPrimary)
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
