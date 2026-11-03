import AppKit
import PDFKit
import SwiftUI

/// One window's open document. PDFKit displays pages; PDFium (through `PDFiumService`) handles Khmer
/// text and search. App-wide settings (language, appearance) stay in `AppState`.
@MainActor
final class DocumentSession: ObservableObject {
    enum OpenError: Error, Equatable {
        case unreadable(fileName: String)
        case needsPassword(fileName: String)
    }

    @Published private(set) var document: PDFDocument?
    @Published private(set) var url: URL?
    @Published var currentPageIndex = 0
    @Published private(set) var scaleFactor: CGFloat = 1
    /// "Fit page" keeps the whole current page visible, also when the window is resized.
    @Published private(set) var isFitPage = true
    @Published var isImporterPresented = false
    @Published var isDropTargeted = false
    /// Called after a successful open (DocumentWindow records it in Recent documents).
    var onOpened: ((URL) -> Void)?
    @Published var openError: OpenError?
    @Published var workspace: Workspace = .read
    @Published var isSidebarVisible = true
    @Published var isCompactSidebarShown = false
    @Published var isInspectorVisible = true

    private(set) var pdfiumID: PDFiumService.DocumentID?
    private var accessedURL: URL?
    private var thumbnailCache: [Int: NSImage] = [:]
    weak var pdfView: PDFView?

    var pageCount: Int { document?.pageCount ?? 0 }
    var fileName: String? { url?.lastPathComponent }

    /// A password-protected file waiting for its password; keeps security-scoped access while the dialog is open.
    /// The password itself is never stored.
    private var pending: (url: URL, document: PDFDocument, didAccess: Bool)?
    @Published private(set) var passwordRejected = false

    /// An About/Help/Developer/Release Notes/Report/Feedback panel over the window (Slek PDF and Help menus).
    @Published var panel: AppPanel?

    /// This window's toasts (also used by actions started from the menu bar, such as Print).
    let toasts = ToastCenter()

    // MARK: Page edits (Organize pages). The PDFKit document mirrors `pages`; the file itself is never changed.

    /// One page of the edited document: which page of the source file, turned how many × 90° clockwise.
    struct PageRef: Identifiable, Hashable {
        let id = UUID()
        let source: Int
        var quarterTurns = 0
    }

    @Published private(set) var pages: [PageRef] = []
    @Published var selectedPageIDs: Set<PageRef.ID> = []
    private var originalPages: [PDFPage] = []
    private var originalRotations: [Int] = []
    private var savedPages: [PageRef] = []
    /// The window's undo manager (MainWindowView), so Edit ▸ Undo / ⌘Z and the toolbar undo page edits.
    weak var undoManager: UndoManager?

    /// Annotate: Slek's annotations per page (the PageRef, so they follow reorder, rotation and delete/undo).
    @Published private(set) var annotations: [PageRef.ID: [PageAnnotation]] = [:]
    private var savedAnnotations: [PageRef.ID: [PageAnnotation]] = [:]

    var hasUnsavedChanges: Bool { pages != savedPages || annotations != savedAnnotations }
    var selectedPageIndices: [Int] { pages.indices.filter { selectedPageIDs.contains(pages[$0].id) } }
    /// The open organize dialog (20 Delete pages?, 42 Save work).
    @Published var organizeDialog: OrganizeDialog?
    /// Where Save work wrote last; later saves go there without asking again.
    var workURL: URL?
    /// "Don’t ask again this session" in 20 Delete pages?
    var skipDeleteConfirmation = false

    enum OrganizeDialog: Equatable { case deletePages, saveWork, merge, split, closeConfirm }

    /// Every open session, for the quit check (Save changes before closing?).
    static let all = NSHashTable<DocumentSession>.weakObjects()
    weak var window: NSWindow?
    /// Set by "Save" in 16 Save changes before closing?: close the window once the work is saved.
    var closeAfterSave = false
    /// Set by "Don’t save": the window may close with unsaved changes.
    var discardChanges = false
    /// The close was part of quitting the app: quit again once this window is closed.
    var quitAfterClose = false

    init() { Self.all.add(self) }

    /// The edited document's pages for PDFium (current order and rotation).
    func editedPageSources(_ indices: [Int]? = nil) -> [PDFiumService.PageSource] {
        guard let id = pdfiumID else { return [] }
        return (indices ?? Array(pages.indices)).map {
            .open(id, page: pages[$0].source, quarterTurns: pages[$0].quarterTurns, annotations: annotations[pages[$0].id] ?? [])
        }
    }

