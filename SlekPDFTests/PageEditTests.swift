import PDFKit
import XCTest
@testable import SlekPDF

/// Organize pages (Figma 02): page edits mirror into the view and save as an editable PDF without touching the source.
@MainActor
final class PageEditTests: XCTestCase {
    private func openFixture() async throws -> (DocumentSession, URL) {
        let url = try XCTUnwrap(Bundle(for: PageEditTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        XCTAssertEqual(session.pageCount, 3)
        return (session, url)
    }

    func testReorderRotateDeleteAndUndo() async throws {
        let (session, _) = try await openFixture()
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        let ids = session.pages.map(\.id)

        session.selectedPageIDs = [ids[2]]
        undo.beginUndoGrouping(); session.movePages(by: -1); undo.endUndoGrouping()
        XCTAssertEqual(session.pages.map(\.source), [0, 2, 1])
        XCTAssertTrue(session.hasUnsavedChanges)

        undo.beginUndoGrouping(); session.rotateSelectedPages(); undo.endUndoGrouping()
        XCTAssertEqual(session.document?.page(at: 1)?.rotation, 90)

        session.selectedPageIDs = [ids[0]]
        undo.beginUndoGrouping(); XCTAssertEqual(session.deleteSelectedPages(), 1); undo.endUndoGrouping()
        XCTAssertEqual(session.pages.map(\.source), [2, 1])
        XCTAssertEqual(session.pageCount, 2)

        undo.undo()
        XCTAssertEqual(session.pages.map(\.source), [0, 2, 1])
        undo.undo(); undo.undo()
        XCTAssertEqual(session.pages.map(\.source), [0, 1, 2])
        XCTAssertFalse(session.hasUnsavedChanges)
        await session.close()
    }

    func testSaveWorkWritesANewEditablePDFAndLeavesTheSourceUnchanged() async throws {
        let (session, url) = try await openFixture()
        let sourceBytes = try Data(contentsOf: url)
        let originalLast = try PDFiumDocument(url: url).text(ofPage: 2)
        let ids = session.pages.map(\.id)
        session.selectedPageIDs = [ids[2]]
        session.movePages(to: 0, ids: [ids[2]])
        session.selectedPageIDs = [ids[2]]
        session.rotateSelectedPages()
        session.selectedPageIDs = [ids[1]]
        session.deleteSelectedPages()

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("work-\(UUID()).pdf")
        try await session.saveWork(to: output)
        XCTAssertFalse(session.hasUnsavedChanges)
        let saved = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertEqual(saved.page(at: 0)?.rotation, 90)
        XCTAssertEqual(try PDFiumDocument(url: output).text(ofPage: 0), originalLast, "page order kept, text not redrawn")
        XCTAssertEqual(try Data(contentsOf: url), sourceBytes, "the source file is never changed")
        await session.close()
    }
}

private extension DocumentSession {
    func movePages(to target: Int, ids: Set<PageRef.ID>) { movePages(ids, to: target) }
}
