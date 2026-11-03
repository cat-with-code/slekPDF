import AppKit
import PDFKit

/// Annotate Tools (Figma 125:135). Edit PDF text is the default: hover a line and click it to edit; Esc returns to it.
enum AnnotateTool: Equatable { case editText, select, text, highlight, comment }

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
/// With `line`, it is a line of the PDF's own text being edited (Figma PDF Text Line, Editing).
struct TextBoxDraft: Equatable {
    var id: PageAnnotation.ID?
    var pageIndex: Int
    var bounds: CGRect
    var text: String
    var style: TextBoxStyle
    var line: LineEdit?
    /// Page point the caret goes to when the editor opens (where the line was clicked).
    var caret: CGPoint?
    /// One typing session: a new draft gets a new on-page editor even on the same page.
    var session = UUID()

    struct LineEdit: Equatable {
        var original: String
        var cover: CGRect
        var baseline: CGFloat
        var coverColor: [CGFloat]
    }

    /// The edit this draft would save.
    var textEdit: TextEditInfo? {
        line.map { TextEditInfo(original: $0.original, text: text, style: style, cover: $0.cover, baseline: $0.baseline, coverColor: $0.coverColor) }
    }
}

/// A piece of the page's text a click can edit: the PDF's own text, or a Khmer OCR line on a recognized scan.
struct EditableLine: Equatable {
    var text: String
    var box: CGRect
    var fontSize: CGFloat
    var baseline: CGFloat
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
        annotateTool = .editText
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
            guard annotateTool != .editText || selectedAnnotationID != nil || commentDraft != nil else { return false }
            annotateTool = .editText
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
        if let box = selectedTextBox, case .textBox = box.content {
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
        let tools: [(ShortcutCommand, AnnotateTool)] = [(.selectTool, .select), (.editTextTool, .editText), (.addTextTool, .text),
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
        case .textEdit:
            menu.addItem(MenuAction.item(copy.string(.edit, language)) { [weak self] in self?.beginEditingTextBox(id) })
            menu.addItem(.separator())
            menu.addItem(MenuAction.item(copy.string(.restoreOriginalText, language)) { [weak self] in self?.removeAnnotation(id: id) })
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

    /// What Text Properties edits: the box or line being typed in, else the selected box or edited line.
    /// Nil = controls disabled.
    var textBoxTarget: (bounds: CGRect, style: TextBoxStyle, pageIndex: Int)? {
        if let draft = textEditing { return (draft.bounds, draft.style, draft.pageIndex) }
        if let box = selectedTextBox, case let .textBox(_, style) = box.content { return (box.bounds, style, pageIndex(of: box.id) ?? 0) }
        if let id = selectedAnnotationID, let edited = annotation(id), case let .textEdit(info) = edited.content {
            return (edited.bounds, info.style, pageIndex(of: id) ?? 0)
        }
        return nil
    }

    /// Whether Text Properties is about a line of the PDF's own text (no Position; Restore original text).
    var textTargetIsPDFLine: Bool {
        if let draft = textEditing { return draft.line != nil }
        if let id = selectedAnnotationID, let edited = annotation(id), case .textEdit = edited.content { return true }
        return false
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

    func beginEditingTextBox(_ id: PageAnnotation.ID, caret: CGPoint? = nil) {
        guard let annotation = annotation(id), let index = pageIndex(of: id) else { return }
        switch annotation.content {
        case let .textBox(text, style):
            commitTextEditing()
            selectedAnnotationID = id
            textEditing = TextBoxDraft(id: id, pageIndex: index, bounds: annotation.bounds, text: text, style: style)
        case let .textEdit(info):
            commitTextEditing()
            selectedAnnotationID = id
            textEditing = TextBoxDraft(id: id, pageIndex: index, bounds: annotation.bounds, text: info.text, style: info.style,
                                       line: .init(original: info.original, cover: info.cover, baseline: info.baseline, coverColor: info.coverColor),
                                       caret: caret)
        default:
            return
        }
    }

    /// Typing in the on-page editor: the box grows with the text.
    func typeInTextBox(_ text: String) {
        guard var draft = textEditing, draft.text != text else { return }
        draft.text = text
        draft.bounds = layout(draft)
        textEditing = draft
    }

    /// Where a draft's text goes: a text box keeps its top and width; an edited line grows from the line's start.
    func layout(_ draft: TextBoxDraft) -> CGRect {
        guard let edit = draft.textEdit else { return Self.fitted(draft.bounds, text: draft.text, style: draft.style) }
        return edit.layoutBounds(pageBox: document?.page(at: draft.pageIndex)?.bounds(for: .mediaBox) ?? .infinite)
    }

    /// Ends typing (Esc, a click elsewhere, another tool, Save work): one undoable change. An emptied box is removed;
    /// a new empty box is dropped.
    func commitTextEditing() {
        guard let draft = textEditing else { return }
        if let edit = draft.textEdit { return commitLineEdit(draft, edit) }
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
        if annotateTool == .text { annotateTool = .editText }
    }

    /// An edited line is kept even when emptied (that deletes the line from the page); a new edit that changed
    /// nothing is dropped. One undo step.
    private func commitLineEdit(_ draft: TextBoxDraft, _ edit: TextEditInfo) {
        textEditing = nil
        let bounds = layout(draft)
        if let id = draft.id {
            guard var annotation = annotation(id) else { return }
            annotation.bounds = bounds
            annotation.content = .textEdit(edit)
            if annotation != self.annotation(id) { updateAnnotation(annotation) }
            selectedAnnotationID = id
        } else {
            guard edit.text != edit.original else { return }
            let annotation = PageAnnotation(bounds: bounds, content: .textEdit(edit))
            addAnnotation(annotation, toPageAt: draft.pageIndex)
            selectedAnnotationID = annotation.id
        }
    }

    /// Text Properties: changes the style of the box being typed in or the selected box (undoable; height refits).
    func changeTextBoxStyle(_ change: (inout TextBoxStyle) -> Void) {
        if var draft = textEditing {
            change(&draft.style)
            draft.bounds = layout(draft)
            textEditing = draft
            return
        }
        if let id = selectedAnnotationID, var edited = annotation(id), case var .textEdit(info) = edited.content {
            let before = info.style
            change(&info.style)
            guard info.style != before else { return }
            edited.content = .textEdit(info)
            edited.bounds = info.layoutBounds(pageBox: pageIndex(of: id).flatMap { document?.page(at: $0)?.bounds(for: .mediaBox) } ?? .infinite)
            return updateAnnotation(edited)
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
            guard draft.line == nil else { return }  // an edited line keeps its place
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

// MARK: - Edit PDF text (Figma PDF Text Line 556:525)

extension DocumentSession {
    /// The text a click can edit on page `index`: the PDF's own text where it is readable, else the page's Khmer OCR
    /// lines. Nil when the page has neither (a scan not recognized yet, or a legacy-font layer).
    func editableLines(onPageAt index: Int) async -> [EditableLine]? {
        guard pages.indices.contains(index), let id = pdfiumID else { return nil }
        let ref = pages[index]
        let doc = documentID(for: ref) ?? id
        let segments = await PDFiumService.shared.editableSegments(doc, page: ref.source)
        if !segments.isEmpty {
            return segments.map { EditableLine(text: $0.text, box: $0.box, fontSize: $0.fontSize, baseline: $0.baseline) }
        }
        guard let ocr = ocrResults[ref.id], !ocr.lines.isEmpty else { return nil }
        // OCR boxes have no baseline: Khmer sits about a quarter of the line above the box's bottom (subscripts below).
        return ocr.lines.map { line in
            EditableLine(text: KhmerNormalizer.normalize(line.displayText), box: line.bounds,
                         fontSize: line.bounds.height * 0.62, baseline: line.bounds.minY + line.bounds.height * 0.27)
        }
    }

    /// Edit PDF text: a click at `point` (page space) opens the line under it for typing, with its text. An edit
    /// already on that line opens again. Returns false when there is no line there (or the page needs OCR first,
    /// which is shown as a hint).
    @discardableResult
    func beginEditingLine(onPageAt index: Int, at point: CGPoint, language: AppLanguage = .km) async -> Bool {
        guard pages.indices.contains(index), document?.page(at: index) != nil else { return false }
        commitTextEditing()
        if let existing = (annotations[pages[index].id] ?? []).last(where: {
            if case .textEdit = $0.content { $0.bounds.insetBy(dx: -1, dy: -1).contains(point) } else { false }
        }) {
            beginEditingTextBox(existing.id, caret: point)
            return true
        }
        guard let lines = await editableLines(onPageAt: index) else {
            toasts.show(.default, CopyCatalog.shared.string(.clickALineOfTextOnThePageToEdit, language))
            return false
        }
        // The smallest piece of text under the click (a word group in a table cell rather than the row).
        guard let line = lines.filter({ $0.box.insetBy(dx: -2, dy: -2).contains(point) })
            .min(by: { $0.box.width * $0.box.height < $1.box.width * $1.box.height }) else { return false }
        let ref = pages[index]
        let cover = line.box.insetBy(dx: -1, dy: -1)
        let coverColor = await PDFiumService.shared.colorAround(documentID(for: ref) ?? pdfiumID!, rect: cover, page: ref.source)
        // The size at which the line's own text, set in the bundled Khmer font, is as tall as it is on the page
        // (PDFium's font size is wrong for PDFs that scale text with a matrix, and OCR has none).
        var style = TextBoxStyle()
        let ink = KhmerGlyphOutlines.inkHeight(text: line.text, style: style)
        let fontSize = ink > 0.2 ? min(200, max(4, line.box.height / ink)) : max(4, line.box.height * 0.62)
        style.fontSize = fontSize
        style.lineSpacing = max(1.2, line.box.height / fontSize)
        var draft = TextBoxDraft(pageIndex: index, bounds: cover, text: line.text, style: style,
                                 line: .init(original: line.text, cover: cover, baseline: line.baseline, coverColor: coverColor),
                                 caret: point)
        draft.bounds = layout(draft)
        selectedAnnotationID = nil
        commentDraft = nil
        textEditing = draft
        return true
    }
}