    /// True while an in-window dialog (password, can't open) or panel is shown; blocks toolbar, menus and drops.
    var isModalPresented: Bool { openError != nil || panel != nil || organizeDialog != nil }

    func open(_ url: URL) async {
        dismissOpenError()
        let didAccess = url.startAccessingSecurityScopedResource()
        let name = url.lastPathComponent
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            openError = .unreadable(fileName: name)
            return
        }
        if pdf.isLocked {
            pending = (url, pdf, didAccess)
            openError = .needsPassword(fileName: name)
            return
        }
        await finishOpening(url, pdf, didAccess: didAccess, password: nil)
    }

    /// Password dialog: unlock PDFKit's copy, then open PDFium with the same password.
    func unlock(with password: String) async {
        guard let pending else { return }
        guard pending.document.unlock(withPassword: password) else {
            passwordRejected = true
            return
        }
        self.pending = nil
        passwordRejected = false
        openError = nil
        await finishOpening(pending.url, pending.document, didAccess: pending.didAccess, password: password)
    }

    func dismissOpenError() {
        if let pending, pending.didAccess { pending.url.stopAccessingSecurityScopedResource() }
        pending = nil
        passwordRejected = false
        openError = nil
    }

    private func finishOpening(_ url: URL, _ pdf: PDFDocument, didAccess: Bool, password: String?) async {
        let name = url.lastPathComponent
        func fail() {
            if didAccess { url.stopAccessingSecurityScopedResource() }
            openError = .unreadable(fileName: name)
        }
        let opened: (id: PDFiumService.DocumentID, pageCount: Int)
        do {
            opened = try await PDFiumService.shared.open(url: url, password: password)
        } catch {
            return fail()
        }
        // Display (PDFKit) and text/search (PDFium) must agree on the pages, or search would point at the wrong page.
        guard opened.pageCount == pdf.pageCount else {
            await PDFiumService.shared.close(opened.id)
            return fail()
        }
        // Reopened saved work: Slek's annotations come back into the model and are drawn by Slek, not by PDFKit.
        let stored = await PDFiumService.shared.annotations(opened.id)
        await close()
        originalPages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
        originalRotations = originalPages.map(\.rotation)
        for (source, list) in stored where originalPages.indices.contains(source) {
            let page = originalPages[source]
            let copies = page.annotations.filter { annotation in list.contains { Self.isStoredCopy(annotation, of: $0) } }
            for annotation in copies {
                if let popup = annotation.popup { page.removeAnnotation(popup) }
                page.removeAnnotation(annotation)
            }
        }
        pages = originalPages.indices.map { PageRef(source: $0) }
        savedPages = pages
        annotations = Dictionary(uniqueKeysWithValues: stored.compactMap { source, list in
            pages.indices.contains(source) ? (pages[source].id, list) : nil
        })
        savedAnnotations = annotations
        mirrorAnnotations()
        selectedPageIDs = pages.first.map { [$0.id] } ?? []
        document = pdf
        self.url = url
        accessedURL = didAccess ? url : nil
        pdfiumID = opened.id
        currentPageIndex = 0
        isFitPage = true
        openError = nil
        onOpened?(url)
    }

    func close() async {
        searchTask?.cancel()
        searchResults = []
        currentMatchIndex = nil
        searchQuery = ""
        if let id = pdfiumID { await PDFiumService.shared.close(id) }
        pdfiumID = nil
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        document = nil
        url = nil
        thumbnailCache = [:]
        pages = []
        savedPages = []
        annotations = [:]
        savedAnnotations = [:]
        selectedPageIDs = []
        originalPages = []
        originalRotations = []
        organizeDialog = nil
        workURL = nil
        currentPageIndex = 0
    }

    // MARK: - Navigation and zoom (drive the PDFView; it reports back through notifications)

    func goToPage(_ index: Int) {
        guard let document, (0..<document.pageCount).contains(index), let page = document.page(at: index) else { return }
        show(page)
        currentPageIndex = index
    }

    private func show(_ page: PDFPage) {
        pdfView?.go(to: page)
    }

    func nextPage() { goToPage(currentPageIndex + 1) }
    func previousPage() { goToPage(currentPageIndex - 1) }
    func zoomIn() { isFitPage = false; pdfView?.zoomIn(nil) }
    func zoomOut() { isFitPage = false; pdfView?.zoomOut(nil) }

    /// View ▸ Fit Width: the page width fills the canvas (leaves Fit page).
    func fitWidth() {
        guard let view = pdfView, let page = view.currentPage ?? document?.page(at: currentPageIndex) else { return }
        var size = page.bounds(for: view.displayBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let width = view.bounds.width - view.pageBreakMargins.left - view.pageBreakMargins.right
        guard size.width > 0, width > 0 else { return }
        isFitPage = false
        view.autoScales = false
        view.scaleFactor = width / size.width
    }

    /// Incremented by Document ▸ Go to Page… (⌘L) to focus the page number field.
    @Published private(set) var pageFieldFocusRequest = 0
    func focusPageField() { pageFieldFocusRequest += 1 }

    /// Scales so the whole current page (not just its width) fits, like the prototype's "Fit page".
    func fitPage() {
        isFitPage = true
        applyFitPage()
    }

    func applyFitPage() {
        guard isFitPage, let view = pdfView, let page = view.currentPage ?? document?.page(at: currentPageIndex) else { return }
        var size = page.bounds(for: view.displayBox).size
        if page.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        let margins = view.pageBreakMargins
        let available = CGSize(width: view.bounds.width - margins.left - margins.right,
                               height: view.bounds.height - PDFCanvasView.topInset - margins.top - margins.bottom)
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return }
        view.autoScales = false
        fitScale = min(available.width / size.width, available.height / size.height)
        view.scaleFactor = fitScale
        show(page)
    }

    /// The scale "Fit page" last applied; any other scale means the user zoomed.
    private var fitScale: CGFloat = 0

    func pdfViewDidChangePage(_ index: Int) { currentPageIndex = index }
    /// Pinch, ⌘+/⌘− and other zooming inside the PDF view leave Fit page, so later layout changes keep the zoom.
    func pdfViewDidChangeScale(_ scale: CGFloat) {
        scaleFactor = scale
        if isFitPage, abs(scale - fitScale) > 0.001 { isFitPage = false }
    }

    // MARK: - Search (PDFium text: reliable Khmer search, unlike PDFKit's — docs/spikes/01)

    @Published var searchQuery = "" { didSet { if searchQuery != oldValue { scheduleSearch() } } }
    @Published var matchCase = false { didSet { scheduleSearch() } }
    @Published var wholeWord = false { didSet { scheduleSearch() } }
    @Published private(set) var searchResults: [PDFiumMatch] = []
    @Published private(set) var currentMatchIndex: Int?
    @Published private(set) var isSearching = false
    /// Incremented by ⌘F / ⌘K to move focus to the search field.
    @Published private(set) var searchFocusRequest = 0
    private var searchTask: Task<Void, Never>?

    var isSearchActive: Bool { !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var searchPageCount: Int { Set(searchResults.map(\.page)).count }

    /// ⌘F / ⌘K / the rail's search button: show the inspector if it is collapsed, then focus its search field
    /// (on the next run-loop turn, once the expanded panel's field exists). Keyboard shortcuts pass
    /// `animated: false` — they are used constantly and must feel instant.
    func focusSearch(animated: Bool = false) {
        guard !isInspectorVisible else {
            searchFocusRequest += 1
            return
        }
        setInspectorVisible(true, animated: animated)
        DispatchQueue.main.async { [weak self] in self?.searchFocusRequest += 1 }
    }

    // MARK: - Panels

    /// Panel show/hide motion: the iOS-style drawer curve (cubic-bezier 0.32, 0.72, 0, 1) at 250 ms.
    /// With Reduce Motion, a short fade only (no sliding).
    static func panelAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.25)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Clicks animate; keyboard shortcuts and menu items pass `animated: false`.
    func setSidebarVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != isSidebarVisible else { return }
        if animated {
            withAnimation(Self.panelAnimation(reduceMotion: reduceMotion)) { isSidebarVisible = visible }
        } else {
            isSidebarVisible = visible
        }
    }

    func setInspectorVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != isInspectorVisible else { return }
        if animated {
            withAnimation(Self.panelAnimation(reduceMotion: reduceMotion)) { isInspectorVisible = visible }
        } else {
            isInspectorVisible = visible
        }
    }

    func toggleCompactSidebar() {
        withAnimation(Self.panelAnimation(reduceMotion: reduceMotion)) { isCompactSidebarShown.toggle() }
    }
    func clearSearch() { searchQuery = "" }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = pdfiumID, !query.isEmpty else {
            searchResults = []
            currentMatchIndex = nil
            isSearching = false
            return
        }
        let matchCase = matchCase, wholeWord = wholeWord
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)  // debounce typing
            guard !Task.isCancelled else { return }
            let found = await PDFiumService.shared.search(id, query: query, matchCase: matchCase, wholeWord: wholeWord)
            guard !Task.isCancelled, let self else { return }
            let results = self.currentPageMatches(found)
            searchResults = results
            isSearching = false
            currentMatchIndex = results.isEmpty ? nil : (results.firstIndex { $0.page >= self.currentPageIndex } ?? 0)
            if let index = currentMatchIndex { reveal(results[index]) }
        }
    }

    /// Waits for the pending search (tests).
    func waitForSearch() async { await searchTask?.value }

    func selectMatch(_ index: Int) {
        guard searchResults.indices.contains(index) else { return }
        currentMatchIndex = index
        reveal(searchResults[index])
    }

    func nextMatch() {
        guard !searchResults.isEmpty else { return }
        selectMatch(((currentMatchIndex ?? -1) + 1) % searchResults.count)
    }

    func previousMatch() {
        guard !searchResults.isEmpty else { return }
        selectMatch(((currentMatchIndex ?? 0) - 1 + searchResults.count) % searchResults.count)
    }

    private func reveal(_ match: PDFiumMatch) {
        guard let page = document?.page(at: match.page), let first = match.rects.first else { return }
        let area = match.rects.dropFirst().reduce(first) { $0.union($1) }
        pdfView?.go(to: area.insetBy(dx: -48, dy: -96), on: page)
        currentPageIndex = match.page
    }

    // MARK: - Copy (readable Khmer via PDFium, not PDFKit's drawing-order text)

    /// Readable text of a PDFKit selection: each selected line's rectangle is read from PDFium and rebuilt.
    func text(of selection: PDFSelection) async -> String {
        guard let id = pdfiumID, let document else { return selection.string ?? "" }
        let lines: [(page: Int, rect: CGRect)] = selection.selectionsByLine().compactMap { line in
            guard let page = line.pages.first else { return nil }
            let index = document.index(for: page)
            return (pages.indices.contains(index) ? pages[index].source : index, line.bounds(for: page))
        }
        return await PDFiumService.shared.copyText(id, lines: lines)
    }

    func copy(_ selection: PDFSelection) {
        Task {
            let text = await text(of: selection)
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: - Page edit operations (undoable)

    /// PDFium reports pages of the source file; show them at their current place (deleted pages drop out).
    private func currentPageMatches(_ matches: [PDFiumMatch]) -> [PDFiumMatch] {
        matches.compactMap { match in
            pages.firstIndex { $0.source == match.page }.map {
                PDFiumMatch(page: $0, charIndex: match.charIndex, charCount: match.charCount, rects: match.rects,
                            before: match.before, match: match.match, after: match.after)
            }
        }
    }

    /// Replaces the page list, mirrors it into the PDFKit document and registers the undo.
    func setPages(_ newPages: [PageRef], selecting selection: Set<PageRef.ID>? = nil) {
        let oldPages = pages, oldSelection = selectedPageIDs
        undoManager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.setPages(oldPages, selecting: oldSelection) }
        }
        pages = newPages
        selectedPageIDs = selection ?? selectedPageIDs.filter { id in newPages.contains { $0.id == id } }
        mirrorPages()
        if isSearchActive { scheduleSearch() }
    }

    private func mirrorPages() {
        guard let document else { return }
        while document.pageCount > 0 { document.removePage(at: document.pageCount - 1) }
        for (index, ref) in pages.enumerated() {
            let page = originalPages[ref.source]
            page.rotation = (originalRotations[ref.source] + ref.quarterTurns * 90) % 360
            document.insert(page, at: index)
        }
        mirrorAnnotations()
        thumbnailCache = [:]
        currentPageIndex = min(currentPageIndex, max(0, pages.count - 1))
        pdfView?.layoutDocumentView()
        if isFitPage { applyFitPage() }
    }

    func movePages(by offset: Int) {
        var result = pages
        let indices = selectedPageIndices
        guard !indices.isEmpty else { return }
        if offset < 0 {
            guard indices.first! > 0 else { return }
            for index in indices { result.swapAt(index, index - 1) }
        } else {
            guard indices.last! < pages.count - 1 else { return }
            for index in indices.reversed() { result.swapAt(index, index + 1) }
        }
        setPages(result)
    }

    /// Drag and drop: moves the dragged pages (the selection, or just the dragged page) before `target`.
    func movePages(_ ids: Set<PageRef.ID>, to target: Int) {
        let moving = pages.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        let before = pages[..<min(target, pages.count)].filter { !ids.contains($0.id) }
        let after = pages[min(target, pages.count)...].filter { !ids.contains($0.id) }
        setPages(Array(before) + moving + Array(after))
    }

    func rotateSelectedPages(clockwise: Bool = true) {
        let ids = selectedPageIDs.isEmpty ? Set(pages.indices.contains(currentPageIndex) ? [pages[currentPageIndex].id] : []) : selectedPageIDs
        setPages(pages.map { ref in
            guard ids.contains(ref.id) else { return ref }
            var turned = ref
            turned.quarterTurns = (ref.quarterTurns + (clockwise ? 1 : 3)) % 4
            return turned
        })
    }

    /// Removes the selected pages (keeps at least one page). Returns how many were removed.
    @discardableResult
    func deleteSelectedPages() -> Int {
        let remaining = pages.filter { !selectedPageIDs.contains($0.id) }
        guard !remaining.isEmpty, remaining.count < pages.count else { return 0 }
        let removed = pages.count - remaining.count
        setPages(remaining, selecting: [remaining[min(selectedPageIndices.first ?? 0, remaining.count - 1)].id])
        return removed
    }

    /// Writes saved work (an editable PDF) to `url`; the source file stays unchanged.
    func saveWork(to url: URL) async throws {
        guard let id = pdfiumID else { throw PDFiumError.file }
        _ = id
        try await PDFiumService.shared.writePDF(editedPageSources(), to: url)
        savedPages = pages
        savedAnnotations = annotations
    }

    // MARK: - Annotate (docs/plans/annotate.md)

    /// Replaces page `pageID`'s annotations, mirrors them into the view and registers the undo.
    func setAnnotations(_ list: [PageAnnotation], on pageID: PageRef.ID) {
        let old = annotations[pageID] ?? []
        guard old != list else { return }
        undoManager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.setAnnotations(old, on: pageID) }
        }
        annotations[pageID] = list.isEmpty ? nil : list
        mirrorAnnotations()
    }

    func addAnnotation(_ annotation: PageAnnotation, toPageAt index: Int) {
        guard pages.indices.contains(index) else { return }
        let id = pages[index].id
        setAnnotations((annotations[id] ?? []) + [annotation], on: id)
    }

    func updateAnnotation(_ annotation: PageAnnotation) {
        guard let pageID = annotations.first(where: { $0.value.contains { $0.id == annotation.id } })?.key else { return }
        setAnnotations(annotations[pageID]!.map { $0.id == annotation.id ? annotation : $0 }, on: pageID)
    }

    func removeAnnotation(id: PageAnnotation.ID) {
        guard let pageID = annotations.first(where: { $0.value.contains { $0.id == id } })?.key else { return }
        setAnnotations(annotations[pageID]!.filter { $0.id != id }, on: pageID)
    }

    /// Rebuilds the drawn annotations on every page from the model.
    private func mirrorAnnotations() {
        for page in originalPages {
            for annotation in page.annotations where annotation is SlekPDFAnnotation { page.removeAnnotation(annotation) }
        }
        for ref in pages {
            let page = originalPages[ref.source]
            for annotation in annotations[ref.id] ?? [] {
                let drawn = SlekPDFAnnotation(annotation)
                page.addAnnotation(drawn)
                // PDFKit gives notes a popup; Slek shows comments in its own panel (Annotate step 2).
                if let popup = drawn.popup {
                    page.removeAnnotation(popup)
                    drawn.popup = nil
                }
            }
        }
    }

    /// PDFKit's copy of an annotation Slek wrote into saved work. PDFKit does not expose the private keys, so the
    /// copy is matched by type and top-left corner (PDFKit resizes note icons but keeps that corner).
    private static func isStoredCopy(_ annotation: PDFAnnotation, of stored: PageAnnotation) -> Bool {
        let type = switch stored.content {
        case .textBox: "FreeText"
        case .highlight: "Highlight"
        case .comment: "Text"
        }
        return annotation.type == type && abs(annotation.bounds.minX - stored.bounds.minX) < 0.5
            && abs(annotation.bounds.maxY - stored.bounds.maxY) < 0.5
    }

    func thumbnail(for index: Int, size: CGSize) -> NSImage? {
        if let cached = thumbnailCache[index] { return cached }
        guard let page = document?.page(at: index) else { return nil }
        let image = page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .cropBox)
        thumbnailCache[index] = image
        return image
    }
}
