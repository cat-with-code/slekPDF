import SwiftUI

/// Figma "Text Field" (93:186), Type=Single line: label, 32 pt field (radius 6), helper text.
/// Focus adds a 2 pt Border/Focus ring 4 pt outside the field; Error uses a 1.5 pt Status/Danger border and helper.
struct DSTextField: View {
    let label: CopyKey
    @Binding var text: String
    var icon: DSIcon?
    var isSecure = false
    var helper: CopyKey?
    /// Helper text already in the interface language (e.g. "Saved in “Documents”").
    var helperText: String?
    var error: CopyKey?
    var onSubmit: () -> Void = {}
    @FocusState private var isFocused: Bool
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            DSLabel(label, style: .labelSmall).foregroundColor(DSColor.textSecondary)
            HStack(spacing: DSSpace.s8) {
                if let icon { icon.image(size: 16).foregroundColor(DSColor.textSecondary) }
                Group {
                    if isSecure {
                        SecureField("", text: $text)
                    } else {
                        TextField("", text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .dsText(.body)
                .foregroundColor(DSColor.textPrimary)
                .focused($isFocused)
                .onSubmit(onSubmit)
            }
            .padding(.horizontal, DSSpace.s12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: DSRadius.sm).fill(DSColor.backgroundSurface))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.sm)
                    .strokeBorder(error != nil ? DSColor.statusDanger : DSColor.borderDefault, lineWidth: error != nil ? 1.5 : DSStroke.default)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.shell)
                    .strokeBorder(DSColor.borderFocus, lineWidth: DSStroke.focus)
                    .padding(-4)
                    .opacity(isFocused && error == nil ? 1 : 0)
            )
            if let message = error ?? helper {
                DSLabel(message, style: .caption).foregroundColor(error != nil ? DSColor.statusDanger : DSColor.textTertiary)
            } else if let helperText {
                Text(helperText).dsText(.caption).foregroundColor(DSColor.textTertiary)
            }
        }
        .onAppear { isFocused = true }
    }
}
