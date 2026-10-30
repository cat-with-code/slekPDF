import SwiftUI

/// Main document window. Reference: Prototype "KM · 01 Read" (164:6246) and the C-/L-/W- size variants.
/// Rows: title bar 44 · toolbar 50 · workspace tabs 44 · workspace (sidebar | canvas | inspector) · status bar 36.
struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { proxy in
            let sizeClass = WindowSizeClass(width: proxy.size.width)
            VStack(spacing: 0) {
                TitleBarView(fileName: "Sample document.pdf")
                ToolbarView(sizeClass: sizeClass)
                WorkspaceTabBar(selection: $appState.workspace)
                HStack(spacing: 0) {
                    if showsSidebar(in: sizeClass) {
                        PageSidebarView()
                            .frame(width: sizeClass.sidebarWidth ?? WindowSizeClass.regular.sidebarWidth)
                        DSDivider(axis: .vertical)
                    }
                    DocumentCanvasPlaceholder()
                    if appState.isInspectorVisible {
                        DSDivider(axis: .vertical)
                        ReadInspectorView().frame(width: sizeClass.inspectorWidth)
                    }
                }
                .frame(maxHeight: .infinity)
                StatusBarView()
            }
        }
        .background(DSColor.backgroundWindow)
        .ignoresSafeArea()
    }

    /// Compact hides the page sidebar by default; the toolbar toggle shows it.
    private func showsSidebar(in sizeClass: WindowSizeClass) -> Bool {
        sizeClass == .compact ? appState.isCompactSidebarShown : appState.isSidebarVisible
    }
}
