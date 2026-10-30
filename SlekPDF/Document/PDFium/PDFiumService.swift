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
    }

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
            guard let chars = page(id, line.page)?.chars else { return nil }
            let area = line.rect.insetBy(dx: -1, dy: -2)
            let inside = chars.filter { char in
                area.contains(char.isGenerated ? char.origin : CGPoint(x: char.box.midX, y: char.box.midY))
            }
            let text = KhmerTextRebuilder.rebuild(inside).text.trimmingCharacters(in: .whitespaces)
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
