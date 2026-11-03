import AppKit
import PDFKit
import XCTest
@testable import SlekPDF

/// 19 Merge PDFs, 21 Split into PDFs and 16 Save changes before closing?.
@MainActor
final class MergeSplitTests: XCTestCase {
    func testPageRanges() {
        XCTAssertEqual(PageRanges.parse("1–2, 3", pageCount: 3), [[0, 1], [2]])
        XCTAssertEqual(PageRanges.parse("១-២,៣", pageCount: 3), [[0, 1], [2]])
        XCTAssertNil(PageRanges.parse("2-1", pageCount: 3))
        XCTAssertNil(PageRanges.parse("4", pageCount: 3))
        XCTAssertNil(PageRanges.parse("", pageCount: 3))
        XCTAssertNil(PageRanges.parse("1-2-3", pageCount: 3))
    }

    func testMergeAndSplitWriteNewPDFs() async throws {
        let url = try XCTUnwrap(Bundle(for: MergeSplitTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        let merged = FileManager.default.temporaryDirectory.appendingPathComponent("merged-\(UUID()).pdf")
        try await PDFiumService.shared.writePDF(session.editedPageSources() + (0..<3).map { .file(url, page: $0) }, to: merged)
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 6)

        let part = FileManager.default.temporaryDirectory.appendingPathComponent("part-\(UUID()).pdf")
        try await PDFiumService.shared.writePDF(session.editedPageSources([1, 2]), to: part)
        XCTAssertEqual(PDFDocument(url: part)?.pageCount, 2)
        XCTAssertEqual(try PDFiumDocument(url: part).text(ofPage: 0), try PDFiumDocument(url: url).text(ofPage: 1))
        await session.close()
    }

    func testClosingWithUnsavedChangesAsksFirst() async throws {
        let url = try XCTUnwrap(Bundle(for: MergeSplitTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        let window = NSWindow()
        let guardDelegate = CloseGuardDelegate(session: session, original: nil)
        XCTAssertTrue(guardDelegate.windowShouldClose(window), "no changes: closes")
        session.rotateSelectedPages()
        XCTAssertFalse(guardDelegate.windowShouldClose(window))
        XCTAssertEqual(session.organizeDialog, .closeConfirm)
        session.organizeDialog = nil
        session.discardChanges = true
        XCTAssertTrue(guardDelegate.windowShouldClose(window), "after Don’t save")
        await session.close()
    }
}
