import PDFKit
import XCTest
@testable import SlekPDF

/// Khmer OCR step 1 (Figma 04 settings, 12, 39, 41): recognition runs in the background on the chosen pages, lines land
/// in page space (also on turned pages), results undo, save into editable work and reopen; cancel keeps finished pages.
@MainActor
final class OCRWorkspaceTests: XCTestCase {
    private func open(_ url: URL? = nil) async throws -> DocumentSession {
        let fixture = try url ?? XCTUnwrap(Bundle(for: OCRWorkspaceTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(fixture)
        session.workspace = .khmerOCR
        // The fixture has a text layer; turn skipping off so OCR reads the rendered pages.
        session.ocrSettings.skipPagesWithText = false
        return session
    }

    /// Union of the PDFium character boxes of a page (where the real text is).
    private func textArea(_ url: URL, page: Int) throws -> CGRect {
        let boxes = try PDFiumDocument(url: url).characters(onPage: page).filter { !$0.isGenerated && !$0.box.isEmpty }.map(\.box)
        return try XCTUnwrap(boxes.dropFirst().reduce(boxes.first) { $0?.union($1) })
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        return inter.isNull ? 0 : inter.width * inter.height / (a.width * a.height)
    }

    func testRecognizesAPageIntoLinesInPageSpace() async throws {
        let url = try XCTUnwrap(Bundle(for: OCRWorkspaceTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = try await open(url)
        session.ocrSettings.scope = .current
        await session.startRecognition([0], .en)?.value
        XCTAssertNil(session.ocrJob)
        XCTAssertNil(session.organizeDialog)
        let ocr = try XCTUnwrap(session.ocrResults[session.pages[0].id])
        XCTAssertFalse(ocr.lines.isEmpty)
        XCTAssertEqual(ocr.languages, "khm+eng")
        XCTAssertTrue(ocr.text.unicodeScalars.contains { (0x1780...0x17FF).contains($0.value) }, "no Khmer read: \(ocr.text)")
        let area = try textArea(url, page: 0).insetBy(dx: -6, dy: -6)
        for line in ocr.lines {
            XCTAssertGreaterThan(overlap(line.bounds, area), 0.8, "line \(line.text) at \(line.bounds) is outside the page text \(area)")
        }
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(session.toasts.current?.tone, .success)
        await session.close()
    }

    /// A sideways scan turned upright in Organize: OCR reads the turned page, and the line boxes land on the text in the
    /// page's own (unturned) space.
    func testASidewaysPageTurnedUprightIsReadAndMappedBack() async throws {
        FontRegistry.registerBundledFonts()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sideways-\(UUID()).pdf")
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.translateBy(x: 120, y: 120)
        context.rotate(by: .pi / 2)  // baseline runs up the page: the page reads upright once turned 90° clockwise
        let font = CTFontCreateWithName("NotoSansKhmer-Regular" as CFString, 28, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "ព្រះរាជាណាចក្រកម្ពុជា ជាតិ សាសនា ព្រះមហាក្សត្រ",
                                                                       attributes: [.font: font]))
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let session = try await open(url)
        session.selectedPageIDs = [session.pages[0].id]
        session.rotateSelectedPages()
        await session.startRecognition([0], .en)?.value
        let lines = try XCTUnwrap(session.ocrResults[session.pages[0].id]?.lines)
        XCTAssertFalse(lines.isEmpty)
        // OCR is not exact (it read កម្ពជា for កម្ពុជា here); the line must still be found and read as Khmer.
        XCTAssertTrue(lines.map(\.text).joined().contains("ព្រះរាជាណាចក្រ"), "\(lines.map(\.text))")
        let area = try textArea(url, page: 0).insetBy(dx: -6, dy: -6)
        XCTAssertGreaterThan(area.height, area.width, "the text runs up the unturned page")
        for line in lines {
            XCTAssertGreaterThan(line.bounds.height, line.bounds.width, "box \(line.bounds) should be upright in page space")
            XCTAssertGreaterThan(overlap(line.bounds, area), 0.8, "\(line.bounds) vs \(area)")
        }
        await session.close()
    }

    func testPagesWithUsableTextAreSkipped() async throws {
        let session = try await open()
        session.ocrSettings.skipPagesWithText = true
        await session.startRecognition([0, 1, 2], .en)?.value
        XCTAssertTrue(session.ocrResults.isEmpty)
        XCTAssertEqual(session.toasts.current?.message, "No text was found on these pages.")
        await session.close()
    }

    func testPageScopeAndTheInvalidRangeOf41() async throws {
        let session = try await open()
        XCTAssertEqual(session.ocrPageIndices, [0, 1, 2])
        session.currentPageIndex = 1
        session.ocrSettings.scope = .current
        XCTAssertEqual(session.ocrPageIndices, [1])
        session.ocrSettings.scope = .custom
        session.ocrSettings.customRange = "៣, 1–2, 2"
        XCTAssertEqual(session.ocrPageIndices, [2, 0, 1])
        session.ocrSettings.customRange = "1–9"
        XCTAssertNil(session.ocrPageIndices)
        session.requestRecognition(.en)
        XCTAssertNil(session.ocrJob, "an invalid range does not run")
        XCTAssertEqual(CopyCatalog.shared.count(.fmtDocumentHasNPagesUsePagesLike, .en, session.pageCount),
                       "This document has 3 pages. Use pages like 1–3, 5.")
        await session.close()
    }

    func testReviewedPagesAskBeforeRecognizingAgain() async throws {
        let session = try await open()
        let reviewed = OCRPage(lines: [OCRLine(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), text: "ក", confidence: 50,
                                               correction: "ខ", reviewed: true)], languages: "khm", date: Date())
        session.setOCR(reviewed, for: session.pages[1].id)
        session.requestRecognition(.en)
        XCTAssertEqual(session.organizeDialog, .recognizeAgain)
        XCTAssertEqual(session.pendingOCRPages, [0, 1, 2])
        XCTAssertEqual(session.reviewedPendingPageCount, 1)
        XCTAssertNil(session.ocrJob)
        await session.close()
    }

    func testCancelKeepsFinishedPagesAndStops() async throws {
        let session = try await open()
        let task = session.startRecognition([0, 1, 2], .en)
        XCTAssertEqual(session.organizeDialog, .recognizing)
        session.runRecognitionInBackground()
        XCTAssertNil(session.organizeDialog)
        XCTAssertNotNil(session.ocrJob, "still running in the background")
        session.cancelRecognition()
        await task?.value
        XCTAssertNil(session.ocrJob)
        XCTAssertLessThan(session.ocrResults.count, 3)
        XCTAssertEqual(session.toasts.current?.message, "Recognition stopped. Finished pages are kept.")
        await session.close()
    }

    func testResultsUndoSaveAndReopen() async throws {
        let session = try await open()
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        let ocr = OCRPage(lines: [OCRLine(bounds: CGRect(x: 72, y: 700, width: 300, height: 20), text: "សាលារៀនបឋមសិក្សា", confidence: 62.5,
                                          correction: "សាលារៀនបឋមសិក្សា ភូមិថ្មី", reviewed: true)],
                          languages: "khm+eng", date: Date(timeIntervalSinceReferenceDate: 800_000_000))
        undo.beginUndoGrouping(); session.setOCR(ocr, for: session.pages[2].id); undo.endUndoGrouping()
        XCTAssertTrue(session.hasUnsavedChanges)
        undo.undo()
        XCTAssertNil(session.ocrResults[session.pages[2].id])
        XCTAssertFalse(session.hasUnsavedChanges)
        undo.redo()
        session.undoManager = nil

        session.movePages([session.pages[2].id], to: 0)
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID()).pdf")
        try await session.saveWork(to: first)
        XCTAssertFalse(session.hasUnsavedChanges)
        await session.close()

        let reopened = try await open(first)
        XCTAssertEqual(reopened.ocrResults[reopened.pages[0].id], ocr, "ids, text, correction, review and confidence come back")
        XCTAssertFalse(reopened.hasUnsavedChanges)
        XCTAssertEqual(reopened.document?.page(at: 0)?.annotations.count, 0, "the hidden OCR note is not shown by PDFKit")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID()).pdf")
        try await reopened.saveWork(to: second)
        await reopened.close()
        let resaved = try PDFiumDocument(url: second)
        XCTAssertEqual(try resaved.slekOCR(page: 0), ocr)
        XCTAssertNil(try resaved.slekOCR(page: 1))
    }
}
