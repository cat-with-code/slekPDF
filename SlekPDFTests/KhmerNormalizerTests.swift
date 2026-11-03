import PDFKit
import XCTest
@testable import SlekPDF

/// KhmerNormalizer (khmernormalizer / SIL khnormal port) and where Slek applies it: OCR output and Copy.
@MainActor
final class KhmerNormalizerTests: XCTestCase {
    /// Input → output of the reference Python `khmernormalizer.khnormal.khmer_normalize` (generated, not hand-written).
    private let reference: [(String, String)] = [
        ("\u{1780}\u{17b6}\u{17d2}\u{179a}", "\u{1780}\u{17d2}\u{179a}\u{17b6}"),          // vowel typed before subscript ro
        ("\u{1780}\u{17d2}\u{179a}\u{17d2}\u{178f}", "\u{1780}\u{17d2}\u{178f}\u{17d2}\u{179a}"), // subscript ro goes last
        ("\u{1780}\u{17c1}\u{17b8}", "\u{1780}\u{17be}"),                                  // េ + ី → ើ
        ("\u{1780}\u{17c1}\u{17b6}", "\u{1780}\u{17c4}"),                                  // េ + ា → ោ
        ("\u{1780}\u{17c6}\u{17b6}", "\u{1780}\u{17b6}\u{17c6}"),                          // nikahit before aa
        ("\u{1780}\u{17bb}\u{17b7}", "\u{1780}\u{17ca}\u{17b7}"),                          // ុ + ិ → ៊ិ (series 1)
        ("\u{1794}\u{17bb}\u{17b7}", "\u{1794}\u{17c9}\u{17b7}"),                          // ុ + ិ → ៉ិ (ba)
        ("\u{1780}\u{17d2}\u{178a}", "\u{1780}\u{17d2}\u{178f}"),                          // subscript da → ta
        ("\u{1780}\u{17c7}\u{17b7}", "\u{1780}\u{17b7}\u{17c7}"),                          // visarga after the vowel
        ("ចក្រើ", "ចក្រើ"),
        ("សេចក្តីជូនដំណឹង", "សេចក្តីជូនដំណឹង"),
        ("ព្រះរាជាណាចក្រកម្ពុជា", "ព្រះរាជាណាចក្រកម្ពុជា"),
        ("\u{17a2}\u{17c4}\u{1799}", "\u{17a2}\u{17c4}\u{1799}"),
        ("\u{1780}\u{17d2}\u{179a}\u{17d2}\u{179a}", "\u{1780}\u{17d2}\u{179a}\u{17d2}\u{179a}"),
        ("ABC \u{1780}\u{17b6} 123", "ABC \u{1780}\u{17b6} 123"),
    ]

