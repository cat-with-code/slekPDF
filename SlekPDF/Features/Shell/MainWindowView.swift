import SwiftUI
import UniformTypeIdentifiers

/// One document window: owns its `DocumentSession`, the Open panel and drag & drop.
struct DocumentWindow: View {
    @StateObject private var session = DocumentSession()
    @EnvironmentObject private var recents: RecentDocuments

    var body: some View {
        MainWindowView()
            .environmentObject(session)
            .onAppear { session.onOpened = { [weak recents] url in recents?.add(url) } }
            // Release PDFium and the file's sandbox access when the window closes.
            .onDisappear { Task { await session.close() } }
            // Files opened from Finder (double-click, Open With, drag onto the Dock icon).
            .onReceive(ExternalOpenRequests.shared.$pending) { pending in
                guard !pending.isEmpty, !session.isModalPresented,
                      let url = ExternalOpenRequests.shared.take() else { return }
                Task { await session.open(url) }
            }
            .focusedSceneObject(session)
            .fileImporter(isPresented: $session.isImporterPresented, allowedContentTypes: [.pdf]) { result in
                guard case let .success(url) = result else { return }
                Task { await session.open(url) }
            }
            .onDrop(of: [.fileURL], isTargeted: $session.isDropTargeted) { providers in
                guard !session.isModalPresented, let provider = providers.first else { return false }
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
                VStack(spacing: 0) {
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
                        StartScreenView()
                    }
                }
                .frame(maxHeight: .infinity)
                }
                // Elevation/4 Backdrop: background blur 6 behind dialogs (SwiftUI radius ≈ half of Figma's).
                .blur(radius: session.isModalPresented ? 3 : 0)
                .allowsHitTesting(!session.isModalPresented)
                StatusBarView()
            }
        }
        .background(DSColor.backgroundWindow)
        .background(
            // ⌘K, shown on the search field's badge, focuses search like ⌘F.
            Button("") { session.focusSearch() }
                .keyboardShortcut("k")
                .disabled(session.document == nil || session.isModalPresented)
                .opacity(0)
        )
        .overlay {
            if let error = session.openError {
                ModalLayer { OpenErrorDialog(error: error) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: session.isModalPresented)
        .ignoresSafeArea()
    }

    /// Compact hides the page sidebar by default; the toolbar toggle shows it.
    private func showsSidebar(in sizeClass: WindowSizeClass) -> Bool {
        sizeClass == .compact ? session.isCompactSidebarShown : session.isSidebarVisible
    }
}
