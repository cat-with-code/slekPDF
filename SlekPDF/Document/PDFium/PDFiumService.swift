import CoreGraphics
import Foundation

/// Serial executor for every PDFium call in the app: PDFium is not thread-safe at the library level,
/// so all documents from all windows share this one actor.
@globalActor
actor PDFiumActor {
    static let shared = PDFiumActor()
}

/// Owns every open `PDFiumDocument`. Documents are opened and closed here, so PDFium's
/// `FPDF_CloseDocument` never runs on another thread.
@PDFiumActor
final class PDFiumService {
    static let shared = PDFiumService()

    struct DocumentID: Hashable, Sendable {
        fileprivate let raw = UUID()
    }

    private var documents: [DocumentID: PDFiumDocument] = [:]

    /// Opens the file (the caller must hold security-scoped access while it stays open). Returns the page count.
    func open(url: URL, password: String? = nil) throws -> (id: DocumentID, pageCount: Int) {
        let document = try PDFiumDocument(url: url, password: password)
        let id = DocumentID()
        documents[id] = document
        return (id, document.pageCount)
    }

    func close(_ id: DocumentID) {
        documents[id] = nil
        pages[id] = nil
        layers[id] = nil
    }

    /// A page for a new PDF: from an open document (with extra rotation) or from another PDF file.
    enum PageSource: Sendable {
        /// A page of an open document with Slek's annotations as they are now (replacing any saved in the file).
        case open(DocumentID, page: Int, quarterTurns: Int, annotations: [PageAnnotation] = [], ocr: OCRPage? = nil)
        case file(URL, page: Int)
    }

    /// Writes `pages` in order as a new PDF (saved work, merge, split). Pages are imported, never redrawn;
    /// source files are only read.
    func writePDF(_ pages: [PageSource], to url: URL) throws {
        let output = PDFiumDocument()
        var files: [URL: PDFiumDocument] = [:]
        for page in pages {
            switch page {
            case let .open(id, index, turns, annotations, ocr):
                guard let source = documents[id] else { throw PDFiumError.file }
                try output.appendPage(from: source, index: index, quarterTurns: turns)
                let added = output.pageCount - 1
                try output.removeSlekAnnotations(page: added)
                for annotation in annotations { try output.add(annotation, page: added) }
                if let ocr { try output.addOCR(ocr, page: added) }
            case let .file(fileURL, index):
                let source = try files[fileURL] ?? PDFiumDocument(url: fileURL)
                files[fileURL] = source
                try output.appendPage(from: source, index: index, quarterTurns: 0)
            }
        }
        try output.save(to: url, incremental: false)
    }

    /// Slek's annotations saved in an open document, by source page (reopened saved work).
    func annotations(_ id: DocumentID) -> [Int: [PageAnnotation]] {
        guard let document = documents[id] else { return [:] }
        var result: [Int: [PageAnnotation]] = [:]
        for index in 0..<document.pageCount {
            if let found = try? document.slekAnnotations(page: index), !found.isEmpty { result[index] = found }
        }
        return result
    }

    /// OCR results saved in an open document, by source page (reopened saved work).
    func ocrPages(_ id: DocumentID) -> [Int: OCRPage] {
        guard let document = documents[id] else { return [:] }
        var result: [Int: OCRPage] = [:]
        for index in 0..<document.pageCount {
            if let ocr = try? document.slekOCR(page: index) { result[index] = ocr }
        }
        return result
    }

    /// Page image for OCR (see `PDFiumDocument.renderForOCR`).
    func renderForOCR(_ id: DocumentID, page: Int, quarterTurns: Int, ppi: CGFloat) -> CGImage? {
        documents[id]?.renderForOCR(page: page, quarterTurns: quarterTurns, ppi: ppi)
    }

    /// OCR line boxes (image pixels) back in page space.
    func pageRects(_ id: DocumentID, _ rects: [CGRect], page: Int, quarterTurns: Int, ppi: CGFloat) -> [CGRect] {
        documents[id]?.pageRects(rects, page: page, quarterTurns: quarterTurns, ppi: ppi) ?? []
    }

