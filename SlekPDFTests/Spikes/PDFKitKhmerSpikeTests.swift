import AppKit
import CoreText
import PDFKit
import XCTest
@testable import SlekPDF

/// Phase 1 feasibility spike: Khmer text in PDFKit (reading, search, added text, export).
/// Results are written to the app container (sandbox) and copied out by Tools/fixtures/run_pdfkit_spike.sh,
/// which also runs the independent pypdf/pdfminer check on the exported files.
/// Findings: docs/spikes/01-pdfkit-khmer.md
@MainActor
final class PDFKitKhmerSpikeTests: XCTestCase {
    private let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("pdfkit-spike")
    private var report: [String] = []
    private let bundle = Bundle(for: PDFKitKhmerSpikeTests.self)

    private func prepare() throws {
        FontRegistry.registerBundledFonts()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    private func writeReport(_ experiment: String) throws {
        try report.joined(separator: "\n").write(to: outDir.appendingPathComponent("report-\(experiment).txt"), atomically: true, encoding: .utf8)
    }

    private var expectedLines: [String] {
        get throws {
            let url = try XCTUnwrap(bundle.url(forResource: "khmer-sample-lines", withExtension: "json"))
            return try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        }
    }

    private func squash(_ text: String) -> String {
        // Filter on scalars: a space followed by a Khmer combining sign forms one Character in Swift.
        String(String.UnicodeScalarView(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !$0.properties.isWhitespace }))
    }

    private func fixture(_ name: String) throws -> PDFDocument {
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "pdf"))
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func checkExtraction(_ document: PDFDocument, label: String, lines: [String]) {
        let text = document.string ?? ""
        let missing = lines.filter { !squash(text).contains(squash($0)) }
        report.append("\(label): PDFKit extraction \(missing.isEmpty ? "OK" : "MISSING \(missing.count)/\(lines.count)")")
        if !missing.isEmpty {
            report.append("  got: " + text.split(separator: "\n").joined(separator: " | "))
        }
        for word in ["ភូមិថ្មី", "ព្រះរាជាណាចក្រកម្ពុជា", "ថ្ងៃទី", "ពិនិត្យ"] where lines.contains(where: { $0.contains(word) }) {
            let hits = document.findString(word, withOptions: []).count
            report.append("  search \(word): \(hits) hit(s)")
        }
    }

    private func renderPNG(_ page: PDFPage, to name: String) throws {
        let size = page.bounds(for: .mediaBox).size
        let image = page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appendingPathComponent(name))
    }

    // E1/E2: how PDFKit reads and searches PDFs produced elsewhere.
    func testE1ReadAndSearchFixtures() throws {
        try prepare()
        defer { try? writeReport("E1") }
        let lines = try expectedLines
        for name in ["khmer-coretext", "khmer-chrome"] {
            checkExtraction(try fixture(name), label: name, lines: lines)
        }
    }

    // E3: added Khmer text as a FreeText annotation (editable, kept as an annotation object).
    func testE3FreeTextAnnotationRoundTrip() throws {
        try prepare()
        defer { try? writeReport("E3") }
        let document = try fixture("khmer-coretext")
        let page = try XCTUnwrap(document.page(at: 0))
        let added = "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"
        let annotation = PDFAnnotation(bounds: CGRect(x: 60, y: 420, width: 420, height: 40), forType: .freeText, withProperties: nil)
        annotation.contents = added
        annotation.font = NSFont(name: "NotoSansKhmer-Regular", size: 16)
        annotation.fontColor = .black
        annotation.color = .clear
        page.addAnnotation(annotation)

        let out = outDir.appendingPathComponent("e3-freetext-annotation.pdf")
        XCTAssertTrue(document.write(to: out))
        let reopened = try XCTUnwrap(PDFDocument(url: out))
        let reread = try XCTUnwrap(reopened.page(at: 0)).annotations.first { $0.type == "FreeText" }
        report.append("E3 annotation contents after reopen: \(reread?.contents == added ? "identical" : "CHANGED: \(reread?.contents ?? "nil")")")
        report.append("E3 annotation font after reopen: \(reread?.font?.fontName ?? "nil")")
        XCTAssertEqual(reread?.contents, added)
        try renderPNG(try XCTUnwrap(reopened.page(at: 0)), to: "e3-freetext-annotation.png")
    }

    // E4: added Khmer text drawn into the page (flattened delivery copy) with normal Core Text drawing.
    func testE4FlattenedCoreText() throws {
        try prepare()
        defer { try? writeReport("E4") }
        let added = "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"
        let out = outDir.appendingPathComponent("e4-flattened-coretext.pdf")
        try drawOverFixture(to: out) { context in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: added, attributes: [.font: NSFont(name: "NotoSansKhmer-Regular", size: 16)!]))
            context.textPosition = CGPoint(x: 60, y: 430)
            CTLineDraw(line, context)
        }
        checkExtraction(try XCTUnwrap(PDFDocument(url: out)), label: "E4 flattened Core Text", lines: [added])
        try renderPNG(try XCTUnwrap(PDFDocument(url: out)?.page(at: 0)), to: "e4-flattened-coretext.png")
    }

    // E5: visible text as glyph outlines (no extractable text) + invisible logical-order text layer
    // drawn glyph-per-character without shaping, so extractors read Unicode in logical order.
    func testE5OutlinesPlusLogicalTextLayer() throws {
        try prepare()
        defer { try? writeReport("E5") }
        let added = "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"
        let font = NSFont(name: "NotoSansKhmer-Regular", size: 16)!
        let origin = CGPoint(x: 60, y: 430)
        let out = outDir.appendingPathComponent("e5-outlines-plus-text-layer.pdf")
        try drawOverFixture(to: out) { context in
            KhmerPDFText.draw(added, font: font, at: origin, in: context)
        }
        let document = try XCTUnwrap(PDFDocument(url: out))
        checkExtraction(document, label: "E5 outlines + logical text layer", lines: [added])
        try renderPNG(try XCTUnwrap(document.page(at: 0)), to: "e5-outlines-plus-text-layer.png")
    }

    // E6: keep the original page content (PDFKit write) and draw the E5 layers on top from a PDFPage subclass.
    func testE6PDFKitPageOverlay() throws {
        try prepare()
        defer { try? writeReport("E6") }
        let added = "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"
        let source = try fixture("khmer-coretext")
        let document = PDFDocument()
        let page = OverlayPage()
        page.overlay = { context in
            KhmerPDFText.draw(added, font: NSFont(name: "NotoSansKhmer-Regular", size: 16)!, at: CGPoint(x: 60, y: 430), in: context)
        }
        // Copy the original page's content via PDFKit (not via a CGContext redraw).
        let original = try XCTUnwrap(source.page(at: 0))
        document.insert(original, at: 0)
        _ = page
        let out = outDir.appendingPathComponent("e6-pdfkit-overlay.pdf")
        let overlaid = PDFDocument()
        let wrapper = try XCTUnwrap(OverlayPage(source: original))
        wrapper.overlay = page.overlay
        overlaid.insert(wrapper, at: 0)
        XCTAssertTrue(overlaid.write(to: out))
        let reopened = try XCTUnwrap(PDFDocument(url: out))
        checkExtraction(reopened, label: "E6 PDFKit overlay (added line)", lines: [added])
        checkExtraction(reopened, label: "E6 PDFKit overlay (original lines kept?)", lines: try expectedLines.prefix(1).map { $0 })
        try renderPNG(try XCTUnwrap(reopened.page(at: 0)), to: "e6-pdfkit-overlay.png")
    }

    // E7 (input): only the E5 layers on an otherwise empty page of the same size, to be overlaid
    // onto the untouched original by an external tool (qpdf --overlay) in run_pdfkit_spike.sh.
    func testE7OverlayLayerOnly() throws {
        try prepare()
        let source = try XCTUnwrap(try fixture("khmer-coretext").page(at: 0)?.pageRef)
        var box = source.getBoxRect(.mediaBox)
        let url = outDir.appendingPathComponent("e7-overlay-layer.pdf")
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        KhmerPDFText.draw("ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ", font: NSFont(name: "NotoSansKhmer-Regular", size: 16)!,
                          at: CGPoint(x: 60, y: 430), in: context)
        context.endPDFPage()
        context.closePDF()
    }

    /// Copies fixture page 1 into a new PDF and lets `draw` add content on top.
    private func drawOverFixture(to url: URL, draw: (CGContext) -> Void) throws {
        let source = try XCTUnwrap(try fixture("khmer-coretext").page(at: 0)?.pageRef)
        var box = source.getBoxRect(.mediaBox)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.drawPDFPage(source)
        draw(context)
        context.endPDFPage()
        context.closePDF()
    }
}

