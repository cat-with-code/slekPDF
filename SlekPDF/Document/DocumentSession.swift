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
                               height: view.bounds.height - margins.top - margins.bottom)
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return }
        view.autoScales = false
        view.scaleFactor = min(available.width / size.width, available.height / size.height)
        show(page)
    }

    func pdfViewDidChangePage(_ index: Int) { currentPageIndex = index }
    func pdfViewDidChangeScale(_ scale: CGFloat) { scaleFactor = scale }

    func thumbnail(for index: Int, size: CGSize) -> NSImage? {
        if let cached = thumbnailCache[index] { return cached }
        guard let page = document?.page(at: index) else { return nil }
        let image = page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .cropBox)
        thumbnailCache[index] = image
        return image
    }
}