    /// Whether a page already has a usable text layer ("Skip pages with usable text"): enough letters, not just a
    /// page number or a stray scanner stamp.
    /// A layer that is mostly another script (e.g. Khmer read as Thai by other OCR software) is not usable: the page
    /// is recognized again, and Copy uses Slek's text.
    func hasUsableText(_ id: DocumentID, page: Int) -> Bool {
        textLayer(id, page: page) == .usable
    }

    /// The page's own text layer, checked once per page (see `layerQuality`).
    func textLayer(_ id: DocumentID, page index: Int) -> TextLayer {
        if let cached = layers[id]?[index] { return cached }
        guard let document = documents[id], let entry = page(id, index) else { return .none }
        let layer = Self.layerQuality(text: entry.text.text, fonts: (try? document.fontUsage(onPage: index)) ?? [:])
        layers[id, default: [:]][index] = layer
        return layer
    }

    private var layers: [DocumentID: [Int: TextLayer]] = [:]

    /// What a page's own text layer is good for.
    nonisolated enum TextLayer: Equatable, CustomStringConvertible {
        /// No text, or too little (a page number, a scanner stamp).
        case none
        case usable
        /// Text that reads as gibberish: legacy (non-Unicode) Khmer fonts such as Limon or ABC, or Khmer whose
        /// glyph-to-Unicode map is broken. Not copied or exported; the page needs OCR.
        case unreadable

        var description: String { switch self { case .none: "none"; case .usable: "usable"; case .unreadable: "unreadable" } }
    }

    /// Legacy Khmer fonts draw Khmer glyphs at Latin code points ("pøaksBaØa" for ផ្លាកសញ្ញា).
    nonisolated static func isLegacyKhmerFont(_ name: String) -> Bool {
        let name = name.lowercased()
        // ABC Khmer fonts are "ABC-TEXT-05", "ABC-KHMER…"; not Latin families such as "ABCDiatype".
        return ["limon", "lmn", "abc-", "abc_", "abc ", "abctext", "abckhmer", "khek", "baidok", "khmm"].contains { name.hasPrefix($0) }
    }

    nonisolated struct KhmerSignals: CustomStringConvertible {
        var khmer = 0, ngCoeng = 0, orphans = 0, badCoeng = 0
        var description: String { "khmer=\(khmer) ngCoeng=\(ngCoeng) orphans=\(orphans) badCoeng=\(badCoeng)" }
    }

    /// Counts of Khmer sequences that a broken glyph map produces: "ង្" standing for the vowel េ, dependent vowels
    /// and signs with no consonant before them, a subscript sign (្) not followed by a consonant.
    nonisolated static func khmerLayerSignals(_ text: String) -> KhmerSignals {
        var signals = KhmerSignals()
        let scalars = Array(text.unicodeScalars)
        func isConsonant(_ s: Unicode.Scalar) -> Bool { (0x1780...0x17B3).contains(s.value) }
        for (i, s) in scalars.enumerated() where (0x1780...0x17FF).contains(s.value) {
            signals.khmer += 1
            let previous = i > 0 ? scalars[i - 1] : nil
            if s.value == 0x17D2 {
                if previous?.value == 0x1784 { signals.ngCoeng += 1 }
                if i + 1 >= scalars.count || !isConsonant(scalars[i + 1]) { signals.badCoeng += 1 }
            } else if (0x17B6...0x17D1).contains(s.value), previous.map({ !(0x1780...0x17D3).contains($0.value) }) ?? true {
                signals.orphans += 1
            }
        }
        return signals
    }

    nonisolated static func layerQuality(text: String, fonts: [String: Int]) -> TextLayer {
        // Even a short heading in a legacy font would be copied and exported as gibberish.
        if fonts.contains(where: { isLegacyKhmerFont($0.key) && $0.value >= 5 }) { return .unreadable }
        guard isUsableText(text) else {
            let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
            return letters >= 20 ? .unreadable : .none
        }
        // Measured (docs/spikes/04-khmerocr.md): well-made Khmer PDFs have no orphan marks or bad subscripts; broken
        // glyph maps have 1.4–4 %. "ង្" is common in real words (អង្គ, បង្ហាញ), so only a lot of it counts.
        let s = khmerLayerSignals(text)
        let khmer = Double(s.khmer)
        if s.orphans + s.badCoeng >= 3, Double(s.orphans + s.badCoeng) >= khmer * 0.01 { return .unreadable }
        if s.khmer >= 100, Double(s.ngCoeng) >= khmer * 0.03 { return .unreadable }
        return .usable
    }