/// PDFPage that draws extra content after the original page (E6).
final class OverlayPage: PDFPage {
    var overlay: ((CGContext) -> Void)?
    private var source: PDFPage?

    override init() { super.init() }

    convenience init?(source: PDFPage) {
        self.init()
        self.source = source
        setBounds(source.bounds(for: .mediaBox), for: .mediaBox)
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        if let source { source.draw(with: box, to: context) } else { super.draw(with: box, to: context) }
        overlay?(context)
    }
}

/// Candidate export technique under test (E5). Lives with the spike until the spike passes.
enum KhmerPDFText {
    static func draw(_ text: String, font: NSFont, at origin: CGPoint, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)

        // 1. Visible: shaped glyphs as filled outlines (correct appearance, contributes no text).
        context.saveGState()
        context.setFillColor(NSColor.black.cgColor)
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                var transform = CGAffineTransform(translationX: origin.x + position.x, y: origin.y + position.y)
                if let placed = path.copy(using: &transform) {
                    context.addPath(placed)
                }
            }
        }
        context.fillPath()
        context.restoreGState()

        // 2. Invisible: one nominal glyph per UTF-16 unit, in logical order. Glyphs sit edge to edge
        // (each at the end of the previous advance, horizontally scaled to the line width) so extractors
        // do not insert spaces inside words.
        let units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let total = max(advances.reduce(0) { $0 + $1.width }, 1)
        let scale = width / total
        var x: CGFloat = 0
        var positions: [CGPoint] = []
        for advance in advances {
            positions.append(CGPoint(x: x, y: 0))
            x += advance.width
        }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: 1)
        CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)
        context.restoreGState()
    }
}
