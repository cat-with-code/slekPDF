import SwiftUI
import UniformTypeIdentifiers

/// One document window: owns its `DocumentSession`, the Open panel and drag & drop.
struct DocumentWindow: View {
    @StateObject private var session = DocumentSession()
    @State private var isDropTargeted = false

    var body: some View {
        MainWindowView()
            .environmentObject(session)
            .focusedSceneObject(session)
            .fileImporter(isPresented: $session.isImporterPresented, allowedContentTypes: [.pdf]) { result in
                guard case let .success(url) = result else { return }
                Task { await session.open(url) }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await session.open(url) }
                }
                return true
            }
    }
}

/// Main document window. Reference: Prototype "KM · 01 Read" (164:6246) and the C-/L-/W- size variants.
/// Rows: title bar 44 · toolbar 50 · workspace tabs 44 · workspace (sidebar | canvas | inspector) · status bar 36.
struct MainWindowView: View {
    @EnvironmentObject private var session: DocumentSession

    var body: some View {
        GeometryReader { proxy in
            let sizeClass = WindowSizeClass(width: proxy.size.width)
            VStack(spacing: 0) {
                TitleBarView(fileName: session.fileName)
                ToolbarView(sizeClass: sizeClass)
                WorkspaceTabBar(selection: $session.workspace, isEnabled: session.document != nil)
                HStack(spacing: 0) {
                    if session.document != nil {
                        if showsSidebar(in: sizeClass) {
                            PageSidebarView()
                                .frame(width: sizeClass.sidebarWidth ?? WindowSizeClass.regular.sidebarWidth)
                            DSDivider(axis: .vertical)
                        }
                        DocumentCanvas()
                        if session.isInspectorVisible {
                            DSDivider(axis: .vertical)
                            ReadInspectorView().frame(width: sizeClass.inspectorWidth)
                        }
                    } else {
                        // Start screen (11 Open a document) arrives in slice 2.
                        DSColor.backgroundCanvas
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
        sizeClass == .compact ? session.isCompactSidebarShown : session.isSidebarVisible
    }
}