    nonisolated static func isUsableText(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        let khmerOrLatin = letters.filter { (0x1780...0x17FF).contains($0.value) || ($0.isASCII) }.count
        return khmerOrLatin >= 20 && Double(khmerOrLatin) >= Double(letters.count) * 0.8
    }

    /// Readable text lines of a page with their positions (Export).
    /// Empty for an unreadable layer (legacy fonts, broken glyph map): the page needs OCR.
    func textLines(_ id: DocumentID, page index: Int) -> [KhmerTextRebuilder.Line] {
        guard textLayer(id, page: index) != .unreadable, let chars = page(id, index)?.chars else { return [] }
        return KhmerTextRebuilder.lines(chars).map {
            KhmerTextRebuilder.Line(text: KhmerNormalizer.normalize($0.text), box: $0.box, fontSize: $0.fontSize)
        }
    }

    /// The pieces of text a click can edit (Edit PDF text): each line split at wide gaps, so a click in a table cell
    /// or a column takes that phrase, not the whole row. Empty for an unreadable layer.
    func editableSegments(_ id: DocumentID, page index: Int) -> [KhmerTextRebuilder.Segment] {
        guard textLayer(id, page: index) == .usable, let chars = page(id, index)?.chars else { return [] }
        return KhmerTextRebuilder.segments(chars, byHeight: true).flatMap { $0 }.map {
            KhmerTextRebuilder.Segment(text: KhmerNormalizer.normalize($0.text), box: $0.box, fontSize: $0.fontSize, baseline: $0.baseline)
        }
    }

    /// The page's colour around `rect` (an edited line's cover).
    func colorAround(_ id: DocumentID, rect: CGRect, page index: Int) -> [CGFloat] {
        documents[id]?.colorAround(rect, page: index) ?? [1, 1, 1]
    }

    /// Lines split into cell candidates (Export tables).
    func textSegments(_ id: DocumentID, page index: Int) -> [[KhmerTextRebuilder.Segment]] {
        guard textLayer(id, page: index) != .unreadable, let chars = page(id, index)?.chars else { return [] }
        return KhmerTextRebuilder.segments(chars)
    }

    /// A searchable delivery copy: the edited pages as they are (nothing redrawn, Slek's editable annotations
    /// removed), each with its text `layers` (one-page PDFs drawn by `ExportTextLayer`) placed on top.
    func writeSearchablePDF(_ pages: [(source: PageSource, layer: Data?)], to url: URL) throws {
        let output = PDFiumDocument()
        for (number, item) in pages.enumerated() {
            guard case let .open(id, index, turns, _, _) = item.source, let source = documents[id] else { throw PDFiumError.file }
            try output.appendPage(from: source, index: index, quarterTurns: turns)
            try output.removeSlekAnnotations(page: number)
            if let layer = item.layer {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("layer-\(UUID()).pdf")
                try layer.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                try output.overlay(page: number, with: PDFiumDocument(url: file))
            }
        }
        try output.save(to: url, incremental: false)
    }

    /// Page count of a PDF file that is not open (Merge PDFs list).
    func pageCount(of url: URL) -> Int? { try? PDFiumDocument(url: url).pageCount }

    /// Rebuilt (readable) text per page, cached: used by copy and search.
    private var pages: [DocumentID: [Int: (text: KhmerTextRebuilder.Result, chars: [PDFiumChar])]] = [:]

    private func page(_ id: DocumentID, _ index: Int) -> (text: KhmerTextRebuilder.Result, chars: [PDFiumChar])? {
        if let cached = pages[id]?[index] { return cached }
        guard let document = documents[id], let chars = try? document.characters(onPage: index) else { return nil }
        let entry = (KhmerTextRebuilder.rebuild(chars), chars)
        pages[id, default: [:]][index] = entry
        return entry
    }

