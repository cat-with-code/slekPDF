import AppKit
import CoreText

/// Export formats (Figma 05–09 format menu). Excel and Word + Excel arrive with tables (Export step 2).
enum ExportFormat: Hashable, CaseIterable {
    case word, searchablePDF, plainText

    var fileExtension: String {
        switch self {
        case .word: "docx"
        case .searchablePDF: "pdf"
        case .plainText: "txt"
        }
    }

    var title: CopyKey {
        switch self {
        case .word: .word
        case .searchablePDF: .searchablePDF
        case .plainText: .plainTextTxt
        }
    }
}

/// Figma Export Options (132:409).
struct ExportSettings: Equatable {
    var format: ExportFormat = .word
    var scope: OCRSettings.Scope = .all
    var customRange = ""
    var includeAddedText = false
    /// The output file name; reset to the default when the format changes.
    var fileName = ""
    /// Folder chosen with Choose folder… (else the Preferences export folder, else asked on Export).
    var folder: URL?
}

/// One page's content for export.
struct ExportPage: Equatable {
    /// Page number in the edited document (1-based).
    let number: Int
    let blocks: [ConvertedDocument.Block]
    /// Lines with page-space boxes, for the searchable PDF text layer (OCR pages only).
    let ocrLines: [(text: String, bounds: CGRect)]
    /// Added text boxes (when “Include added text” is on).
    let textBoxes: [PageAnnotation]
    let fromOCR: Bool
    /// The page has text to export (its own text layer, OCR, or included added text).
    var hasText: Bool { !blocks.isEmpty }

    static func == (a: ExportPage, b: ExportPage) -> Bool {
        a.number == b.number && a.fromOCR == b.fromOCR && a.textBoxes == b.textBoxes && a.ocrLines.map(\.text) == b.ocrLines.map(\.text)
            && ExportBuilder.plainText(a.blocks) == ExportBuilder.plainText(b.blocks)
    }
}

/// A text line on a page, from the PDF's own text, reviewed OCR, or an added text box.
nonisolated struct ExportLine: Sendable {
    var text: String
    var box: CGRect
    var fontSize: CGFloat
    /// Added text: its own paragraph, never joined with neighbouring lines.
    var standalone = false
    var bold = false
    var italic = false
}

