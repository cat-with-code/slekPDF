import AppKit
import PDFKit

/// Annotate Tools (Figma 125:135). Esc returns to Select.
enum AnnotateTool: Equatable { case select, text, highlight, comment }

/// A comment being written or edited in the Editing Comment Card.
struct CommentDraft: Equatable {
    /// Current page index of a new comment (unused when editing).
    var pageIndex: Int
    /// Page-space point the pin's anchor (bottom-left corner) sits on.
    var anchor: CGPoint
    var quote: String?
    /// Set when editing an existing comment.
    var editing: PageAnnotation.ID?
    var text = ""
}

/// One entry of the inspector's comment list.
struct CommentEntry: Identifiable {
    let annotation: PageAnnotation
    let info: CommentInfo
    let pageIndex: Int
    var id: PageAnnotation.ID { annotation.id }
}

extension DocumentSession {
    /// Written as a comment's author; shown as "You" for comments by this Mac's user.
    static var currentAuthor: String { NSFullUserName().isEmpty ? NSUserName() : NSFullUserName() }

    /// Current page index of the page holding annotation `id`.
    func pageIndex(of id: PageAnnotation.ID) -> Int? {
        pages.firstIndex { annotations[$0.id]?.contains { $0.id == id } == true }
    }

    func annotation(_ id: PageAnnotation.ID) -> PageAnnotation? {
        annotations.values.lazy.compactMap { $0.first { $0.id == id } }.first
    }

    /// Comments in reading order: by page, then top to bottom.
    var comments: [CommentEntry] {
        pages.enumerated().flatMap { index, ref in
            (annotations[ref.id] ?? []).compactMap { annotation -> CommentEntry? in
                guard case let .comment(info) = annotation.content else { return nil }
                return CommentEntry(annotation: annotation, info: info, pageIndex: index)
            }
            .sorted { $0.annotation.bounds.maxY > $1.annotation.bounds.maxY }
        }
    }

    // MARK: Highlights