    /// Readable text for a selection, given as line rectangles in PDF page space (from PDFKit's selection).
    func copyText(_ id: DocumentID, lines: [(page: Int, rect: CGRect)]) -> String {
        lines.compactMap { line -> String? in
            guard textLayer(id, page: line.page) != .unreadable, let chars = page(id, line.page)?.chars else { return nil }
            let area = line.rect.insetBy(dx: -1, dy: -2)
            let inside = chars.filter { char in
                area.contains(char.isGenerated ? char.origin : CGPoint(x: char.box.midX, y: char.box.midY))
            }
            let text = KhmerNormalizer.normalize(KhmerTextRebuilder.rebuild(inside).text).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }

    /// Searches the rebuilt text of every page (spaces ignored, so stray spaces in a PDF don't break a match),
    /// stopping early if the calling task is cancelled.
    func search(_ id: DocumentID, query: String, matchCase: Bool, wholeWord: Bool) -> [PDFiumMatch] {
        guard let document = documents[id] else { return [] }
        let needle = Self.searchable(query, matchCase: matchCase)
        guard !needle.isEmpty else { return [] }
        var results: [PDFiumMatch] = []
        for index in 0..<document.pageCount {
            if Task.isCancelled { return [] }
            guard let entry = page(id, index) else { continue }
            results += Self.matches(of: needle, in: entry.text, chars: entry.chars, page: index, matchCase: matchCase, wholeWord: wholeWord)
        }
        return results
    }

    private static func searchable(_ text: String, matchCase: Bool) -> [Unicode.Scalar] {
        let normalized = text.precomposedStringWithCanonicalMapping
        return Array((matchCase ? normalized : normalized.lowercased()).unicodeScalars.filter { !$0.properties.isWhitespace })
    }

    private static func matches(of needle: [Unicode.Scalar], in result: KhmerTextRebuilder.Result, chars: [PDFiumChar],
                                page: Int, matchCase: Bool, wholeWord: Bool) -> [PDFiumMatch] {
        let scalars = Array(result.text.unicodeScalars)
        // Positions in `scalars` of every non-whitespace scalar, compared case-folded when needed.
        var positions: [Int] = []
        var haystack: [Unicode.Scalar] = []
        for (position, scalar) in scalars.enumerated() where !scalar.properties.isWhitespace {
            let folded = matchCase ? [scalar] : Array(String(scalar).lowercased().unicodeScalars)
            for f in folded { haystack.append(f); positions.append(position) }
        }
        let byIndex = Dictionary(chars.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        func isWordScalar(_ p: Int) -> Bool { p >= 0 && p < scalars.count && (scalars[p].properties.isAlphabetic || scalars[p].properties.numericType != nil) }
        var found: [PDFiumMatch] = []
        var start = 0
        while start + needle.count <= haystack.count {
            guard haystack[start..<(start + needle.count)].elementsEqual(needle) else { start += 1; continue }
            let first = positions[start], last = positions[start + needle.count - 1]
            if wholeWord, isWordScalar(first - 1) || isWordScalar(last + 1) { start += 1; continue }
            let sources = result.sources[first...last].compactMap { $0 }
            let boxes = sources.compactMap { byIndex[$0] }.filter { !$0.isGenerated }.map(\.box)
            func text(_ range: Range<Int>) -> String {
                var s = ""
                s.unicodeScalars.append(contentsOf: scalars[max(0, range.lowerBound)..<min(scalars.count, range.upperBound)])
                return s
            }
            found.append(PDFiumMatch(page: page, charIndex: sources.min() ?? 0, charCount: sources.count,
                                     rects: mergeLines(boxes),
                                     before: text((first - 24)..<first), match: text(first..<(last + 1)),
                                     after: text((last + 1)..<(last + 33))))
            start += needle.count
        }
        return found
    }

    /// One rectangle per text line.
    private static func mergeLines(_ boxes: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        for box in boxes where box.width > 0 || box.height > 0 {
            if let i = lines.firstIndex(where: { min($0.maxY, box.maxY) - max($0.minY, box.minY) > min($0.height, box.height) * 0.4 }) {
                lines[i] = lines[i].union(box)
            } else {
                lines.append(box)
            }
        }
        return lines
    }
}
