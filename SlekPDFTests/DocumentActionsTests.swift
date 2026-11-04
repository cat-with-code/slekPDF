import AppKit
import PDFKit
import XCTest
@testable import SlekPDF

/// Insert Pages from File…, Rotate view, Select/copy text, recovery copies (Figma 15) and the print comments summary.
@MainActor
final class DocumentActionsTests: XCTestCase {
    private func fixture(_ name: String = "khmer-multipage") throws -> URL {
        try XCTUnwrap(Bundle(for: DocumentActionsTests.self).url(forResource: name, withExtension: "pdf"))
    }

    private func open(_ url: URL? = nil, recovery folder: URL? = nil) async throws -> DocumentSession {
        let session = DocumentSession()
        if let folder { session.recoveryStore = RecoveryStore(folder: folder) }
        await session.open(try url ?? fixture())
        XCTAssertNotNil(session.document)
        return session
    }

    func testInsertedPagesComeAfterTheSelectionUndoAndSaveWithTheirOwnText() async throws {
        let session = try await open()
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        session.selectedPageIDs = [session.pages[0].id]
        let other = try fixture("khmer-coretext")
        undo.beginUndoGrouping()
        let inserted = await session.insertPages(from: other)
        undo.endUndoGrouping()
        XCTAssertTrue(inserted)
        let otherCount = try XCTUnwrap(PDFDocument(url: other)?.pageCount)
        XCTAssertEqual(session.pageCount, 3 + otherCount)
        XCTAssertEqual(session.pages[1].file, other)
        XCTAssertEqual(session.selectedPageIDs, Set(session.pages[1...otherCount].map(\.id)))

        // Text of an inserted page comes from its own file.
        let content = await session.exportPages([1], includeAddedText: false)
        let expected = try PDFiumDocument(url: other).text(ofPage: 0)
        let squash = { (text: String) in String(String.UnicodeScalarView(text.unicodeScalars.filter { !$0.properties.isWhitespace })) }
        XCTAssertTrue(squash(expected).hasPrefix(squash(ExportBuilder.plainText(content[0].blocks)).prefix(10)),
                      ExportBuilder.plainText(content[0].blocks))

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("inserted-\(UUID()).pdf")
        try await session.saveWork(to: output)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 3 + otherCount)

        undo.undo()
        XCTAssertEqual(session.pageCount, 3)
        await session.close()
    }

    func testRotateViewTurnsOnlyTheScreen() async throws {
        let session = try await open()
        let before = try XCTUnwrap(session.document?.page(at: 0)?.rotation)
        session.rotateView()
        XCTAssertEqual(session.document?.page(at: 0)?.rotation, (before + 90) % 360)
        XCTAssertEqual(session.pages[0].quarterTurns, 0)
        XCTAssertFalse(session.hasUnsavedChanges)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("view-\(UUID()).pdf")
        try await session.saveWork(to: output)
        XCTAssertEqual(PDFDocument(url: output)?.page(at: 0)?.rotation, before, "saved work is not turned")
        await session.close()
    }

    func testSelectCopyTextPutsThePagesReadableTextOnTheClipboard() async throws {
        let session = try await open()
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        await session.copyPageText(.en)
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        let lines = await PDFiumService.shared.textLines(try XCTUnwrap(session.pdfiumID), page: 0).map(\.text)
        XCTAssertEqual(copied, lines.joined(separator: "\n"))
        XCTAssertEqual(session.toasts.current?.message, "Copied the text of page 1")
        await session.close()
    }

    func testRecoveryCopyIsWrittenRemovedOnSaveAndReopensAsUnsavedWork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID())")
        let store = RecoveryStore(folder: folder)
        let session = try await open(recovery: folder)
        session.selectedPageIDs = [session.pages[0].id]
        session.rotateSelectedPages()
        session.addAnnotation(PageAnnotation(bounds: CGRect(x: 72, y: 600, width: 24, height: 24),
                                             content: .comment(CommentInfo(text: "ពិនិត្យ", author: "A", date: Date()))), toPageAt: 1)
        try await Task.sleep(nanoseconds: 3_600_000_000)
        let entry = try XCTUnwrap(store.entries().first)
        XCTAssertEqual(entry.fileName, "khmer-multipage.pdf")
        XCTAssertEqual(entry.changes, 2)

        // What a crash leaves behind reopens with the edits, unsaved, under the document's name.
        let recovered = try await open(recovery: folder)
        await recovered.close()
        await recovered.openRecovered(entry)
        XCTAssertEqual(recovered.fileName, "khmer-multipage.pdf")
        XCTAssertTrue(recovered.hasUnsavedChanges)
        XCTAssertEqual(recovered.document?.page(at: 0)?.rotation, 90)
        XCTAssertEqual(recovered.comments.first?.info.text, "ពិនិត្យ")

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("recovered-\(UUID()).pdf")
        try await session.saveWork(to: output)
        try await recovered.saveWork(to: output)
        XCTAssertTrue(store.entries().isEmpty, "saving removes the copies")
        XCTAssertFalse(recovered.hasUnsavedChanges)
        await session.close()
        await recovered.close()
    }

    func testCommentsSummaryPageListsTheComments() async throws {
        FontRegistry.registerBundledFonts()
        let session = try await open()
        session.addAnnotation(PageAnnotation(bounds: CGRect(x: 72, y: 600, width: 24, height: 24),
                                             content: .comment(CommentInfo(text: "Check the spelling", author: DocumentSession.currentAuthor,
                                                                           date: Date(), quote: "ឈ្មោះ"))), toPageAt: 2)
        let page = try XCTUnwrap(CommentsSummary.page(session.comments, size: CGSize(width: 595, height: 842), language: .en))
        let text = page.string ?? ""
        XCTAssertTrue(text.contains("Comments · 1"), text)
        XCTAssertTrue(text.contains("Check the spelling"), text)
        XCTAssertTrue(text.contains("Page 3"), text)
        XCTAssertNil(CommentsSummary.page([], size: CGSize(width: 595, height: 842), language: .en))
        await session.close()
    }

    /// Title Bar Home: back to the start screen; unsaved work asks 16 Save changes? first (Cancel stays, Don't Save goes).
    func testHomeGoesBackToTheStartScreenAndAsksAboutUnsavedWork() async throws {
        let clean = try await open()
        clean.goHome()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(clean.document, "nothing to save: straight to the start screen")

        let session = try await open()
        session.rotateView()
        session.selectedPageIDs = [session.pages[0].id]
        session.rotateSelectedPages()
        XCTAssertTrue(session.hasUnsavedChanges)
        session.goHome()
        XCTAssertEqual(session.organizeDialog, .closeConfirm)
        XCTAssertNotNil(session.document)
        // Cancel: stays on the document.
        session.organizeDialog = nil
        session.goHomeAfterDecision = false
        XCTAssertNotNil(session.document)
        // Don't Save: goes home, the window stays open.
        session.goHome()
        session.organizeDialog = nil
        session.discardChanges = true
        session.closeWindowAfterDecision()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(session.document)
        XCTAssertFalse(session.discardChanges)
    }
}