    func testReorderingMatchesTheReferenceImplementation() {
        for (input, expected) in reference {
            XCTAssertEqual(KhmerNormalizer.reorder(input).unicodeScalars.map(\.value), expected.unicodeScalars.map(\.value),
                           "\(input.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    func testCleanupsAndWhatIsLeftAlone() {
        XCTAssertEqual(KhmerNormalizer.normalize("\u{17A3}ក\u{200B}ក"), "អកក", "deprecated ឣ, zero-width space")
        XCTAssertEqual(KhmerNormalizer.normalize("កាាាត់"), "កាត់", "doubled vowel")
        XCTAssertEqual(KhmerNormalizer.normalize("ក\u{17D2}\u{179A}\u{17D2}\u{179A}ា"), "ក\u{17D2}\u{179A}ា", "doubled subscript")
        XCTAssertEqual(KhmerNormalizer.normalize("ឯកសារ ។។  ថ្មី ៗ"), "ឯកសារ។ ថ្មីៗ", "Khmer punctuation and spaces")
        XCTAssertEqual(KhmerNormalizer.normalize("ពេល\nក្រោយ"), "ពេល\nក្រោយ", "line breaks are kept")
        XCTAssertEqual(KhmerNormalizer.normalize("café — “Résumé”  2026"), "café — “Résumé”  2026", "text without Khmer is not touched")
        XCTAssertEqual(KhmerNormalizer.normalize("។ល។"), "។ល។", "not turned into the discouraged ៘")
    }

    func testALayerInAnotherScriptIsNotUsableText() {
        XCTAssertTrue(PDFiumService.isUsableText("ព្រះរាជាណាចក្រកម្ពុជា ជាតិ សាសនា ព្រះមហាក្សត្រ"))
        XCTAssertTrue(PDFiumService.isUsableText("This page has a normal English text layer."))
        // Khmer read as Thai by another OCR program.
        XCTAssertFalse(PDFiumService.isUsableText("ประกาศ ราชอาณาจักรกัมพูชา ชาติ ศาสนา พระมหากษัตริย์"))
        XCTAssertFalse(PDFiumService.isUsableText("12"))
    }

    func testLegacyFontsAndBrokenKhmerLayersAreUnreadable() {
        let clean = String(repeating: "ព្រះរាជាណាចក្រកម្ពុជា ជាតិ សាសនា ព្រះមហាក្សត្រ អង្គភាព លេខកូដ ", count: 3)
        XCTAssertEqual(PDFiumService.layerQuality(text: clean, fonts: ["KhmerOS": 150]), .usable)
        XCTAssertEqual(PDFiumService.layerQuality(text: "Quarterly report for the project team", fonts: ["ArialMT": 32]), .usable)
        XCTAssertEqual(PDFiumService.layerQuality(text: "12", fonts: ["ArialMT": 2]), .none)
        // Limon draws Khmer at Latin code points: even a short heading makes the layer gibberish.
        XCTAssertEqual(PDFiumService.layerQuality(text: "pøaksBaØacracr (ROAD SIGNS) R1-01 R1-02 R1-03 R1-04",
                                                  fonts: ["LimonS1": 14, "ArialMT": 170]), .unreadable)
        XCTAssertTrue(PDFiumService.isLegacyKhmerFont("ABC-TEXT-05"))
        XCTAssertTrue(PDFiumService.isLegacyKhmerFont("LmnTTFantBig"))
        XCTAssertFalse(PDFiumService.isLegacyKhmerFont("ABCDiatype-Regular"), "a Latin design font, not ABC Khmer")
        XCTAssertFalse(PDFiumService.isLegacyKhmerFont("KhmerOS"))
        XCTAssertFalse(PDFiumService.isLegacyKhmerFont("ArialMT"))
        // A Unicode font with a broken glyph map: "ង្" in place of េ (លេខ → ង្លខ), marks with no consonant.
        let broken = String(repeating: "ង្លខកូដ ៖ សញ្ញា ង្ េះ ហាម ង្លើ ា ទំហំ ផ្លូវ ", count: 4)
        XCTAssertEqual(PDFiumService.layerQuality(text: broken, fonts: ["KhmerOS": 120]), .unreadable)
    }

    func testCopyOnARecognizedPageUsesSlekText() async throws {
        let url = try XCTUnwrap(Bundle(for: KhmerNormalizerTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox)))
        let firstLine = try XCTUnwrap(selection.selectionsByLine().first { !$0.bounds(for: page).isEmpty })
        let bounds = firstLine.bounds(for: page)
        // Out-of-order Khmer as OCR might produce it; Copy gives it in standard order.
        session.setOCR(OCRPage(lines: [OCRLine(bounds: bounds, text: "\u{1780}\u{17b6}\u{17d2}\u{179a}", confidence: 90)],
                               languages: "khm", date: Date()), for: session.pages[0].id)
        let copied = await session.text(of: firstLine)
        XCTAssertEqual(copied.unicodeScalars.map(\.value), [0x1780, 0x17D2, 0x179A, 0x17B6])
        await session.close()
    }

    func testCopyingSeveralLinesOfARecognizedPageGivesEachLineOnce() async throws {
        let url = try XCTUnwrap(Bundle(for: KhmerNormalizerTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox)))
        let lines = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(lines.count, 2)
        // OCR lines a little taller than the PDF's lines, so each touches its neighbours.
        let ocr = lines.enumerated().map { index, rect in
            OCRLine(bounds: rect.insetBy(dx: 0, dy: -3), text: "បន្ទាត់\(index)", confidence: 95)
        }
        session.setOCR(OCRPage(lines: ocr, languages: "khm", date: Date()), for: session.pages[0].id)
        let copied = await session.text(of: selection)
        XCTAssertEqual(copied, ocr.map(\.text).joined(separator: "\n"))
        await session.close()
    }
}
