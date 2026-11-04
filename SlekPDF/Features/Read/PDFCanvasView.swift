import PDFKit
import SwiftUI

/// Figma "Document Canvas" (109:197): PDFKit's PDFView for page display.
/// Text selection/copy in PDFView uses PDFKit's Khmer text, which is unreliable (docs/spikes/01);
/// copy will be routed through PDFium before release.
struct PDFCanvasView: NSViewRepresentable {
    @ObservedObject var session: DocumentSession
    @Environment(\.appLanguage) private var language
    /// Space above the first page for the floating page navigation (12 pt + 36 pt card + 12 pt).
    static let topInset: CGFloat = 60

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> PDFView {
        let view = KhmerPDFView()
        view.copyHandler = { [weak session, weak view] selection in session?.copy(selection, language: view?.language ?? .km) }
        view.session = session
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        view.backgroundColor = DSNSColor.backgroundCanvas
        view.postsFrameChangedNotifications = true
        session.pdfView = view
        // Over the pages: Slek's annotations (KhmerPDFView's own overlays), then search matches.
        let highlights = SearchHighlightView(frame: view.bounds)
        highlights.autoresizingMask = [.width, .height]
        highlights.pdfView = view
        view.addSubview(highlights)
        context.coordinator.highlights = highlights
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        (view as? KhmerPDFView)?.language = language
        (view as? KhmerPDFView)?.syncTextEditor()
        if view.document !== session.document {
            view.document = session.document
            DispatchQueue.main.async {
                Self.applyTopInset(to: view)
                session.applyFitPage()
            }
        }
        context.coordinator.highlights?.update(matches: session.searchResults, current: session.currentMatchIndex)
    }

    /// Pages scroll underneath the floating card, but start below it.
    static func applyTopInset(to view: PDFView) {
        guard let scroll = view.documentView?.enclosingScrollView else { return }
        scroll.automaticallyAdjustsContentInsets = false
        if scroll.contentInsets.top != topInset {
            scroll.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        private let session: DocumentSession
        private var tokens: [NSObjectProtocol] = []
        var highlights: SearchHighlightView?
        private var lastWindowSize: CGSize?

        init(session: DocumentSession) { self.session = session }

        func observe(_ view: PDFView) {
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view, let page = view.currentPage, let document = view.document else { return }
                    self?.session.pdfViewDidChangePage(document.index(for: page))
                }
            })
            // Re-fit only when the window is resized. Showing or hiding the page sidebar or inspector also changes
            // this view's size, but must never change the zoom.
            tokens.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let size = view?.window?.frame.size, size != self.lastWindowSize else { return }
                    self.lastWindowSize = size
                    self.session.applyFitPage()
                }
            })
            // Redraw search highlights while scrolling.
            if let clip = view.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                tokens.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak view] _ in
                    MainActor.assumeIsolated {
                        self?.highlights?.needsDisplay = true
                        (view as? KhmerPDFView)?.redrawAnnotations()
                        (view as? KhmerPDFView)?.syncTextEditor()
                    }
                })
            }
            tokens.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view else { return }
                    self?.session.pdfViewDidChangeScale(view.scaleFactor)
                    self?.highlights?.needsDisplay = true
                    (view as? KhmerPDFView)?.redrawAnnotations()
                    (view as? KhmerPDFView)?.syncTextEditor()
                }
            })
        }

        func stopObserving() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
        }
    }
}

/// Draws PDFium search matches over the PDFView. Rectangles come from PDFium in PDF page space and are
/// mapped with `PDFView.convert(_:from:)` (handles zoom, rotation and crop) — never from PDFKit's Khmer text.
final class SearchHighlightView: NSView {
    weak var pdfView: PDFView?
    private var matches: [PDFiumMatch] = []
    private var current: Int?

