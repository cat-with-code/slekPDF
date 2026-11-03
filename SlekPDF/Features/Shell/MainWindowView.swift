import SwiftUI
import UniformTypeIdentifiers

/// One document window: owns its `DocumentSession`, the Open panel and drag & drop.
struct DocumentWindow: View {
    @StateObject private var session = DocumentSession()
    @EnvironmentObject private var recents: RecentDocuments

    var body: some View {
        MainWindowView()
            .environmentObject(session)
            .environmentObject(session.toasts)
            .navigationTitle(session.fileName ?? "Slek PDF")
            .onAppear { session.onOpened = { [weak recents = recents] url in recents?.add(url) } }
            // Release PDFium and the file's sandbox access when the window closes.
            .onDisappear { Task { await session.close() } }
            // Files opened from Finder (double-click, Open With, drag onto the Dock icon).
            .onReceive(ExternalOpenRequests.shared.$pending) { pending in
                guard !pending.isEmpty, !session.isModalPresented,
                      let url = ExternalOpenRequests.shared.take() else { return }
                Task { await session.open(url) }
            }
            .focusedSceneObject(session)
            .background(WindowCloseGuard(session: session))  // 16 Save changes before closing?
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
    @Environment(\.undoManager) private var undoManager
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                                .transition(panelTransition(edge: .leading))
                            DSDivider(axis: .vertical)
                        } else if sizeClass != .compact {
                            // Collapsed: keep a rail so the sidebar can be brought back (Compact uses the toolbar toggle).
                            CollapsedSidebarRail().transition(.opacity)
                            DSDivider(axis: .vertical)
                        }
                        if session.workspace == .organizePages {
                            OrganizeCanvas()  // Prototype 02
                        } else {
                            DocumentCanvas()
                        }
                        DSDivider(axis: .vertical)
                        if session.isInspectorVisible {
                            Group {
                                switch session.workspace {
                                case .organizePages: OrganizeInspector()
                                case .annotate: AnnotateInspector()  // Prototype 03
                                default: ReadInspectorView()
                                }
                            }
                                .frame(width: sizeClass.inspectorWidth)
                                .transition(panelTransition(edge: .trailing))
                        } else {
                            CollapsedInspectorRail().transition(.opacity)
                        }
                    } else {
                        StartScreenView()
                    }
                }
                .frame(maxHeight: .infinity)
                .clipped()  // sliding panels stay inside the workspace row
                }
                // Elevation/4 Backdrop: background blur 6 behind dialogs (SwiftUI radius ≈ half of Figma's).
                .blur(radius: session.isModalPresented ? 3 : 0)
                .allowsHitTesting(!session.isModalPresented)
                StatusBarView()
            }
        }
        .background(DSColor.backgroundWindow)
        .background {
            let isBlocked = session.document == nil || session.isModalPresented
            // ⌘K, shown on the search field's badge, focuses search like ⌘F.
            Button("") { session.focusSearch() }
                .shortcut(.focusSearch)
                .disabled(isBlocked)
                .opacity(0)
            // ⌘= zooms in like View ▸ Zoom In (⌘+), so the key works without Shift — while Zoom In keeps its default.
            Button("") { session.zoomIn() }
                .keyboardShortcut("=")
                .disabled(isBlocked || ShortcutStore.shared.isChanged(.zoomIn))
                .opacity(0)
        }
        .overlay(alignment: .bottom) {
            // Toast 143:68: bottom-centre, 24 pt above the status bar.
            if let toast = toasts.current {
                DSToast(tone: toast.tone, message: toast.message, action: toast.action) { toasts.dismiss() }
                    .onHover { toasts.isHovered = $0 }
                    .padding(.bottom, ChromeMetrics.statusBarHeight + DSSpace.s24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(toast.id)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.25), value: toasts.current?.id)
        .overlay {
            if let error = session.openError {
                ModalLayer { OpenErrorDialog(error: error) }
            } else if let panel = session.panel {
                ModalLayer { AppPanelView(panel: panel) }
            } else if let dialog = session.organizeDialog {
                ModalLayer { OrganizeDialogView(dialog: dialog) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: session.isModalPresented)
        .onAppear { session.undoManager = undoManager }
        .onChange(of: undoManager) { session.undoManager = $0 }
        .ignoresSafeArea()
    }

    /// Panels slide in from their own edge while fading; with Reduce Motion they only fade.
    private func panelTransition(edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// Compact hides the page sidebar by default; the toolbar toggle shows it.
    private func showsSidebar(in sizeClass: WindowSizeClass) -> Bool {
        sizeClass == .compact ? session.isCompactSidebarShown : session.isSidebarVisible
    }
}
