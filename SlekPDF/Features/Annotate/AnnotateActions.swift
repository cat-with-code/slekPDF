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

/// A Khmer text box being typed in (Figma Added Text Box, Editing). `id` is set when editing an existing box.
struct TextBoxDraft: Equatable {
    var id: PageAnnotation.ID?
    var pageIndex: Int
    var bounds: CGRect
    var text: String
    var style: TextBoxStyle
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

    /// Single-key tools on the canvas (V, T, H, C — from Keyboard Shortcuts), Esc, Delete for the selection, and for a
    /// selected text box ↩ (edit) and arrows (nudge). Returns false for keys it does not handle.
    func handleAnnotateKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {  // Esc
            if textEditing != nil {  // ends typing; the box stays selected
                commitTextEditing()
                return true
            }
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
        if let box = selectedTextBox {
            switch event.keyCode {
            case 36, 76:  // ↩, enter: edit the text
                beginEditingTextBox(box.id)
                return true
            case 123, 124, 125, 126:  // arrows nudge 1 pt (⇧ 10 pt)
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                let delta: CGPoint = switch event.keyCode {
                case 123: CGPoint(x: -step, y: 0)
                case 124: CGPoint(x: step, y: 0)
                case 125: CGPoint(x: 0, y: -step)
                default: CGPoint(x: 0, y: step)
                }
                setTextBoxBounds(box.bounds.offsetBy(dx: delta.x, dy: delta.y))
                return true
            default: break
            }
        }
        let tools: [(ShortcutCommand, AnnotateTool)] = [(.selectTool, .select), (.addTextTool, .text),
                                                        (.highlightTool, .highlight), (.commentTool, .comment)]
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
            menu.addItem(MenuAction.item(copy.string(.edit, language)) { [weak self] in self?.beginEditingTextBox(id) })
            menu.addItem(.separator())
            menu.addItem(MenuAction.item(copy.string(.deleteTextBox, language)) { [weak self] in self?.removeAnnotation(id: id) })
        }
        return menu
    }
}

// MARK: - Khmer text boxes (Figma Added Text Box 125:23, Text Properties Panel 123:292)

extension DocumentSession {
    /// Width of a new box (Figma Added Text Box: 240 pt).
    static let newTextBoxWidth: CGFloat = 240

    /// The selected text box, if the selection is one.
    var selectedTextBox: PageAnnotation? {
        guard let id = selectedAnnotationID, let annotation = annotation(id), case .textBox = annotation.content else { return nil }
        return annotation
    }

    /// What Text Properties edits: the box being typed in, else the selected box. Nil = controls disabled.
    var textBoxTarget: (bounds: CGRect, style: TextBoxStyle, pageIndex: Int)? {
        if let draft = textEditing { return (draft.bounds, draft.style, draft.pageIndex) }
        guard let box = selectedTextBox, case let .textBox(_, style) = box.content else { return nil }
        return (box.bounds, style, pageIndex(of: box.id) ?? 0)
    }

    /// Add Khmer text: a new box with its top-left corner at `point`, ready for typing.
    func beginTextBox(onPageAt index: Int, at point: CGPoint) {
        guard let page = document?.page(at: index) else { return }
        commitTextEditing()
        let box = page.bounds(for: .mediaBox)
        let size = CGSize(width: min(Self.newTextBoxWidth, box.width), height: TextBoxStyle.minimumHeight)
        let origin = CGPoint(x: min(max(point.x, box.minX), box.maxX - size.width),
                             y: min(max(point.y - size.height, box.minY), box.maxY - size.height))
        selectedAnnotationID = nil
        commentDraft = nil
        textEditing = TextBoxDraft(pageIndex: index, bounds: CGRect(origin: origin, size: size), text: "", style: TextBoxStyle())
    }

    func beginEditingTextBox(_ id: PageAnnotation.ID) {
        guard let annotation = annotation(id), case let .textBox(text, style) = annotation.content, let index = pageIndex(of: id) else { return }
        commitTextEditing()
        selectedAnnotationID = id
        textEditing = TextBoxDraft(id: id, pageIndex: index, bounds: annotation.bounds, text: text, style: style)
    }

