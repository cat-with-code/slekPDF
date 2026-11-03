import AppKit
import PDFKit
import SwiftUI

/// Prototype 25 Print and 26 Printing… (Print Sheet 188:179). The macOS print sheet provides printer, copies,
/// paper size, pages, preview, Help and PDF ▾; Slek PDF adds its own section (an accessory view) for what to print.
/// Printing draws the original pages as they are — nothing is redrawn into the source, which is never changed.
@MainActor
final class PrintOptions: ObservableObject {
    enum Content: Hashable { case documentAndAnnotations, documentOnly }

    @Published var content: Content = .documentAndAnnotations { didSet { onChange() } }
    @Published var addedText = true { didSet { onChange() } }
    @Published var highlights = true { didSet { onChange() } }
    /// Needs comment threads (Annotate, not built yet); off and disabled until then.
    @Published var commentsSummary = false

    var onChange: () -> Void = {}

    /// Whether an annotation already in the PDF prints with these options.
    func prints(_ annotation: PDFAnnotation) -> Bool {
        guard content == .documentAndAnnotations else { return false }
        // Comment pins are on-screen markers; comments print only as the summary page (once built).
        if let slek = annotation as? SlekPDFAnnotation, slek.isComment { return false }
        switch annotation.type {
        case "FreeText": return addedText
        case "Highlight": return highlights
        default: return true
        }
    }
}

enum PrintController {
    /// Opens the print sheet on the document's window; once the job is sent, shows the Printing… toast (D-26).
    @MainActor
    static func print(_ session: DocumentSession, language: AppLanguage) {
        guard let document = session.document, let window = session.pdfView?.window ?? NSApp.keyWindow,
              let info = NSPrintInfo.shared.copy() as? NSPrintInfo,
              let operation = document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true)
        else { return }
        let options = PrintOptions()
        let visibility = AnnotationVisibility(document: document)
        let accessory = PrintAccessoryController(options: options, language: language)
        options.onChange = {
            visibility.apply(options)
            accessory.previewToken += 1  // the print panel re-renders its preview
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = false
        operation.jobTitle = session.fileName ?? "Slek PDF"
        operation.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsPreview])
        operation.printPanel.addAccessoryController(accessory)
        visibility.apply(options)

        let completion = PrintCompletion { success, info in
            visibility.restore()
            guard success else { return }
            let pages = info.pageCount(of: document.pageCount)
            session.toasts.show(.progress, CopyCatalog.shared.format(.fmtPrintingNPagesToPrinter, language, pages, info.printer.name))
            // The job is now in the macOS print queue; the toast stays briefly, then the queue takes over.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                session.toasts.dismiss()
            }
        }
        operation.runModal(for: window, delegate: completion,
                           didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: Unmanaged.passRetained(completion).toOpaque())
    }
}

/// Receives NSPrintOperation's completion callback; retained until it is called.
final class PrintCompletion: NSObject {
    private let handler: (Bool, NSPrintInfo) -> Void

    init(_ handler: @escaping (Bool, NSPrintInfo) -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintCompletion>.fromOpaque(contextInfo).release() }
        handler(success, operation.printInfo)
    }
}

/// Hides annotations the options leave out while the sheet and the job run, then restores them.
@MainActor
private final class AnnotationVisibility {
    private var original: [(PDFAnnotation, Bool)] = []

    init(document: PDFDocument) {
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] { original.append((annotation, annotation.shouldDisplay)) }
        }
    }

    func apply(_ options: PrintOptions) {
        for (annotation, shown) in original { annotation.shouldDisplay = shown && options.prints(annotation) }
    }

    func restore() {
        for (annotation, shown) in original { annotation.shouldDisplay = shown }
    }
}

private extension NSPrintInfo {
    /// Pages in the chosen range ("All" = the whole document).
    func pageCount(of total: Int) -> Int {
        let values = dictionary()
        guard let all = values[NSPrintInfo.AttributeKey.allPages] as? Bool, !all,
              let first = values[NSPrintInfo.AttributeKey.firstPage] as? Int,
              let last = values[NSPrintInfo.AttributeKey.lastPage] as? Int
        else { return total }
        return max(0, min(last, total) - first + 1)
    }
}

/// The Slek PDF section of the print sheet (Figma: "Slek PDF" heading, Print dropdown, Include checkboxes, note).
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    private let options: PrintOptions
    private let language: AppLanguage
    /// Bumped when an option changes so the print panel refreshes its preview.
    @objc dynamic var previewToken = 0

    init(options: PrintOptions, language: AppLanguage) {
        self.options = options
        self.language = language
        super.init(nibName: nil, bundle: nil)
        title = "Slek PDF"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: PrintAccessoryView(options: options).environment(\.appLanguage, language))
        host.frame.size = host.fittingSize
        view = host
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        let content = CopyCatalog.shared.string(options.content == .documentOnly ? .documentOnly : .documentAndAnnotations, language)
        return [[.itemName: CopyCatalog.shared.string(.print, language), .itemDescription: content]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["previewToken"] }
}

struct PrintAccessoryView: View {
    @ObservedObject var options: PrintOptions
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s12) {
            Text("Slek PDF").dsText(.heading).foregroundColor(DSColor.textPrimary)
            DSDropdown(label: CopyCatalog.shared.string(.print, language), selection: $options.content, options: [
                (value: PrintOptions.Content.documentAndAnnotations, title: CopyCatalog.shared.string(.documentAndAnnotations, language)),
                (value: .documentOnly, title: CopyCatalog.shared.string(.documentOnly, language)),
            ])
            VStack(alignment: .leading, spacing: DSSpace.s6) {
                DSCheckbox(label: .addedKhmerText, isOn: $options.addedText)
                DSCheckbox(label: .highlights, isOn: $options.highlights)
                DSCheckbox(label: .commentsSummaryPageAtTheEnd, isOn: $options.commentsSummary).disabled(true)
            }
            .disabled(options.content == .documentOnly)
            Text(CopyCatalog.shared.string(.khmerFontsAreEmbeddedSoClustersPri, language)).dsText(.caption).foregroundColor(DSColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DSSpace.s20)
        .frame(width: 420, alignment: .leading)
    }
}
