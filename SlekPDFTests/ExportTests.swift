import AppKit
import PDFKit
import XCTest
@testable import SlekPDF

/// Export step 1 (Figma 05, 08, 09, 14, 18, 36, 37): Word, searchable PDF and plain text from the PDF's own text,
/// reviewed OCR and (optionally) added text; already-exists and could-not-save paths.
@MainActor
final class ExportTests: XCTestCase {
    private let khmer = "ព្រះរាជាណាចក្រកម្ពុជា"

    private func open() async throws -> (DocumentSession, URL) {
        FontRegistry.registerBundledFonts()
        let url = try XCTUnwrap(Bundle(for: ExportTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        session.workspace = .export
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        session.exportSettings.folder = folder
        return (session, folder)
    }

    private func export(_ session: DocumentSession, _ format: ExportFormat, to folder: URL, name: String) async -> URL {
        session.exportSettings.format = format
        let url = folder.appendingPathComponent(name)
        await session.runExport(session.exportPageIndices ?? [], to: url, access: SaveDestination.Access(url: folder) {}, .en).value
        return url
    }

    private func squash(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isWhitespace })) }

    func testLinesBecomeHeadingsAndParagraphs() {
        let lines = [
            ExportLine(text: "របាយការណ៍", box: CGRect(x: 72, y: 760, width: 200, height: 30), fontSize: 24),
            ExportLine(text: "ឯកសារនេះបង្ហាញ", box: CGRect(x: 72, y: 720, width: 300, height: 14), fontSize: 12),
            ExportLine(text: "លទ្ធផលសិក្សា", box: CGRect(x: 72, y: 704, width: 300, height: 14), fontSize: 12),
            ExportLine(text: "Results are", box: CGRect(x: 72, y: 688, width: 300, height: 14), fontSize: 12),
            ExportLine(text: "listed.", box: CGRect(x: 72, y: 672, width: 300, height: 14), fontSize: 12),
            ExportLine(text: "Next paragraph", box: CGRect(x: 72, y: 600, width: 300, height: 14), fontSize: 12),
        ]
        let blocks = ExportBuilder.blocks(lines)
        XCTAssertEqual(ExportBuilder.plainText(blocks), "របាយការណ៍\nឯកសារនេះបង្ហាញលទ្ធផលសិក្សា Results are listed.\nNext paragraph")
        guard case let .heading(level, _) = blocks.first else { return XCTFail("no heading") }
        XCTAssertEqual(level, 1)
    }

    func testWordExportCarriesThePagesKhmerText() async throws {
        let (session, folder) = try await open()
        let url = await export(session, .word, to: folder, name: "Document.docx")
        XCTAssertNil(session.exportJob)
        XCTAssertEqual(session.toasts.current?.message, "Export finished · Document.docx")
        let read = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        let expected = await PDFiumService.shared.textLines(try XCTUnwrap(session.pdfiumID), page: 0).map(\.text)
        XCTAssertFalse(expected.isEmpty)
        for line in expected { XCTAssertTrue(squash(read.string).contains(squash(line)), "missing \(line)") }
        await session.close()
    }

    func testPlainTextMarksPageBreaksAndUsesReviewedOCR() async throws {
        let (session, folder) = try await open()
        let ocr = OCRPage(lines: [OCRLine(bounds: CGRect(x: 72, y: 700, width: 300, height: 20), text: "ព្រះរាជាណាចក្រកម្ពជា", confidence: 50,
                                          correction: khmer, reviewed: true)], languages: "khm", date: Date())
        session.setOCR(ocr, for: session.pages[1].id)
        let url = await export(session, .plainText, to: folder, name: "Document.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n--- page 2 ---\n\(khmer)\n--- page 3 ---\n"), text)
        await session.close()
    }

    func testSearchablePDFAddsOCRTextAndOptionallyAddedText() async throws {
        let (session, folder) = try await open()
        session.setOCR(OCRPage(lines: [OCRLine(bounds: CGRect(x: 72, y: 500, width: 260, height: 24), text: khmer, confidence: 90)],
                               languages: "khm", date: Date()), for: session.pages[0].id)
        let box = PageAnnotation(bounds: CGRect(x: 72, y: 300, width: 240, height: 44),
                                 content: .textBox(text: "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ", style: TextBoxStyle()))
        session.addAnnotation(box, toPageAt: 0)

        let without = await export(session, .searchablePDF, to: folder, name: "a.pdf")
        let plain = try PDFiumDocument(url: without).text(ofPage: 0)
        XCTAssertTrue(squash(plain).contains(khmer), "OCR text is searchable: \(plain)")
        XCTAssertFalse(squash(plain).contains("ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"))
        XCTAssertTrue(try PDFiumDocument(url: without).slekAnnotations(page: 0).isEmpty, "a delivery copy has no editable Slek annotations")

        session.exportSettings.includeAddedText = true
        let with = await export(session, .searchablePDF, to: folder, name: "b.pdf")
        XCTAssertTrue(squash(try PDFiumDocument(url: with).text(ofPage: 0)).contains("ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"))
        XCTAssertEqual(PDFDocument(url: with)?.pageCount, 3)
        await session.close()
    }

    func testExistingFileAsksAndKeepBothPicksAFreeName() async throws {
        let (session, folder) = try await open()
        session.exportSettings.fileName = "Document.txt"
        session.exportSettings.format = .plainText
        try Data("old".utf8).write(to: folder.appendingPathComponent("Document.txt"))
        session.requestExport(.en, AppState(defaults: UserDefaults(suiteName: "export-\(UUID())")!))
        XCTAssertEqual(session.organizeDialog, .exportExists)
        XCTAssertEqual(session.pendingExport?.url.lastPathComponent, "Document.txt")
        XCTAssertEqual(DocumentSession.freeURL(near: folder.appendingPathComponent("Document.txt")).lastPathComponent, "Document 2.txt")
        await session.close()
    }

    func testAFolderThatCannotBeWrittenShowsCouldNotSave() async throws {
        let (session, folder) = try await open()
        let missing = folder.appendingPathComponent("gone/Document.txt")
        session.exportSettings.format = .plainText
        await session.runExport([0], to: missing, access: SaveDestination.Access(url: folder) {}, .en).value
        XCTAssertEqual(session.organizeDialog, .exportFailed)
        XCTAssertEqual(session.pendingExport?.url, missing)
        await session.close()
    }
}
