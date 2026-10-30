import SwiftUI

/// In-window modal layer (user rule: every overlay gets a backdrop). Title bar and toolbar stay visible but
/// inert; the scrim covers the workspace area (Figma y 94–864): Background/Scrim at 35% plus the blur that
/// `MainWindowView` applies to the content underneath.
struct ModalLayer<Dialog: View>: View {
    @ViewBuilder var dialog: Dialog

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: ChromeMetrics.titleBarHeight + ChromeMetrics.toolbarHeight)
                .contentShape(Rectangle())
            ZStack {
                DSColor.backgroundScrim.opacity(0.35)
                dialog
            }
            Color.clear
                .frame(height: ChromeMetrics.statusBarHeight)
                .contentShape(Rectangle())
        }
        .transition(.opacity)
    }
}

/// Prototype "13 This PDF needs a password" (164:6408) and "35 This file can’t be opened" (408:48432).
struct OpenErrorDialog: View {
    let error: DocumentSession.OpenError
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var password = ""

    var body: some View {
        switch error {
        case let .needsPassword(fileName):
            DSDialog(icon: .lock,
                     title: CopyCatalog.shared.string(.thisPDFNeedsAPassword, language),
                     message: CopyCatalog.shared.format(.fmtFileIsProtectedEnterPassword, language, fileName),
                     cancel: .cancel, confirm: .open, confirmDisabled: password.isEmpty,
                     onCancel: session.dismissOpenError, onConfirm: submit) {
                DSTextField(label: .password, text: $password, icon: .lock, isSecure: true,
                            helper: .thePasswordIsUsedOnlyToOpenTheFi,
                            error: session.passwordRejected ? .thatPasswordDidnTWork : nil,
                            onSubmit: submit)
                    .padding(.top, DSSpace.s6)
            }
        case let .unreadable(fileName):
            DSDialog(icon: .attention, iconColor: DSColor.statusDanger,
                     title: CopyCatalog.shared.string(.thisFileCanTBeOpened, language),
                     message: CopyCatalog.shared.format(.fmtFileIsDamagedOrUnsupported, language, fileName),
                     cancel: .cancel, confirm: .chooseAnotherFile,
                     onCancel: session.dismissOpenError) {
                session.dismissOpenError()
                session.isImporterPresented = true
            }
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let attempt = password
        password = ""
        Task { await session.unlock(with: attempt) }
    }
}
