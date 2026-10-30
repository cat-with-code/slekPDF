import AppKit
import PDFKit
import XCTest
@testable import SlekPDF

@MainActor
final class KhmerTextRebuilderTests: XCTestCase {
    private let bundle = Bundle(for: KhmerTextRebuilderTests.self)

    private func lines(_ text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Exact-line score (NFC, spaces included) for PDFKit, raw PDFium and the rebuilder; written to the report.
    func testScoresOnFixtures() throws {
        let expected = try JSONDecoder().decode([String].self, from: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "khmer-sample-lines", withExtension: "json"))))
            .map { $0.precomposedStringWithCanonicalMapping }
        let multipage: [[String]] = [
            ["ទំព័រទី ១ · Khmer / English document", "សាលារៀនបឋមសិក្សា ភូមិថ្មី", "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ", "ឈ្មោះ សាលារៀន បឋមសិក្សា"],
            ["ទំព័រទី ២ · Report", "សាលារៀន ក្រសួងអប់រំ យុវជន និងកីឡា", "ស្ត្រី ក្រសួង ព្រះរាជាណាចក្រកម្ពុជា", "ឈ្មោះ សាលារៀន ទី ២"],
            ["ទំព័រទី ៣ · Invoice", "Invoice លេខ INV-0042 តម្លៃ 12,500 ៛", "លេខ ០១២៣៤៥៦៧៨៩ · ថ្ងៃទី ៣០ ខែតុលា ឆ្នាំ ២០២៦", "សាលារៀន ភូមិថ្មី"],
        ]
        var report: [String] = []
        for (name, pages) in [("khmer-coretext", [expected]), ("khmer-chrome", [expected]), ("khmer-multipage", multipage)] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "pdf"))
            let pdfium = try PDFiumDocument(url: url)
            let pdfkit = try XCTUnwrap(PDFDocument(url: url))
            var scores = (pdfkit: 0, raw: 0, rebuilt: 0, total: 0)
            for (pageIndex, want) in pages.enumerated() {
                let rebuilt = KhmerTextRebuilder.rebuild(try pdfium.characters(onPage: pageIndex)).text
                let raw = try pdfium.text(ofPage: pageIndex)
                let kit = pdfkit.page(at: pageIndex)?.string ?? ""
                for line in want {
                    scores.total += 1
                    if lines(kit).contains(line) { scores.pdfkit += 1 }
                    if lines(raw).contains(line) { scores.raw += 1 }
                    if lines(rebuilt).contains(line) { scores.rebuilt += 1 } else { report.append("  \(name) p\(pageIndex + 1) MISS: \(line)") }
                }
                report.append("  \(name) p\(pageIndex + 1) rebuilt: " + lines(rebuilt).joined(separator: " ⏎ "))
            }
            report.insert("\(name): exact lines — PDFKit \(scores.pdfkit)/\(scores.total), PDFium raw \(scores.raw)/\(scores.total), rebuilt \(scores.rebuilt)/\(scores.total)", at: report.startIndex)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rebuilder-report.txt")
        try report.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }

    /// The user's example (multipage page 1, copied through PDFKit) must come out readable.
    func testUserExampleLines() throws {
        let url = try XCTUnwrap(bundle.url(forResource: "khmer-multipage", withExtension: "pdf"))
        let text = KhmerTextRebuilder.rebuild(try PDFiumDocument(url: url).characters(onPage: 0)).text
        for line in ["សាលារៀនបឋមសិក្សា ភូមិថ្មី", "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ", "ឈ្មោះ សាលារៀន បឋមសិក្សា"] {
            XCTAssertTrue(lines(text).contains(line), "missing \(line) in:\n\(text)")
        }
    }

    /// Text already in reading order (Slek PDF's invisible layer) must pass through byte-identical.
    func testInvisibleLogicalLayerIsUntouched() throws {
        FontRegistry.registerBundledFonts()
        let added = "លេខ ១២ ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ ស្ត្រី"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("logical-layer.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        KhmerPDFText.draw(added, font: NSFont(name: "NotoSansKhmer-Regular", size: 16)!, at: CGPoint(x: 60, y: 430), in: context)
        context.endPDFPage()
        context.closePDF()
        let chars = try PDFiumDocument(url: url).characters(onPage: 0)
        XCTAssertTrue(chars.contains { $0.isInvisible })
        let rebuilt = KhmerTextRebuilder.rebuild(chars).text
        XCTAssertEqual(rebuilt.unicodeScalars.filter { !$0.properties.isWhitespace }.map(\.value),
                       added.unicodeScalars.filter { !$0.properties.isWhitespace }.map(\.value))
    }

    /// Synthetic records: a genuinely repeated syllable and Latin "ll" are not duplicates; a stand-alone េ
    /// drawn left of ល attaches to it; a vowel drawn after the next consonant returns to its own.
    func testSyntheticCases() {
        func char(_ index: Int, _ s: String, x: CGFloat, w: CGFloat = 6, origin: CGFloat? = nil, generated: Bool = false) -> PDFiumChar {
            PDFiumChar(index: index, scalar: s.unicodeScalars.first!, isGenerated: generated, isInvisible: false,
                       origin: CGPoint(x: origin ?? x, y: 100), box: CGRect(x: x, y: 96, width: w, height: 10), fontSize: 14)
        }
        // ដដែល drawn as ដ, ែ(left of second ដ), ដ, ល
        let repeated = [char(0, "ដ", x: 0), char(1, "ែ", x: 7, w: 3), char(2, "ដ", x: 11), char(3, "ល", x: 18)]
        XCTAssertEqual(KhmerTextRebuilder.rebuild(repeated).text, "ដដែល")
        let latin = [char(0, "h", x: 0), char(1, "e", x: 6), char(2, "l", x: 12), char(3, "l", x: 18), char(4, "o", x: 24)]
        XCTAssertEqual(KhmerTextRebuilder.rebuild(latin).text, "hello")
        // រួច drawn as រ, ច, ួ (under រ)
        let vowelLater = [char(0, "រ", x: 0, w: 4), char(1, "ច", x: 5), char(2, "ួ", x: 0.5, w: 3, origin: 12)]
        XCTAssertEqual(KhmerTextRebuilder.rebuild(vowelLater).text, "រួច")
        // generated line break on the same baseline is dropped
        let broken = [char(0, "ភ", x: 0), char(1, "ូ", x: 1, origin: 0), char(2, "\n", x: 7, generated: true), char(3, "ម", x: 8)]
        XCTAssertEqual(KhmerTextRebuilder.rebuild(broken).text, "ភូម")
    }
}

