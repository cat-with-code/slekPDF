import AppKit
import PDFKit

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

    /// True while an in-window dialog (password, can't open) is shown; blocks toolbar, menus and drops.
    var isModalPresented: Bool { openError != nil }

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
        await close()
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
    /// (on the next run-loop turn, once the expanded panel's field exists).
    func focusSearch() {
        guard !isInspectorVisible else {
            searchFocusRequest += 1
            return
        }
        isInspectorVisible = true
        DispatchQueue.main.async { [weak self] in self?.searchFocusRequest += 1 }
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
            let results = await PDFiumService.shared.search(id, query: query, matchCase: matchCase, wholeWord: wholeWord)
            guard !Task.isCancelled, let self else { return }
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
            return (document.index(for: page), line.bounds(for: page))
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

    func thumbnail(for index: Int, size: CGSize) -> NSImage? {
        if let cached = thumbnailCache[index] { return cached }
        guard let page = document?.page(at: index) else { return nil }
        let image = page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .cropBox)
        thumbnailCache[index] = image
        return image
    }
}
