import SwiftUI

/// Figma "Dialog" (135:230): 448 pt card, 24 pt padding, 16 pt gaps, radius 12, Background/Raised,
/// Border/Subtle, Elevation/3. Header = 32 pt icon + title/message/content; actions right-aligned.
struct DSDialog<Content: View>: View {
    let icon: DSIcon
    var iconColor: Color = DSColor.textSecondary
    let title: String
    let message: String
    let cancel: CopyKey
    /// nil = no confirm button (Figma 12 Recognizing text…: Run in background · Cancel).
    let confirm: CopyKey?
    var confirmDisabled = false
    /// Destructive for irreversible actions (Figma Button: Destructive, e.g. "Delete pages").
    var confirmStyle: DSButton.Style = .primary
    /// A plain third choice on the left (e.g. "Don’t save").
    var secondary: (title: CopyKey, action: () -> Void)?
    /// The plain left button is the dialog's Cancel (Esc), e.g. Figma 39: Cancel · Save work first · Recognize again.
    var secondaryCancels = false
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s16) {
            HStack(alignment: .top, spacing: DSSpace.s16) {
                icon.image(size: 32).foregroundColor(iconColor)
                VStack(alignment: .leading, spacing: DSSpace.s6) {
                    Text(title).dsText(.title).foregroundColor(DSColor.textPrimary)
                    Text(message).dsText(.body).foregroundColor(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    content
                }
            }
            HStack(spacing: DSSpace.s8) {
                if let secondary {
                    DSButton(secondary.title, style: .plain, action: secondary.action)
                        .keyboardShortcut(secondaryCancels ? .cancelAction : nil)
                }
                Spacer()
                DSButton(cancel, action: onCancel).keyboardShortcut(secondaryCancels ? nil : .cancelAction)
                if let confirm {
                    DSButton(confirm, style: confirmStyle, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                        .disabled(confirmDisabled)
                }
            }
        }
        .padding(DSSpace.s24)
        .frame(width: 448)
        .background(RoundedRectangle(cornerRadius: DSRadius.lg).fill(DSColor.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.lg).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .dsElevation(.dialog)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

extension DSDialog where Content == EmptyView {
    init(icon: DSIcon, iconColor: Color = DSColor.textSecondary, title: String, message: String, cancel: CopyKey, confirm: CopyKey?,
         confirmStyle: DSButton.Style = .primary, secondary: (title: CopyKey, action: () -> Void)? = nil, secondaryCancels: Bool = false,
         onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        self.init(icon: icon, iconColor: iconColor, title: title, message: message, cancel: cancel, confirm: confirm,
                  confirmStyle: confirmStyle, secondary: secondary, secondaryCancels: secondaryCancels,
                  onCancel: onCancel, onConfirm: onConfirm) { EmptyView() }
    }
}