@MainActor
final class KhmerCopyAndSearchTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: KhmerCopyAndSearchTests.self).url(forResource: name, withExtension: "pdf"))
    }

    func testCopyWholePageIsReadableKhmer() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-multipage"))
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox)))
        let copied = await session.text(of: selection)
        XCTAssertTrue(copied.contains("សាលារៀនបឋមសិក្សា ភូមិថ្មី"), copied)
        XCTAssertTrue(copied.contains("ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"), copied)
        XCTAssertTrue(copied.contains("ឈ្មោះ សាលារៀន បឋមសិក្សា"), copied)
        XCTAssertFalse(copied.contains("េរៀន"), "visual-order text leaked into the copy")
    }

    func testCopySingleLine() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-multipage"))
        let page = try XCTUnwrap(session.document?.page(at: 0))
        // Third line of page 1 (baseline y = 770 - 2 × 34 = 702).
        let selection = try XCTUnwrap(page.selection(for: CGRect(x: 50, y: 696, width: 500, height: 18)))
        let copied = await session.text(of: selection)
        XCTAssertEqual(copied, "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ")
    }

    func testSearchFindsWordsThatWereInDrawingOrder() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-multipage"))
        for (query, count) in [("ឯកសារនេះ", 1), ("លេខ", 2), ("ខែតុលា", 1), ("រួចហើយ", 1)] {
            session.searchQuery = query
            await session.waitForSearch()
            XCTAssertEqual(session.searchResults.count, count, query)
            XCTAssertTrue(session.searchResults.allSatisfy { !$0.rects.isEmpty }, query)
        }
    }

    func testSearchIgnoresStraySpacesInChromePDF() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-chrome"))
        session.searchQuery = "សាលារៀន"   // extracted as "សាលារៀ ន"
        await session.waitForSearch()
        XCTAssertEqual(session.searchResults.count, 1)
    }
}
