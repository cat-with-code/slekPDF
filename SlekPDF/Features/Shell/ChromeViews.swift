import SwiftUI

/// Figma "Title Bar" (102:39). The system traffic lights sit over the leading inset.
struct TitleBarView: View {
    let fileName: String

    var body: some View {
        HStack(spacing: DSSpace.s16) {
            Color.clear.frame(width: 64)
            Text("Slek PDF")
                .font(.custom("Inter-SemiBold", fixedSize: 13))
                .foregroundColor(DSColor.textPrimary)
            HStack(spacing: DSSpace.s6) {
                DSIcon.fileTypePdf.image()
                Text(fileName)
                    .font(.custom("Inter-Regular", fixedSize: 13))
                    .foregroundColor(DSColor.textSecondary)
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
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: DSSpace.s8) {
            if sizeClass == .compact {
                DSIconButton(.leftBar) { appState.isCompactSidebarShown.toggle() }
            }
            DSButton(.openPDF, icon: .folderOpen)
            DSButton(.saveWork, icon: .save)
            DSDivider(axis: .vertical).frame(height: 24).padding(.horizontal, DSSpace.s4)
            DSButton(.undo, icon: .undo, style: .plain)
            DSButton(.redo, icon: .redo, style: .plain)
            Spacer()
            DSButton(.print, icon: .printer, style: .plain)
            DSButton(.preferences, icon: .setting, style: .plain)
        }
        .padding(.horizontal, DSSpace.s12)
        .frame(height: ChromeMetrics.toolbarHeight)
        .background(DSColor.backgroundSurface)
        .overlay(DSDivider(), alignment: .top)
        .overlay(DSDivider(), alignment: .bottom)
    }
}

/// Figma "Workspace Tabs" (98:331): underline tabs.
struct WorkspaceTabBar: View {
    @Binding var selection: Workspace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Workspace.allCases) { workspace in
                tab(workspace)
            }
            Spacer()
        }
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

    var body: some View {
        HStack(spacing: DSSpace.s12) {
            DSLabel(.page1Of3SourcePreservedLocalP, style: .caption)
                .foregroundColor(DSColor.textSecondary)
                .lineLimit(1)
            Spacer()
            Text("100%")
                .dsText(.caption)
                .foregroundColor(DSColor.textSecondary)
            ThemeSwitch(appearance: $appState.appearance)
            LanguageSwitch(language: $appState.language)
        }
        .padding(.horizontal, DSSpace.s12)
        .frame(height: ChromeMetrics.statusBarHeight)
        .background(DSColor.backgroundWindow)
        .overlay(DSDivider(), alignment: .top)
    }
}
