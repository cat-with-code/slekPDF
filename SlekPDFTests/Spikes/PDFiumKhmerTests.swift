import AppKit
import CoreText
import XCTest
@testable import SlekPDF

/// Spike 01 follow-up: the E2 (search) and E7 (overlay without redrawing) results, repeated through
/// the app's own PDFium wrapper inside the sandboxed app. Exported file is checked independently by
/// Tools/fixtures/run_pdfium_check.sh.
@MainActor
final class PDFiumKhmerTests: XCTestCase {
    private let bundle = Bundle(for: PDFiumKhmerTests.self)
    private let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("pdfium-spike")
    private let added = "ព្រះរាជាណាចក្រកម្ពុជា ជាតិ សាសនា ព្រះមហាក្សត្រ"

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(bundle.url(forResource: name, withExtension: "pdf"))
    }

    private func squash(_ text: String) -> String {
        String(String.UnicodeScalarView(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !$0.properties.isWhitespace }))
    }

    func testSearchKhmerWordsInExistingPDFs() throws {
        let words = ["ភូមិថ្មី", "ព្រះរាជាណាចក្រកម្ពុជា", "ថ្ងៃទី", "ពិនិត្យ", "សាកល្បង", "តម្លៃ", "លេខ"]
        var found: [String: Int] = [:]
        for name in ["khmer-coretext", "khmer-chrome"] {
            let document = try PDFiumDocument(url: try fixtureURL(name))
            found[name] = try words.filter { try document.matchCount(of: $0, onPage: 0) > 0 }.count
        }
        // Same results as pypdfium2 in docs/spikes/01-pdfkit-khmer.md (PDFKit found 2/4 and 0/4).
        XCTAssertGreaterThanOrEqual(found["khmer-coretext"] ?? 0, 6, "\(found)")
        XCTAssertEqual(found["khmer-chrome"], words.count, "\(found)")
    }

    func testOverlayAddsSearchableKhmerWithoutChangingOriginalText() throws {
        FontRegistry.registerBundledFonts()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let sourceURL = try fixtureURL("khmer-coretext")
        let originalText = try PDFiumDocument(url: sourceURL).text(ofPage: 0)

        // Layer page: outlines + invisible logical-order text (KhmerPDFText, spike 01 E5).
        let layerURL = outDir.appendingPathComponent("layer.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(layerURL as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        KhmerPDFText.draw(added, font: NSFont(name: "NotoSansKhmer-Regular", size: 16)!, at: CGPoint(x: 60, y: 430), in: context)
        context.endPDFPage()
        context.closePDF()

        let document = try PDFiumDocument(url: sourceURL)
        try document.overlay(page: 0, with: try PDFiumDocument(url: layerURL))
        let outURL = outDir.appendingPathComponent("pdfium-overlay.pdf")
        try document.save(to: outURL)

        let saved = try PDFiumDocument(url: outURL)
        let savedText = try saved.text(ofPage: 0)
        XCTAssertTrue(squash(savedText).contains(squash(originalText)), "original text changed:\n\(savedText)")
        XCTAssertTrue(squash(savedText).contains(squash(added)), "added text not extractable:\n\(savedText)")
        XCTAssertGreaterThan(try saved.matchCount(of: "ក្សត្រ", onPage: 0), 0)
        try JSONEncoder().encode([added]).write(to: outDir.appendingPathComponent("added.json"))
    }
}