    override var isFlipped: Bool { pdfView?.isFlipped ?? false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(matches: [PDFiumMatch], current: Int?) {
        guard matches != self.matches || current != self.current else { return }
        self.matches = matches
        self.current = current
        needsDisplay = true
    }

    /// PDFium returns one rectangle per text run; draw one box per line instead.
    static func mergedByLine(_ rects: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        for rect in rects.sorted(by: { $0.minX < $1.minX }) {
            if let index = lines.firstIndex(where: { min($0.maxY, rect.maxY) - max($0.minY, rect.minY) > min($0.height, rect.height) * 0.5 }) {
                lines[index] = lines[index].union(rect)
            } else {
                lines.append(rect)
            }
        }
        return lines
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let document = pdfView.document, !matches.isEmpty else { return }
        let visible = Set(pdfView.visiblePages.map { document.index(for: $0) })
        let fill = DSNSColor.annotationHighlight.withAlphaComponent(0.5)
        for (index, match) in matches.enumerated() where visible.contains(match.page) {
            guard let page = document.page(at: match.page) else { continue }
            for rect in Self.mergedByLine(match.rects) {
                let frame = pdfView.convert(rect, from: page).insetBy(dx: -1, dy: -1)
                let path = NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2)
                fill.setFill()
                path.fill()
                if index == current {
                    DSNSColor.accentDefault.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
        }
    }
}

/// PDFView whose Copy (⌘C, Edit ▸ Copy, context menu) uses PDFium + the Khmer rebuilder instead of
/// PDFKit's drawing-order text.
final class KhmerPDFView: PDFView {
    var copyHandler: ((PDFSelection) -> Void)?
    /// Annotate (Figma 03): the canvas handles the tools' clicks, single-key tools and the annotation menu.
    weak var session: DocumentSession?
    var language: AppLanguage = .km

    override func copy(_ sender: Any?) {
        guard let selection = currentSelection, let copyHandler else { return super.copy(sender) }
        copyHandler(selection)
    }

    private var annotating: DocumentSession? { session?.workspace == .annotate ? session : nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Slek's annotations are drawn over the pages (highlights multiply, the rest covers).
        for kind in [SlekAnnotationOverlay.Kind.highlights, .content] {
            let overlay = SlekAnnotationOverlay(kind: kind, frame: bounds)
            overlay.pdfView = self
            addSubview(overlay)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The page under `event` and the point on it (page space).
    private func pagePoint(_ event: NSEvent) -> (index: Int, page: PDFPage, point: CGPoint)? {
        let location = convert(event.locationInWindow, from: nil)
        guard let document, let page = page(for: location, nearest: false) else { return nil }
        return (document.index(for: page), page, convert(location, to: page))
    }

    /// Slek's annotation under `point`, topmost first.
    private func slekAnnotation(on page: PDFPage, at point: CGPoint) -> SlekPDFAnnotation? {
        page.annotations.reversed().lazy.compactMap { $0 as? SlekPDFAnnotation }.first { $0.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let session = annotating, let hit = pagePoint(event) else { return super.mouseDown(with: event) }
        session.commitTextEditing()  // a click outside the box being typed in ends typing
        window?.makeFirstResponder(self)
        let annotation = slekAnnotation(on: hit.page, at: hit.point)
        switch session.annotateTool {
        case .comment:
            session.beginComment(onPageAt: hit.index, at: hit.point)
        case .highlight:
            super.mouseDown(with: event)
            finishHighlight()
        case .text where annotation == nil:
            session.beginTextBox(onPageAt: hit.index, at: hit.point)
        case .editText where annotation == nil || annotation?.isTextEdit == true:
            // Edit PDF text: the line under the click opens for typing (an edited line opens again).
            if let annotation { return session.beginEditingTextBox(annotation.model.id, caret: hit.point) }
            let (index, point, language) = (hit.index, hit.point, language)
            Task { await session.beginEditingLine(onPageAt: index, at: point, language: language) }
        case .select, .text, .editText:
            guard let annotation else {
                session.selectedAnnotationID = nil
                return super.mouseDown(with: event)
            }
            guard case .textBox = annotation.model.content else {
                return session.selectAnnotation(annotation.model.id, reveal: false)
            }
            if event.clickCount >= 2 { return session.beginEditingTextBox(annotation.model.id) }
            let handle = annotation.handle(at: hit.point)
            session.selectAnnotation(annotation.model.id, reveal: false)
            // A click (no drag) on the box starts typing in it; dragging moves it, handles resize.
            if !dragTextBox(annotation.model, handle: handle, on: hit.page, from: hit.point), handle == nil {
                session.beginEditingTextBox(annotation.model.id)
            }
        }
    }

    /// Drag to move; handles resize (the left/right edge sets the width; the height follows the text).
    /// One undo for the whole drag. Returns whether the mouse moved (a plain click returns false).
    @discardableResult
    private func dragTextBox(_ original: PageAnnotation, handle: SlekPDFAnnotation.Handle?, on page: PDFPage, from start: CGPoint) -> Bool {
        guard let session = annotating, let window else { return false }
        let limits = page.bounds(for: .mediaBox)
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(convert(next.locationInWindow, from: nil), to: page)
            let dx = point.x - start.x, dy = point.y - start.y
            if next.type == .leftMouseUp, !moved { return false }
            // Small hand movement during a click is not a drag (3 pt on the page).
            guard moved || hypot(dx, dy) >= 3 else { continue }
            moved = true
            var bounds = original.bounds
            switch handle {
            case .left?, .topLeft?, .bottomLeft?:
                let minX = min(bounds.maxX - 40, max(limits.minX, bounds.minX + dx))
                bounds = CGRect(x: minX, y: bounds.minY, width: bounds.maxX - minX, height: bounds.height)
            case .right?, .topRight?, .bottomRight?:
                bounds.size.width = max(40, min(limits.maxX - bounds.minX, bounds.width + dx))
            case .top?, .bottom?, nil:
                bounds.origin.x = min(max(limits.minX, bounds.minX + dx), limits.maxX - bounds.width)
                bounds.origin.y = min(max(limits.minY, bounds.minY + dy), limits.maxY - bounds.height)
            }
            session.setTextBoxBounds(bounds, undoable: false)
            if next.type == .leftMouseUp { break }
        }
        session.finishTextBoxDrag(from: original)
        return true
    }

    // MARK: Text box editor

    private var editor: TextBoxEditor?
    private var editorKey: UUID?

    /// Shows, moves or removes the on-page editor to match `session.textEditing` (also on scroll and zoom).
    func syncTextEditor() {
        guard let session, let draft = session.textEditing, let page = document?.page(at: draft.pageIndex) else {
            if let editor {
                editor.removeFromSuperview()
                self.editor = nil
                editorKey = nil
                if window?.firstResponder == nil || window?.firstResponder === editor { window?.makeFirstResponder(self) }
            }
            return
        }
        var isNew = false
        if editor == nil || editorKey != draft.session {
            editor?.removeFromSuperview()
            let created = TextBoxEditor(text: draft.text)
            created.setAccessibilityLabel(CopyCatalog.shared.string(.editAnAddedTextBox, language))
            created.onChange = { [weak session] text in session?.typeInTextBox(text) }
            created.onEnd = { [weak session] in session?.commitTextEditing() }
            addSubview(created)
            editor = created
            editorKey = draft.session
            window?.makeFirstResponder(created)
            isNew = true
        }
        guard let editor else { return }
        editor.apply(draft.style, scale: scaleFactor, insets: draft.line == nil ? KhmerGlyphOutlines.textBoxInsets : TextEditInfo.insets,
                     background: draft.line?.coverColor)
        editor.frame = convert(draft.bounds, from: page).integral
        if let line = draft.line { placeOnBaseline(editor, line: line, page: page) }
        // An edited line opens with the caret where it was clicked.
        if isNew, let caret = draft.caret {
            editor.layoutManager?.ensureLayout(for: editor.textContainer!)
            let index = editor.characterIndexForInsertion(at: editor.convert(convert(caret, from: page), from: self))
            editor.setSelectedRange(NSRange(location: min(index, (editor.string as NSString).length), length: 0))
        }
    }

    /// An edited line's editor: as tall as its text and moved so its first baseline is the original line's baseline
    /// (where the committed text is drawn), at any zoom.
    private func placeOnBaseline(_ editor: TextBoxEditor, line: TextBoxDraft.LineEdit, page: PDFPage) {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let fragment = layout.numberOfGlyphs > 0 ? layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil) : used
        // An empty line has no glyph to measure: its baseline is the font's ascent below the top.
        let baselineInLine = layout.numberOfGlyphs > 0 ? layout.location(forGlyphAt: 0).y : (editor.font?.ascender ?? 0)
        let baselineFromTop = editor.textContainerInset.height + fragment.minY + baselineInLine
        let height = max(ceil(max(used.maxY, fragment.maxY) + 2 * editor.textContainerInset.height), 1)
        let baseline = convert(CGPoint(x: 0, y: line.baseline), from: page).y
        var frame = editor.frame
        frame.size.height = height
        frame.origin.y = isFlipped ? baseline - baselineFromTop : baseline + baselineFromTop - height
        // Keep covering the original line below the text (its background is the page colour).
        let cover = convert(line.cover, from: page)
        if isFlipped, cover.maxY > frame.maxY { frame.size.height += cover.maxY - frame.maxY }
        if !isFlipped, cover.minY < frame.minY { frame.size.height += frame.minY - cover.minY; frame.origin.y = cover.minY }
        editor.frame = frame.integral
    }

    /// Redraws Slek's annotations over the pages (immediately; see `SlekAnnotationOverlay`).
    func redrawAnnotations() {
        for overlay in subviews.compactMap({ $0 as? SlekAnnotationOverlay }) { overlay.needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if annotating?.annotateTool == .highlight { finishHighlight() }
    }

    /// Highlight tool: the text just selected becomes a highlight.
    private func finishHighlight() {
        guard let session = annotating, let selection = currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearSelection()
        Task { await session.highlight(selection) }
    }

    override func keyDown(with event: NSEvent) {
        if let session = annotating, session.handleAnnotateKey(event) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session = annotating, let hit = pagePoint(event), let annotation = slekAnnotation(on: hit.page, at: hit.point),
              let menu = session.annotationMenu(for: annotation.model.id, language: language) else { return super.menu(for: event) }
        session.selectAnnotation(annotation.model.id, reveal: false)
        return menu
    }
}