    /// Typing in the on-page editor: the box grows with the text.
    func typeInTextBox(_ text: String) {
        guard var draft = textEditing, draft.text != text else { return }
        draft.text = text
        draft.bounds = Self.fitted(draft.bounds, text: text, style: draft.style)
        textEditing = draft
    }

    /// Ends typing (Esc, a click elsewhere, another tool, Save work): one undoable change. An emptied box is removed;
    /// a new empty box is dropped.
    func commitTextEditing() {
        guard let draft = textEditing else { return }
        textEditing = nil
        let isBlank = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let bounds = Self.fitted(draft.bounds, text: draft.text, style: draft.style)
        if let id = draft.id {
            guard !isBlank else { return removeAnnotation(id: id) }
            guard var annotation = annotation(id) else { return }
            annotation.bounds = bounds
            annotation.content = .textBox(text: draft.text, style: draft.style)
            updateAnnotation(annotation)
            selectedAnnotationID = id
        } else {
            guard !isBlank else { return }
            let annotation = PageAnnotation(bounds: bounds, content: .textBox(text: draft.text, style: draft.style))
            addAnnotation(annotation, toPageAt: draft.pageIndex)
            selectedAnnotationID = annotation.id
        }
        if annotateTool == .text { annotateTool = .select }
    }

    /// Text Properties: changes the style of the box being typed in or the selected box (undoable; height refits).
    func changeTextBoxStyle(_ change: (inout TextBoxStyle) -> Void) {
        if var draft = textEditing {
            change(&draft.style)
            draft.bounds = Self.fitted(draft.bounds, text: draft.text, style: draft.style)
            textEditing = draft
            return
        }
        guard var box = selectedTextBox, case let .textBox(text, style) = box.content else { return }
        var changed = style
        change(&changed)
        guard changed != style else { return }
        box.content = .textBox(text: text, style: changed)
        box.bounds = Self.fitted(box.bounds, text: text, style: changed)
        updateAnnotation(box)
    }

    /// Moves or resizes the target box; the height always fits the text. `undoable: false` for live drag steps.
    func setTextBoxBounds(_ bounds: CGRect, undoable: Bool = true) {
        if var draft = textEditing {
            draft.bounds = Self.fitted(bounds, text: draft.text, style: draft.style)
            textEditing = draft
            return
        }
        guard var box = selectedTextBox, case let .textBox(text, style) = box.content else { return }
        let fitted = Self.fitted(bounds, text: text, style: style)
        guard fitted != box.bounds else { return }
        box.bounds = fitted
        updateAnnotation(box, undoable: undoable)
    }

    /// End of a drag: the live steps are replaced by one undoable change from `original`.
    func finishTextBoxDrag(from original: PageAnnotation) {
        guard let final = annotation(original.id), final != original else { return }
        updateAnnotation(original, undoable: false)
        updateAnnotation(final)
    }

    /// Text Properties X / Y: points from the page's top-left corner, as shown in the panel.
    func setTextBoxPosition(x: CGFloat? = nil, y: CGFloat? = nil) {
        guard let target = textBoxTarget, let page = document?.page(at: target.pageIndex) else { return }
        let box = page.bounds(for: .mediaBox)
        var bounds = target.bounds
        if let x { bounds.origin.x = box.minX + x }
        if let y { bounds.origin.y = box.maxY - y - bounds.height }
        setTextBoxBounds(bounds)
    }

    /// Position shown in Text Properties (from the page's top-left corner).
    func textBoxPosition() -> CGPoint? {
        guard let target = textBoxTarget, let page = document?.page(at: target.pageIndex) else { return nil }
        let box = page.bounds(for: .mediaBox)
        return CGPoint(x: target.bounds.minX - box.minX, y: box.maxY - target.bounds.maxY)
    }

    /// Keeps the top edge and width; the height follows the text.
    static func fitted(_ bounds: CGRect, text: String, style: TextBoxStyle) -> CGRect {
        let width = max(40, bounds.width)
        let height = KhmerGlyphOutlines.fittedHeight(text: text, width: width, style: style)
        return CGRect(x: bounds.minX, y: bounds.maxY - height, width: width, height: height)
    }
}
