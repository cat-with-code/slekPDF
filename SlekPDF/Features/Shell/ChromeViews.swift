import SwiftUI

/// Figma "Title Bar" (102:39). The system traffic lights sit over the leading inset.
struct TitleBarView: View {
    let fileName: String?
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(spacing: DSSpace.s16) {
            Color.clear.frame(width: 64)
            Text("Slek PDF")
                .font(.custom("Inter-SemiBold", fixedSize: 13))
                .foregroundColor(DSColor.textPrimary)
            HStack(spacing: DSSpace.s6) {
                if let fileName {
                    DSIcon.fileTypePdf.image()
                    Text(fileName)
                        .font(.custom("Inter-Regular", fixedSize: 13))
                        .foregroundColor(DSColor.textSecondary)
                } else {
                    DSLabel(.noDocumentOpen, style: .body).foregroundColor(DSColor.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, DSSpace.s12)
        .frame(height: ChromeMetrics.titleBarHeight)
        .background(DSColor.backgroundWindow)
    }
}

/// Figma "Toolbar" (103:776) Type=Full; Compact adds the sidebar toggle.
struct ToolbarView: View {
    let sizeClass: WindowSizeClass
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        let hasDocument = session.document != nil
        HStack(spacing: DSSpace.s8) {
            if sizeClass == .compact {
                DSIconButton(.leftBar) { session.toggleCompactSidebar() }
                    .dsTooltip(.showPageSidebar, shortcut: "⌥⌘S")
                    .disabled(!hasDocument)
            }
            DSButton(.openPDF, icon: .folderOpen) { session.isImporterPresented = true }
                .dsTooltip(.openPDF, shortcut: "⌘O")
            DSButton(.saveWork, icon: .save) { session.requestSaveWork(language) }  // 42 Save work
                .dsTooltip(.saveWork, shortcut: ShortcutStore.shared.shortcut(.saveWork)?.display)
                .disabled(!hasDocument || session.isModalPresented)
            DSDivider(axis: .vertical).frame(height: 24).padding(.horizontal, DSSpace.s4)
            DSButton(.undo, icon: .undo, style: .plain) { session.undoManager?.undo() }
                .dsTooltip(.undo, shortcut: ShortcutStore.shared.shortcut(.undo)?.display)
                .disabled(!hasDocument || session.isModalPresented || session.undoManager?.canUndo != true)
            DSButton(.redo, icon: .redo, style: .plain) { session.undoManager?.redo() }
                .dsTooltip(.redo, shortcut: ShortcutStore.shared.shortcut(.redo)?.display)
                .disabled(!hasDocument || session.isModalPresented || session.undoManager?.canRedo != true)
            Spacer()
            DSButton(.print, icon: .printer, style: .plain) { PrintController.print(session, language: language) }  // D-25
                .dsTooltip(.print, shortcut: ShortcutStore.shared.shortcut(.print)?.display)
                .disabled(!hasDocument || session.isModalPresented)
            DSButton(.preferences, icon: .setting, style: .plain) { session.panel = .preferences(.general) }  // D-10
                .dsTooltip(.preferences, shortcut: ShortcutStore.shared.shortcut(.preferences)?.display)
                .disabled(session.isModalPresented)
        }
        .padding(.horizontal, DSSpace.s12)
        .frame(height: ChromeMetrics.toolbarHeight)
        .background(DSColor.backgroundSurface)
        .overlay(DSDivider(), alignment: .top)
        .overlay(DSDivider(), alignment: .bottom)
    }
}

/// Figma "Workspace Tabs" (98:331): underline tabs. Disabled (dimmed) until a document is open.
struct WorkspaceTabBar: View {
    @Binding var selection: Workspace
    var isEnabled = true

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Workspace.allCases) { workspace in
                tab(workspace)
            }
            Spacer()
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .padding(.horizontal, DSSpace.s8)
        .frame(height: ChromeMetrics.workspaceTabsHeight)
        .background(DSColor.backgroundWindow)
        .overlay(DSDivider(), alignment: .bottom)
    }

    private func tab(_ workspace: Workspace) -> some View {
        let isSelected = workspace == selection
        return Button { selection = workspace } label: {
            HStack(spacing: DSSpace.s6) {
                workspace.icon.image()
                    .foregroundColor(isSelected ? DSColor.textAccent : DSColor.textSecondary)
                DSLabel(workspace.title, style: isSelected ? .bodyStrong : .body)
                    .foregroundColor(isSelected ? DSColor.textPrimary : DSColor.textSecondary)
            }
            .padding(.horizontal, DSSpace.s12)
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle().fill(isSelected ? DSColor.accentDefault : .clear).frame(height: DSStroke.focus),
                alignment: .bottom
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Figma "Status Bar" (101:82).
struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(spacing: DSSpace.s12) {
            Group {
                if session.document != nil {
                    Text(CopyCatalog.shared.format(.fmtPageNOfMStatus, language, session.currentPageIndex + 1, session.pageCount)).dsText(.caption)
                } else {
                    DSLabel(.noDocumentDragAPDFIntoTheWindow, style: .caption)
                }
            }
            .foregroundColor(DSColor.textSecondary)
            .lineLimit(1)
            Spacer()
            if session.document != nil {
                Text(language.number(Int((session.scaleFactor * 100).rounded())) + "%")
                    .dsText(.caption)
                    .foregroundColor(DSColor.textSecondary)
            }
            ThemeSwitch(appearance: $appState.appearance)
            LanguageSwitch(language: $appState.language)
        }
        .padding(.horizontal, DSSpace.s12)
        .frame(height: ChromeMetrics.statusBarHeight)
        .background(DSColor.backgroundWindow)
        .overlay(DSDivider(), alignment: .top)
    }
}
