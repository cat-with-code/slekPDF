import PDFKit
import SwiftUI

/// Figma "Document Canvas" (109:197): PDFKit's PDFView for page display.
/// Text selection/copy in PDFView uses PDFKit's Khmer text, which is unreliable (docs/spikes/01);
/// copy will be routed through PDFium before release.
struct PDFCanvasView: NSViewRepresentable {
    @ObservedObject var session: DocumentSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        view.backgroundColor = DSNSColor.backgroundCanvas
        view.postsFrameChangedNotifications = true
        session.pdfView = view
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== session.document {
            view.document = session.document
            DispatchQueue.main.async { session.applyFitPage() }
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator {
        private let session: DocumentSession
        private var tokens: [NSObjectProtocol] = []

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
            tokens.append(center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let view else { return }
                    self?.session.pdfViewDidChangeScale(view.scaleFactor)
                }
            })
        }

        func stopObserving() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
        }
    }
}
