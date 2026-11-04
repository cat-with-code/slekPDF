import SwiftUI

/// Figma "Switch" (140:36): macOS-style toggle for settings that apply at once (Preferences). 32×18 track,
/// 14 pt knob with Elevation/1; Off = Background/Pressed (Border/Strong on hover), On = Accent (Accent/Hover);
/// focus ring for the keyboard, Space toggles.
struct DSSwitch: View {
    let label: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            HStack(spacing: DSSpace.s8) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(trackColor)
                    if !isOn { Capsule().strokeBorder(DSColor.borderDefault, lineWidth: 0.5) }
                    Circle().fill(DSColor.textOnAccent)
                        .frame(width: 14, height: 14)
                        .dsElevation(isEnabled ? .raised : .flat)
                        .padding(2)
                }
                .frame(width: 32, height: 18)
                .overlay(Capsule().strokeBorder(DSColor.borderFocus, lineWidth: DSStroke.focus).padding(-3).opacity(isFocused ? 1 : 0))
                Text(label).dsText(.body).foregroundColor(isEnabled ? DSColor.textPrimary : DSColor.textDisabled)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityValue(isOn ? "1" : "0")
    }

    private var trackColor: Color {
        switch (isOn, isEnabled) {
        case (true, true): isHovered ? DSColor.accentHover : DSColor.accentDefault
        case (true, false): DSColor.backgroundPressed
        case (false, true): isHovered ? DSColor.borderStrong : DSColor.backgroundPressed
        case (false, false): DSColor.backgroundDisabled
        }
    }
}

/// Figma "Badge" (89:32): short honest-state label ("Preview build", "Uncertain", "Reviewed"). Subtle (default)
/// or Solid; a 6 pt dot in the label colour; never colour alone.
struct DSBadge: View {
    enum Tone { case neutral, accent, success, warning, danger }
    enum Style { case subtle, solid }

    let label: String
    var tone: Tone = .neutral
    var style: Style = .subtle
    var showsDot = true

    var body: some View {
        HStack(spacing: DSSpace.s4) {
            if showsDot { Circle().fill(foreground).frame(width: 6, height: 6) }
            Text(label).dsText(.labelSmall).foregroundColor(foreground).lineLimit(1)
        }
        .padding(.horizontal, DSSpace.s8)
        .padding(.vertical, DSSpace.s2)
        .background(Capsule().fill(background))
        .fixedSize()
    }

    private var foreground: Color {
        switch (style, tone) {
        case (.solid, .accent): DSColor.textOnAccent
        case (.solid, _): DSColor.textOnStatus
        case (.subtle, .neutral): DSColor.textSecondary
        case (.subtle, .accent): DSColor.textAccent
        case (.subtle, .success): DSColor.statusSuccess
        case (.subtle, .warning): DSColor.statusWarning
        case (.subtle, .danger): DSColor.statusDanger
        }
    }

    private var background: Color {
        switch (style, tone) {
        case (.subtle, .neutral): DSColor.backgroundHover
        case (.subtle, .accent): DSColor.accentSubtle
        case (.subtle, .success): DSColor.statusSuccessSubtle
        case (.subtle, .warning): DSColor.statusWarningSubtle
        case (.subtle, .danger): DSColor.statusDangerSubtle
        case (.solid, .neutral): DSColor.textSecondary
        case (.solid, .accent): DSColor.accentDefault
        case (.solid, .success): DSColor.statusSuccess
        case (.solid, .warning): DSColor.statusWarning
        case (.solid, .danger): DSColor.statusDangerFill
        }
    }
}

/// Figma "Tab" (98:64), Style=Segmented, in a segmented control: 28 pt pills on a Background/Hover track;
/// Selected = Background/Surface with Elevation/1 and Body Strong; Hover = Background/Pressed.
/// For switching views inside a panel (Word preview / Excel preview).
struct DSSegmentedControl<Value: Hashable>: View {
    struct Segment {
        let value: Value
        let title: String
        var icon: DSIcon?
    }

    @Binding var selection: Value
    let segments: [Segment]
    /// Segments share the full width (tabs at the top of a panel).
    var fillsWidth = false

    var body: some View {
        HStack(spacing: DSSpace.s2) {
            ForEach(segments, id: \.value) { segment in
                SegmentButton(segment: segment, isSelected: segment.value == selection, fillsWidth: fillsWidth) { selection = segment.value }
            }
        }
        .padding(DSSpace.s2)
        .background(Capsule().fill(DSColor.backgroundHover))
    }

    private struct SegmentButton: View {
        let segment: Segment
        let isSelected: Bool
        var fillsWidth = false
        let action: () -> Void
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: DSSpace.s6) {
                    if let icon = segment.icon { icon.image(size: 16) }
                    Text(segment.title).dsText(isSelected ? .bodyStrong : .label).lineLimit(1)
                }
                .foregroundColor(!isEnabled ? DSColor.textDisabled : isSelected || isHovered ? DSColor.textPrimary : DSColor.textSecondary)
                .padding(.horizontal, DSSpace.s12)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .frame(height: 28)
                .background(
                    Capsule().fill(isSelected ? DSColor.backgroundSurface : isHovered && isEnabled ? DSColor.backgroundPressed : .clear)
                        .dsElevation(isSelected ? .raised : .flat)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }
}