/// Turns page lines into paragraphs and headings (no guessing beyond layout: spacing and size).
nonisolated enum ExportBuilder {
    static func blocks(_ lines: [ExportLine]) -> [ConvertedDocument.Block] {
        let sizes = lines.filter { !$0.standalone }.map(\.fontSize).filter { $0 > 0 }.sorted()
        let body = sizes.isEmpty ? 12 : sizes[sizes.count / 2]
        func headingLevel(_ line: ExportLine) -> Int? {
            guard !line.standalone, line.text.count <= 120, line.fontSize >= body * 1.3 else { return nil }
            return line.fontSize >= body * 1.8 ? 1 : 2
        }
        var blocks: [ConvertedDocument.Block] = []
        var current: (lines: [ExportLine], heading: Int?)?
        func flush() {
            guard let group = current else { return }
            let text = join(group.lines.map(\.text))
            if let level = group.heading {
                blocks.append(.heading(level: level, text: text))
            } else {
                let first = group.lines[0]
                blocks.append(.paragraph([TextRun(text: text, bold: first.bold, italic: first.italic)]))
            }
            current = nil
        }
        for line in lines {
            let level = headingLevel(line)
            if let group = current, let last = group.lines.last, !line.standalone, !last.standalone, group.heading == level {
                let height = max(last.box.height, line.box.height, 1)
                let gap = last.box.minY - line.box.maxY
                let sameSize = abs(last.fontSize - line.fontSize) <= max(last.fontSize, line.fontSize) * 0.2
                if gap >= -height * 0.5, gap <= height * 0.6, sameSize {
                    current?.lines.append(line)
                    continue
                }
            }
            flush()
            current = ([line], level)
        }
        flush()
        return blocks
    }

    /// Lines of one paragraph: Khmer to Khmer joins without a space (Khmer has none between words), else one space.
    static func join(_ texts: [String]) -> String {
        texts.reduce("") { result, next in
            guard let last = result.unicodeScalars.last, let first = next.unicodeScalars.first else { return result + next }
            return result + (isKhmer(last) && isKhmer(first) ? "" : " ") + next
        }
    }

    static func isKhmer(_ scalar: Unicode.Scalar) -> Bool { (0x1780...0x17FF).contains(scalar.value) || (0x19E0...0x19FF).contains(scalar.value) }

    /// Plain text of one page's blocks (one paragraph per line).
    static func plainText(_ blocks: [ConvertedDocument.Block]) -> String {
        blocks.map { block -> String in
            switch block {
            case let .heading(_, text): text
            case let .paragraph(runs): runs.map(\.text).joined()
            case let .table(table): table.rows.map { $0.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    /// The .txt file (Figma 09): pages separated by “--- page N ---”.
    static func plainText(pages: [ExportPage]) -> String {
        pages.enumerated().map { offset, page in
            (offset == 0 ? "" : "\n--- page \(page.number) ---\n") + plainText(page.blocks)
        }.joined() + "\n"
    }
}

/// Text layer for a searchable delivery copy (spike 01, E5): invisible Unicode text in logical order over each
/// recognized line, and added text boxes as shaped outlines plus invisible text. One page, drawn from (0, 0).
nonisolated enum ExportTextLayer {
    static func pdfData(pageBox: CGRect, rotation: Int, ocrLines: [(text: String, bounds: CGRect)], textBoxes: [PageAnnotation]) -> Data? {
        guard !ocrLines.isEmpty || !textBoxes.isEmpty else { return nil }
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: pageBox.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        context.beginPDFPage(nil)
        context.translateBy(x: -pageBox.minX, y: -pageBox.minY)
        for line in ocrLines { drawInvisible(line.text, in: line.bounds, rotation: rotation, context: context) }
        for box in textBoxes {
            guard case let .textBox(text, style) = box.content else { continue }
            context.saveGState()
            context.setFillColor(CGColor(srgbRed: style.color[0], green: style.color[1], blue: style.color[2], alpha: 1))
            for path in KhmerGlyphOutlines.outlines(text: text, in: box.bounds, style: style) {
                context.addPath(path)
                context.fillPath()
            }
            context.restoreGState()
            // One invisible line per text line, stacked from the box's top inset.
            let lineHeight = style.fontSize * style.lineSpacing
            for (number, part) in text.components(separatedBy: "\n").enumerated() where !part.isEmpty {
                let top = box.bounds.maxY - TextBoxStyle.verticalInset - CGFloat(number) * lineHeight
                let rect = CGRect(x: box.bounds.minX + TextBoxStyle.horizontalInset, y: top - lineHeight,
                                  width: box.bounds.width - 2 * TextBoxStyle.horizontalInset, height: lineHeight)
                drawInvisible(part, in: rect, rotation: 0, context: context)
            }
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// One nominal glyph per UTF-16 unit, edge to edge, scaled to the line's length, along the direction the line
    /// reads on the turned page (`rotation`, degrees clockwise). Khmer from Noto Sans Khmer, everything else from Inter.
    static func drawInvisible(_ text: String, in rect: CGRect, rotation: Int, context: CGContext) {
        let turns = ((rotation / 90) % 4 + 4) % 4
        let length = turns % 2 == 0 ? rect.width : rect.height
        let height = turns % 2 == 0 ? rect.height : rect.width
        guard length > 0, height > 0, !text.isEmpty else { return }
        let size = height * 0.8
        let khmer = CTFontCreateWithName("NotoSansKhmer-Regular" as CFString, size, nil)
        let latin = CTFontCreateWithName("Inter-Regular" as CFString, size, nil)
        var runs: [(font: CTFont, glyphs: [CGGlyph], advances: [CGFloat])] = []
        for unit in text.utf16 {
            let font = Unicode.Scalar(unit).map { ExportBuilder.isKhmer($0) } == true ? khmer : latin
            var character = unit, glyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            if let last = runs.last, CFEqual(last.font, font) {
                runs[runs.count - 1].glyphs.append(glyph)
                runs[runs.count - 1].advances.append(advance.width)
            } else {
                runs.append((font, [glyph], [advance.width]))
            }
        }
        let total = max(runs.flatMap(\.advances).reduce(0, +), 1)
        // Origin: the line's start on its baseline, as the page is shown (bottom-left in reading direction).
        let origin: CGPoint = switch turns {
        case 1: CGPoint(x: rect.maxX - height * 0.2, y: rect.minY)
        case 2: CGPoint(x: rect.maxX, y: rect.maxY - height * 0.2)
        case 3: CGPoint(x: rect.minX + height * 0.2, y: rect.maxY)
        default: CGPoint(x: rect.minX, y: rect.minY + height * 0.2)
        }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.translateBy(x: origin.x, y: origin.y)
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.scaleBy(x: length / total, y: 1)
        var x: CGFloat = 0
        for run in runs {
            var positions: [CGPoint] = []
            for advance in run.advances {
                positions.append(CGPoint(x: x, y: 0))
                x += advance
            }
            CTFontDrawGlyphs(run.font, run.glyphs, positions, run.glyphs.count, context)
        }
        context.restoreGState()
    }
}

extension DocumentSession {
    /// The pages Export includes (current indices), or nil for an invalid custom range.
    var exportPageIndices: [Int]? {
        switch exportSettings.scope {
        case .all: return Array(pages.indices)
        case .current: return pages.indices.contains(currentPageIndex) ? [currentPageIndex] : nil
        case .custom:
            guard let groups = PageRanges.parse(exportSettings.customRange, pageCount: pages.count) else { return nil }
            var seen = Set<Int>()
            return groups.flatMap { $0 }.filter { seen.insert($0).inserted }
        }
    }

    /// Default output name: the PDF's name, “(searchable)” for a searchable PDF.
    func defaultExportFileName(for format: ExportFormat) -> String {
        let base = (fileName as NSString?)?.deletingPathExtension ?? "Document"
        return format == .searchablePDF ? "\(base) (searchable).pdf" : "\(base).\(format.fileExtension)"
    }

    /// Content of `indices` for export: reviewed OCR where a page was recognized, else the PDF's own text; added
    /// text boxes when asked. `progress` is called after each page.
    func exportPages(_ indices: [Int], includeAddedText: Bool, progress: (Int) -> Void = { _ in }) async -> [ExportPage] {
        guard let id = pdfiumID else { return [] }
        var result: [ExportPage] = []
        for (done, index) in indices.enumerated() where pages.indices.contains(index) {
            let ref = pages[index]
            var lines: [ExportLine]
            var ocrLines: [(text: String, bounds: CGRect)] = []
            let ocr = ocrResults[ref.id]
            if let ocr, !ocr.lines.isEmpty {
                ocrLines = ocr.lines.map { ($0.displayText, $0.bounds) }
                lines = ocr.lines.map { ExportLine(text: $0.displayText, box: $0.bounds, fontSize: $0.bounds.height * 0.75) }
            } else {
                lines = await PDFiumService.shared.textLines(id, page: ref.source).map {
                    ExportLine(text: $0.text, box: $0.box, fontSize: $0.fontSize)
                }
            }
            let boxes = includeAddedText ? (annotations[ref.id] ?? []).filter { if case .textBox = $0.content { true } else { false } } : []
            for box in boxes {
                guard case let .textBox(text, style) = box.content else { continue }
                let line = ExportLine(text: text, box: box.bounds, fontSize: style.fontSize, standalone: true, bold: style.bold, italic: style.italic)
                // Placed by position: before the first line that sits lower on the page.
                let at = lines.firstIndex { $0.box.maxY < box.bounds.maxY } ?? lines.count
                lines.insert(line, at: at)
            }
            result.append(ExportPage(number: index + 1, blocks: ExportBuilder.blocks(lines), ocrLines: ocrLines,
                                     textBoxes: boxes, fromOCR: ocr?.lines.isEmpty == false))
            progress(done + 1)
        }
        return result
    }
}
