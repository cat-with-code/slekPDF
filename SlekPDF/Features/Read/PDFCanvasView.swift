import PDFKit
import SwiftUI

/// Figma "Document Canvas" (109:197): PDFKit's PDFView for page display.
/// Text selection/copy in PDFView uses PDFKit's Khmer text, which is unreliable (docs/spikes/01);
/// copy will be routed through PDFium before release.
struct PDFCanvasView: NSViewRepresentable {
    @ObservedObject var session: DocumentSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> PDFView {
        let view = KhmerPDFView()
        view.copyHandler = { [weak session] selection in session?.copy(selection) }
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        view.backgroundColor = DSNSColor.backgroundCanvas
        view.postsFrameChangedNotifications = true
        session.pdfView = view
        let highlights = SearchHighlightView(frame: view.bounds)
        highlights.autoresizingMask = [.width, .height]
        highlights.pdfView = view
        view.addSubview(highlights)
        context.coordinator.highlights = highlights
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== session.document {
            view.document = session.document
            DispatchQueue.main.async { session.applyFitPage() }
        }
        context.coordinator.highlights?.update(matches: session.searchResults, current: session.currentMatchIndex)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        private let session: DocumentSession
        private var tokens: [NSObjectProtocol] = []
        var highlights: SearchHighlightView?

        init(session: DocumentSession) { self.session = session }

        func observe(_ view: PDFView) {
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view, let page = view.currentPage, let document = view.document else { return }
                    self?.session.pdfViewDidChangePage(document.index(for: page))
                }
            })
            tokens.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.applyFitPage() }
            })
            // Redraw search highlights while scrolling.
            if let clip = view.documentView?.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                tokens.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.highlights?.needsDisplay = true }
                })
            }
            tokens.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view else { return }
                    self?.session.pdfViewDidChangeScale(view.scaleFactor)
                    self?.highlights?.needsDisplay = true
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

    override func copy(_ sender: Any?) {
        guard let selection = currentSelection, let copyHandler else { return super.copy(sender) }
        copyHandler(selection)
    }
}