    /// Highlight text: one Highlight per page, one rectangle per selected line; the text comes from PDFium, as Copy does.
    func highlight(_ selection: PDFSelection) async {
        guard let document else { return }
        var linesByPage: [Int: [CGRect]] = [:]
        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let rect = line.bounds(for: page)
            guard !rect.isEmpty else { continue }
            linesByPage[document.index(for: page), default: []].append(rect)
        }
        guard !linesByPage.isEmpty else { return }
        let text = await text(of: selection)
        for (index, lines) in linesByPage.sorted(by: { $0.key < $1.key }) {
            let bounds = lines.dropFirst().reduce(lines[0]) { $0.union($1) }
            addAnnotation(PageAnnotation(bounds: bounds, content: .highlight(HighlightInfo(lines: lines, text: text))), toPageAt: index)
        }
    }

    // MARK: Comments

    /// Starts a new comment with its pin anchored at `point` on page `index`.
    func beginComment(onPageAt index: Int, at point: CGPoint, quote: String? = nil) {
        guard let page = document?.page(at: index) else { return }
        let box = page.bounds(for: .mediaBox)
        let size = SlekPDFAnnotation.pinSize
        let anchor = CGPoint(x: min(max(point.x, box.minX), box.maxX - size), y: min(max(point.y, box.minY), box.maxY - size))
        selectedAnnotationID = nil
        commentDraft = CommentDraft(pageIndex: index, anchor: anchor, quote: quote)
    }

    /// Add comment on a highlight: the pin sits at the highlight's top-right, quoting its text.
    func beginComment(onHighlight id: PageAnnotation.ID) {
        guard let annotation = annotation(id), case let .highlight(info) = annotation.content, let index = pageIndex(of: id) else { return }
        beginComment(onPageAt: index, at: CGPoint(x: annotation.bounds.maxX + 2, y: annotation.bounds.maxY - SlekPDFAnnotation.pinSize / 2),
                     quote: info.text.isEmpty ? nil : info.text)
    }

    func beginEditing(_ id: PageAnnotation.ID) {
        guard let annotation = annotation(id), case let .comment(info) = annotation.content else { return }
        selectedAnnotationID = id
        commentDraft = CommentDraft(pageIndex: pageIndex(of: id) ?? 0, anchor: annotation.bounds.origin, quote: info.quote,
                                    editing: id, text: info.text)
    }

    /// Save in the Editing card. Empty text is not saved (the button is disabled).
    func saveCommentDraft() {
        guard let draft = commentDraft else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commentDraft = nil
        if let id = draft.editing {
            updateComment(id) { $0.text = text }
            return
        }
        let size = SlekPDFAnnotation.pinSize
        let comment = PageAnnotation(bounds: CGRect(origin: draft.anchor, size: CGSize(width: size, height: size)),
                                     content: .comment(CommentInfo(text: text, author: Self.currentAuthor, date: Date(), quote: draft.quote)))
        addAnnotation(comment, toPageAt: draft.pageIndex)
        annotateTool = .select
        selectedAnnotationID = comment.id
    }

    func cancelCommentDraft() { commentDraft = nil }

    func setResolved(_ id: PageAnnotation.ID, _ resolved: Bool) { updateComment(id) { $0.resolved = resolved } }

    func addReply(to id: PageAnnotation.ID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        updateComment(id) { $0.replies.append(.init(author: Self.currentAuthor, text: text, date: Date())) }
    }

    private func updateComment(_ id: PageAnnotation.ID, _ change: (inout CommentInfo) -> Void) {
        guard var annotation = annotation(id), case var .comment(info) = annotation.content else { return }
        change(&info)
        annotation.content = .comment(info)
        updateAnnotation(annotation)
    }

    // MARK: Selection

    /// Selects an annotation and scrolls the page to it (comment list → pin).
    func selectAnnotation(_ id: PageAnnotation.ID, reveal: Bool = true) {
        selectedAnnotationID = id
        guard reveal, let annotation = annotation(id), let index = pageIndex(of: id), let page = document?.page(at: index) else { return }
        pdfView?.go(to: annotation.bounds.insetBy(dx: -48, dy: -96), on: page)
        currentPageIndex = index
    }

    func deleteSelectedAnnotation() {
        guard let id = selectedAnnotationID else { return }
        removeAnnotation(id: id)
    }

    // MARK: Canvas keys and menu

    /// Single-key tools on the canvas (V, H, C — from Keyboard Shortcuts), Esc, and Delete for the selection.
    /// Returns false for keys it does not handle. T (Add Khmer text) arrives with text boxes (Annotate step 3).
    func handleAnnotateKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {  // Esc
            guard annotateTool != .select || selectedAnnotationID != nil || commentDraft != nil else { return false }
            annotateTool = .select
            selectedAnnotationID = nil
            commentDraft = nil
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117, selectedAnnotationID != nil {  // ⌫, ⌦
            deleteSelectedAnnotation()
            return true
        }
        guard let shortcut = KeyShortcut(event: event) else { return false }
        let store = ShortcutStore.shared
        let tools: [(ShortcutCommand, AnnotateTool)] = [(.selectTool, .select), (.highlightTool, .highlight), (.commentTool, .comment)]
        guard let tool = tools.first(where: { store.shortcut($0.0) == shortcut })?.1 else { return false }
        annotateTool = tool
        return true
    }

    /// Right-click on an annotation (Figma Highlight: “Selected … offers Remove / Add comment”).
    func annotationMenu(for id: PageAnnotation.ID, language: AppLanguage) -> NSMenu? {
        guard let annotation = annotation(id) else { return nil }
        let copy = CopyCatalog.shared
        let menu = NSMenu()
        switch annotation.content {
        case .highlight:
            menu.addItem(MenuAction.item(copy.string(.removeHighlight, language)) { [weak self] in self?.removeAnnotation(id: id) })
            menu.addItem(MenuAction.item(copy.string(.addComment, language)) { [weak self] in self?.beginComment(onHighlight: id) })
        case let .comment(info):
            menu.addItem(MenuAction.item(copy.string(.edit, language)) { [weak self] in self?.beginEditing(id) })
            menu.addItem(MenuAction.item(copy.string(info.resolved ? .reopen : .resolve, language)) { [weak self] in
                self?.setResolved(id, !info.resolved)
            })
            menu.addItem(.separator())
            menu.addItem(MenuAction.item(copy.string(.deleteComment, language)) { [weak self] in self?.removeAnnotation(id: id) })
        case .textBox:
            return nil
        }
        return menu
    }
}
