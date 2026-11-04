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
    @Published var workspace: Workspace = .read {
        didSet {
            guard workspace != .annotate, oldValue == .annotate else { return }
            commitTextEditing()
            annotateTool = .editText
            commentDraft = nil
            selectedAnnotationID = nil
        }
    }
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
        /// Page index in its file.
        let source: Int
        var quarterTurns = 0
        /// Insert Pages from File…: the other PDF this page comes from (nil = the open document).
        var file: URL?
    }

    /// PDFs whose pages were inserted (Organize ▸ Insert Pages from File…), open in PDFium and PDFKit.
    struct InsertedDocument {
        let id: PDFiumService.DocumentID
        let pages: [PDFPage]
        let rotations: [Int]
    }

    var insertedDocuments: [URL: InsertedDocument] = [:]
    /// Rotate view (Read): turns pages on screen only; the document and saved work are unchanged.
    @Published var viewTurns: [PageRef.ID: Int] = [:] {
        didSet { if viewTurns != oldValue { mirrorPages() } }
    }

    /// The PDFium document a page belongs to.
    func documentID(for ref: PageRef) -> PDFiumService.DocumentID? {
        ref.file.map { insertedDocuments[$0]?.id } ?? pdfiumID
    }

    private func pdfPage(for ref: PageRef) -> PDFPage? {
        if let file = ref.file { return insertedDocuments[file]?.pages[safe: ref.source] }
        return originalPages[safe: ref.source]
    }

    private func baseRotation(for ref: PageRef) -> Int {
        if let file = ref.file { return insertedDocuments[file]?.rotations[safe: ref.source] ?? 0 }
        return originalRotations[safe: ref.source] ?? 0
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
    /// Annotate Tools (Figma 125:135): Edit PDF text (E, the default: click a line to edit it), Select (V),
    /// Add Khmer text (T), Highlight (H), Comment (C); Esc returns to Edit PDF text.
    @Published var annotateTool: AnnotateTool = .editText {
        didSet { if annotateTool != oldValue, annotateTool != .text, textEditing != nil { commitTextEditing() } }
    }
    /// The annotation selected on the page or in the comment list (drawn with the accent outline / selected pin).
    @Published var selectedAnnotationID: PageAnnotation.ID? {
        didSet { if selectedAnnotationID != oldValue { mirrorAnnotations() } }
    }
    /// A comment being written (new) or edited, shown as the Editing Comment Card.
    @Published var commentDraft: CommentDraft?
    /// A Khmer text box being typed in (new or existing); drawn by the on-page editor, not by the page, until committed.
    @Published var textEditing: TextBoxDraft? {
        didSet { if textEditing?.id != oldValue?.id || (textEditing == nil) != (oldValue == nil) { mirrorAnnotations() } }
    }
    private var savedAnnotations: [PageRef.ID: [PageAnnotation]] = [:]

    var hasUnsavedChanges: Bool {
        pages != savedPages || annotations != savedAnnotations || ocrResults != savedOCR || !(textEditing?.text.isEmpty ?? true)
            || recoveredEntryID != nil
    }

    // MARK: Khmer OCR (Figma 04 / 12 / 39 / 41)

    /// Recognized text per page (the PageRef, like annotations).
    @Published private(set) var ocrResults: [PageRef.ID: OCRPage] = [:]
    private var savedOCR: [PageRef.ID: OCRPage] = [:]
    /// Recognition settings (Figma Recognition Settings 129:231).
    @Published var ocrSettings = OCRSettings()
    /// The recognition in progress (also when it runs in the background).
    @Published var ocrJob: OCRJob?
    /// OCR Review Panel (129:111): which lines are listed, and the one being reviewed.
    @Published var ocrReviewFilter: OCRReviewFilter = .uncertain
    @Published var ocrReviewItem: OCRItemRef?
    // MARK: Export (Figma 05–09, 14, 18, 36, 37)

    @Published var exportSettings = ExportSettings()
    /// Tables for Excel / Word (detected, or marked with Select table region), editable in the Excel preview.
    @Published var exportTables: [ExportTable] = []
    @Published var exportTablesDetected = false
    /// Select table region: the next drag on the source page marks a table.
    @Published var exportTableSelecting = false
    /// The export being written (37 Exporting… toast).
    @Published var exportJob: ExportJob?
    /// Destination waiting for 36 (already exists) or 14 (could not save).
    var pendingExport: PendingExport?
    /// Bumped whenever pages, annotations or OCR change (the export preview rebuilds; a recovery copy is scheduled).
    @Published private(set) var contentRevision = 0 {
        didSet {
            changesSinceSave += 1
            scheduleRecoveryCopy()
        }
    }

    // MARK: Recovery (Figma 15)

    /// This window's recovery copy.
    let recoveryID = UUID()
    var recoveryStore = RecoveryStore.shared
    /// Edits since the work was opened or saved (shown in 15).
    var changesSinceSave = 0
    /// Opened from a recovery copy: unsaved until saved; the copy is removed on save or close.
    var recoveredEntryID: UUID?
    /// The copy offered by 15.
    var recoveryOffer: RecoveryStore.Entry?
    private var recoveryTask: Task<Void, Never>?

    /// Writes the recovery copy a moment after the last change (Preferences ▸ Keep recovery copies).
    private func scheduleRecoveryCopy() {
        recoveryTask?.cancel()
        guard RecoveryStore.isEnabled, document != nil else { return }
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.hasUnsavedChanges, self.document != nil else { return }
            try? await self.recoveryStore.write(self, id: self.recoveryID)
        }
    }

    /// Saved or closed: no recovery copy is needed any more.
    func removeRecoveryCopies() {
        recoveryTask?.cancel()
        recoveryStore.remove(recoveryID)
        if let recovered = recoveredEntryID { recoveryStore.remove(recovered) }
        recoveredEntryID = nil
    }

    /// 15 Open recovered work.
    func openRecovered(_ entry: RecoveryStore.Entry) async {
        guard let url = try? recoveryStore.openableCopy(of: entry) else { return }
        await open(url)
        guard document != nil else { return }
        recoveredEntryID = entry.id
        changesSinceSave = entry.changes
    }

    /// Pages waiting for “Recognize again” (39).
    var pendingOCRPages: [Int] = []
    var ocrCancel: CancelFlag?
    var selectedPageIndices: [Int] { pages.indices.filter { selectedPageIDs.contains(pages[$0].id) } }
    /// The open organize dialog (20 Delete pages?, 42 Save work).
    @Published var organizeDialog: OrganizeDialog?
    /// Where Save work wrote last; later saves go there without asking again.
    var workURL: URL?
    /// "Don’t ask again this session" in 20 Delete pages?
    var skipDeleteConfirmation = false

    enum OrganizeDialog: Equatable {
        case deletePages, saveWork, merge, split, closeConfirm, recognizing, recognizeAgain, exportExists, exportFailed,
             noTables, excelFailed, recovered
    }

    /// Every open session, for the quit check (Save changes before closing?).
    static let all = NSHashTable<DocumentSession>.weakObjects()
    weak var window: NSWindow?
    /// Set by "Save" in 16 Save changes before closing?: close the window once the work is saved.
    var closeAfterSave = false
    /// Home (Title Bar): after the 16 Save changes? decision, go back to the start screen instead of closing the window.
    var goHomeAfterDecision = false
    /// The window is in full screen (no window controls: the title bar drops their space).
    @Published var isFullScreen = false
    /// Set by "Don’t save": the window may close with unsaved changes.
    var discardChanges = false
    /// The close was part of quitting the app: quit again once this window is closed.
    var quitAfterClose = false

    init() { Self.all.add(self) }

    /// The edited document's pages for PDFium (current order and rotation).
    func editedPageSources(_ indices: [Int]? = nil) -> [PDFiumService.PageSource] {
        guard let id = pdfiumID else { return [] }
        return (indices ?? Array(pages.indices)).map {
            .open(documentID(for: pages[$0]) ?? id, page: pages[$0].source, quarterTurns: pages[$0].quarterTurns,
                  annotations: annotations[pages[$0].id] ?? [],
                  ocr: ocrResults[pages[$0].id])
        }
    }

    /// True while an in-window dialog (password, can't open) or panel is shown; blocks toolbar, menus and drops.
    var isModalPresented: Bool { openError != nil || panel != nil || organizeDialog != nil }

    func open(_ url: URL) async {
        dismissOpenError()
        let didAccess = url.startAccessingSecurityScopedResource()
        let name = url.lastPathComponent
        let pdf = PDFDocument(url: url)
        pdf?.delegate = SlekPageFactory.shared  // Slek's annotations are drawn as part of the page (sharp)
        guard let pdf, pdf.pageCount > 0 else {
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
        let storedOCR = await PDFiumService.shared.ocrPages(opened.id)
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
        for source in storedOCR.keys where originalPages.indices.contains(source) {
            // PDFKit's copy of the hidden OCR note (at the page origin).
            let page = originalPages[source]
            for note in page.annotations where note.type == "Text" && abs(note.bounds.minX) < 0.5 && abs(note.bounds.maxY) < 0.5 {
                if let popup = note.popup { page.removeAnnotation(popup) }
                page.removeAnnotation(note)
            }
        }
        ocrResults = Dictionary(uniqueKeysWithValues: storedOCR.compactMap { source, ocr in
            pages.indices.contains(source) ? (pages[source].id, ocr) : nil
        })
        savedOCR = ocrResults
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
        removeRecoveryCopies()
        changesSinceSave = 0
        if let id = pdfiumID { await PDFiumService.shared.close(id) }
        pdfiumID = nil
        for inserted in insertedDocuments.values { await PDFiumService.shared.close(inserted.id) }
        insertedDocuments = [:]
        viewTurns = [:]
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        document = nil
        url = nil
        thumbnailCache = [:]
        pages = []
        savedPages = []
        annotations = [:]
        savedAnnotations = [:]
        ocrCancel?.cancel()
        ocrJob = nil
        ocrResults = [:]
        savedOCR = [:]
        ocrReviewItem = nil
        textEditing = nil  // first: changing the tool would commit it
        annotateTool = .editText
        selectedAnnotationID = nil
        commentDraft = nil
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
        // Each page is read from the PDF it comes from (inserted pages have their own); a page Slek recognized gives
        // its reviewed OCR text, not the PDF's own layer (often another program's OCR, e.g. Khmer read as Thai).
        var parts: [String] = []
        var ocrPage: (ref: PageRef, rects: [CGRect])?
        func flushOCR() {
            guard let (ref, rects) = ocrPage, let ocr = ocrResults[ref.id] else { return }
            ocrPage = nil
            // Each OCR line once, in reading order, when the selection covers at least half of its height.
            let picked = ocr.lines.filter { line in
                rects.contains { rect in
                    let overlap = line.bounds.intersection(rect.insetBy(dx: -2, dy: 0))
                    return !overlap.isNull && overlap.height >= line.bounds.height * 0.5
                }
            }
            if !picked.isEmpty { parts.append(KhmerNormalizer.normalize(picked.map(\.displayText).joined(separator: "\n"))) }
        }
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let index = document.index(for: page)
            let ref = pages.indices.contains(index) ? pages[index] : nil
            let rect = line.bounds(for: page)
            if let ref, let ocr = ocrResults[ref.id], !ocr.lines.isEmpty {
                if ocrPage?.ref.id != ref.id { flushOCR() }
                ocrPage = (ref, (ocrPage?.rects ?? []) + [rect])
                continue
            }
            flushOCR()
            let text = await PDFiumService.shared.copyText(ref.flatMap(documentID(for:)) ?? id, lines: [(ref?.source ?? index, rect)])
            if !text.isEmpty { parts.append(text) }
        }
        flushOCR()
        return parts.joined(separator: "\n")
    }

    func copy(_ selection: PDFSelection, language: AppLanguage) {
        Task {
            let text = await text(of: selection)
            guard !text.isEmpty else {
                // Text in a legacy Khmer font (or with a broken glyph map) is not copied as gibberish.
                if !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    toasts.show(.default, CopyCatalog.shared.string(.recognizeTextToEnableSearchingAndC, language))
                }
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: - Page edit operations (undoable)

    /// PDFium reports pages of the source file; show them at their current place (deleted pages drop out).
    private func currentPageMatches(_ matches: [PDFiumMatch]) -> [PDFiumMatch] {
        matches.compactMap { match in
            pages.firstIndex { $0.source == match.page && $0.file == nil }.map {
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
        contentRevision += 1
        selectedPageIDs = selection ?? selectedPageIDs.filter { id in newPages.contains { $0.id == id } }
        mirrorPages()
        if isSearchActive { scheduleSearch() }
    }

    private func mirrorPages() {
        guard let document else { return }
        while document.pageCount > 0 { document.removePage(at: document.pageCount - 1) }
        for (index, ref) in pages.enumerated() {
            guard let page = pdfPage(for: ref) else { continue }
            page.rotation = (baseRotation(for: ref) + (ref.quarterTurns + (viewTurns[ref.id] ?? 0)) * 90) % 360
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
        commitTextEditing()  // text still being typed is part of the work
        try await PDFiumService.shared.writePDF(editedPageSources(), to: url)
        savedPages = pages
        savedAnnotations = annotations
        savedOCR = ocrResults
        changesSinceSave = 0
        removeRecoveryCopies()
    }

    /// Replaces page `pageID`'s OCR result (recognition, a correction, Mark reviewed) and registers the undo.
    func setOCR(_ ocr: OCRPage?, for pageID: PageRef.ID) {
        let old = ocrResults[pageID]
        guard old != ocr else { return }
        undoManager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.setOCR(old, for: pageID) }
        }
        ocrResults[pageID] = ocr
        contentRevision += 1
    }

    // MARK: - Annotate (docs/plans/annotate.md)

    /// Replaces page `pageID`'s annotations, mirrors them into the view and registers the undo
    /// (not while dragging: `undoable: false` for the live steps, one undo for the whole drag).
    func setAnnotations(_ list: [PageAnnotation], on pageID: PageRef.ID, undoable: Bool = true) {
        let old = annotations[pageID] ?? []
        guard old != list else { return }
        if undoable {
            undoManager?.registerUndo(withTarget: self) { session in
                MainActor.assumeIsolated { session.setAnnotations(old, on: pageID) }
            }
        }
        annotations[pageID] = list.isEmpty ? nil : list
        contentRevision += 1
        if let selected = selectedAnnotationID, !list.contains(where: { $0.id == selected }),
           !annotations.values.contains(where: { $0.contains { $0.id == selected } }) {
            selectedAnnotationID = nil
        }
        mirrorAnnotations()
    }

    func addAnnotation(_ annotation: PageAnnotation, toPageAt index: Int) {
        guard pages.indices.contains(index) else { return }
        let id = pages[index].id
        setAnnotations((annotations[id] ?? []) + [annotation], on: id)
    }

    func updateAnnotation(_ annotation: PageAnnotation, undoable: Bool = true) {
        guard let pageID = annotations.first(where: { $0.value.contains { $0.id == annotation.id } })?.key else { return }
        setAnnotations(annotations[pageID]!.map { $0.id == annotation.id ? annotation : $0 }, on: pageID, undoable: undoable)
    }

    func removeAnnotation(id: PageAnnotation.ID) {
        guard let pageID = annotations.first(where: { $0.value.contains { $0.id == id } })?.key else { return }
        setAnnotations(annotations[pageID]!.filter { $0.id != id }, on: pageID)
    }

    /// Rebuilds the drawn annotations on every page from the model.
    private func mirrorAnnotations() {
        var touched: [PDFPage] = []
        for page in originalPages + insertedDocuments.values.flatMap(\.pages) {
            let old = page.annotations.filter { $0 is SlekPDFAnnotation }
            if !old.isEmpty { touched.append(page) }
            for annotation in old { page.removeAnnotation(annotation) }
        }
        for ref in pages {
            guard let page = pdfPage(for: ref) else { continue }
            for annotation in annotations[ref.id] ?? [] where annotation.id != textEditing?.id {
                let drawn = SlekPDFAnnotation(annotation, selected: annotation.id == selectedAnnotationID)
                page.addAnnotation(drawn)
                if !touched.contains(page) { touched.append(page) }
                // PDFKit gives notes a popup; Slek shows comments in its own panel (Annotate step 2).
                if let popup = drawn.popup {
                    page.removeAnnotation(popup)
                    drawn.popup = nil
                }
            }
        }
        // On screen they are drawn by an overlay over the pages, at once (PDFKit's page images update seconds later).
        if !touched.isEmpty { (pdfView as? KhmerPDFView)?.redrawAnnotations() }
    }

    /// PDFKit's copy of an annotation Slek wrote into saved work. PDFKit does not expose the private keys, so the
    /// copy is matched by type and top-left corner (PDFKit resizes note icons but keeps that corner).
    private static func isStoredCopy(_ annotation: PDFAnnotation, of stored: PageAnnotation) -> Bool {
        let type = switch stored.content {
        case .textBox, .textEdit: "FreeText"
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

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
