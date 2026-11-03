import AppKit
import PDFKit
import XCTest
@testable import SlekPDF

/// Annotate step 2 (Figma 03): highlight text, write / edit / reply / resolve / delete comments, canvas keys and menu.
@MainActor
final class AnnotateInteractionTests: XCTestCase {
    private func open() async throws -> DocumentSession {
        let url = try XCTUnwrap(Bundle(for: AnnotateInteractionTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        XCTAssertEqual(session.pageCount, 3)
        session.workspace = .annotate
        return session
    }

    private func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testHighlightingASelectionStoresOneRectanglePerLineAndThePDFiumText() async throws {
        let session = try await open()
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        let selection = try XCTUnwrap(page.selection(for: CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2)))
        let lines = selection.selectionsByLine().filter { !$0.bounds(for: page).isEmpty }
        XCTAssertGreaterThan(lines.count, 0, "fixture page has no text in the top half")
        let expectedText = await session.text(of: selection)

        await session.highlight(selection)
        let stored = session.annotations[session.pages[0].id] ?? []
        XCTAssertEqual(stored.count, 1)
        guard case let .highlight(info) = stored.first?.content else { return XCTFail("no highlight") }
        XCTAssertEqual(info.lines.count, lines.count)
        XCTAssertEqual(info.text, expectedText)
        XCTAssertFalse(info.text.isEmpty)
        XCTAssertTrue(session.hasUnsavedChanges)
        await session.close()
    }

    func testWritingEditingReplyingResolvingAndUndoingAComment() async throws {
        let session = try await open()
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        session.annotateTool = .comment

        session.beginComment(onPageAt: 1, at: CGPoint(x: 100, y: 300), quote: "ឈ្មោះសាលារៀន")
        XCTAssertEqual(session.commentDraft?.pageIndex, 1)
        session.saveCommentDraft()  // empty: not saved
        XCTAssertTrue(session.comments.isEmpty)
        session.commentDraft?.text = "  សូមពិនិត្យអក្ខរាវិរុទ្ធនៃឈ្មោះខ្មែរនេះ។ "
        undo.beginUndoGrouping(); session.saveCommentDraft(); undo.endUndoGrouping()

        let comment = try XCTUnwrap(session.comments.first)
        XCTAssertEqual(comment.pageIndex, 1)
        XCTAssertEqual(comment.info.text, "សូមពិនិត្យអក្ខរាវិរុទ្ធនៃឈ្មោះខ្មែរនេះ។")
        XCTAssertEqual(comment.info.quote, "ឈ្មោះសាលារៀន")
        XCTAssertEqual(comment.info.author, DocumentSession.currentAuthor)
        XCTAssertEqual(comment.annotation.bounds.origin, CGPoint(x: 100, y: 300))
        XCTAssertNil(session.commentDraft)
        XCTAssertEqual(session.annotateTool, .editText)
        XCTAssertEqual(session.selectedAnnotationID, comment.id)
        let pin = try XCTUnwrap(session.document?.page(at: 1)?.annotations.compactMap { $0 as? SlekPDFAnnotation }.first)
        XCTAssertTrue(pin.isSelected)

        session.beginEditing(comment.id)
        XCTAssertEqual(session.commentDraft?.text, comment.info.text)
        session.commentDraft?.text = "Edited"
        undo.beginUndoGrouping(); session.saveCommentDraft(); undo.endUndoGrouping()
        undo.beginUndoGrouping(); session.addReply(to: comment.id, text: "បាទ"); undo.endUndoGrouping()
        undo.beginUndoGrouping(); session.setResolved(comment.id, true); undo.endUndoGrouping()
        var info = try XCTUnwrap(session.comments.first?.info)
        XCTAssertEqual(info.text, "Edited")
        XCTAssertEqual(info.replies.map(\.text), ["បាទ"])
        XCTAssertTrue(info.resolved)

        undo.undo()
        info = try XCTUnwrap(session.comments.first?.info)
        XCTAssertFalse(info.resolved)
        undo.undo(); undo.undo()
        XCTAssertEqual(session.comments.first?.info.text, comment.info.text)
        undo.undo()
        XCTAssertTrue(session.comments.isEmpty)
        XCTAssertFalse(session.hasUnsavedChanges)
        await session.close()
    }

    func testCancelledCommentAddsNothingAndPinsStayOnThePage() async throws {
        let session = try await open()
        session.beginComment(onPageAt: 0, at: CGPoint(x: -50, y: 10_000))
        let box = try XCTUnwrap(session.document?.page(at: 0)?.bounds(for: .mediaBox))
        let anchor = try XCTUnwrap(session.commentDraft?.anchor)
        XCTAssertTrue(box.contains(CGRect(origin: anchor, size: CGSize(width: SlekPDFAnnotation.pinSize, height: SlekPDFAnnotation.pinSize))))
        session.cancelCommentDraft()
        XCTAssertNil(session.commentDraft)
        XCTAssertTrue(session.comments.isEmpty)
        XCTAssertFalse(session.hasUnsavedChanges)
        await session.close()
    }

    func testCommentsAreListedInReadingOrder() async throws {
        let session = try await open()
        for (page, y, text) in [(1, 500.0, "c"), (0, 200.0, "b"), (0, 700.0, "a")] {
            session.beginComment(onPageAt: page, at: CGPoint(x: 50, y: y))
            session.commentDraft?.text = text
            session.saveCommentDraft()
        }
        XCTAssertEqual(session.comments.map(\.info.text), ["a", "b", "c"])
        // Reordering pages reorders the list.
        session.movePages([session.pages[1].id], to: 0)
        XCTAssertEqual(session.comments.map(\.info.text), ["c", "a", "b"])
        await session.close()
    }

    func testCanvasKeysChooseToolsEscapeAndDelete() async throws {
        let session = try await open()
        XCTAssertTrue(session.handleAnnotateKey(key("h", code: 4)))
        XCTAssertEqual(session.annotateTool, .highlight)
        XCTAssertTrue(session.handleAnnotateKey(key("c", code: 8)))
        XCTAssertEqual(session.annotateTool, .comment)
        XCTAssertTrue(session.handleAnnotateKey(key("\u{1b}", code: 53)))
        XCTAssertEqual(session.annotateTool, .editText, "Esc returns to the default tool, Edit PDF text")
        XCTAssertFalse(session.handleAnnotateKey(key("\u{1b}", code: 53)), "nothing to cancel: Esc goes on")
        XCTAssertTrue(session.handleAnnotateKey(key("v", code: 9)))
        XCTAssertEqual(session.annotateTool, .select)
        XCTAssertTrue(session.handleAnnotateKey(key("e", code: 14)))
        XCTAssertEqual(session.annotateTool, .editText)
        XCTAssertTrue(session.handleAnnotateKey(key("t", code: 17)))
        XCTAssertEqual(session.annotateTool, .text)
        session.annotateTool = .select

        session.beginComment(onPageAt: 0, at: CGPoint(x: 50, y: 50))
        session.commentDraft?.text = "x"
        session.saveCommentDraft()
        XCTAssertNotNil(session.selectedAnnotationID)
        XCTAssertTrue(session.handleAnnotateKey(key("\u{7f}", code: 51)))
        XCTAssertTrue(session.comments.isEmpty)
        XCTAssertNil(session.selectedAnnotationID)
        await session.close()
    }

    func testAnnotationMenusAndLeavingAnnotate() async throws {
        let session = try await open()
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        await session.highlight(try XCTUnwrap(page.selection(for: CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2))))
        let highlight = try XCTUnwrap(session.annotations[session.pages[0].id]?.first)
        let menu = try XCTUnwrap(session.annotationMenu(for: highlight.id, language: .en))
        XCTAssertEqual(menu.items.map(\.title), ["Remove highlight", "Add comment"])

        (menu.items[1].target as? MenuAction)?.run()
        guard case let .highlight(info) = highlight.content else { return XCTFail("not a highlight") }
        XCTAssertEqual(session.commentDraft?.quote, info.text)
        XCTAssertEqual(session.commentDraft?.anchor.x, highlight.bounds.maxX + 2)

        session.annotateTool = .highlight
        session.selectedAnnotationID = highlight.id
        session.workspace = .read
        XCTAssertEqual(session.annotateTool, .editText)
        XCTAssertNil(session.selectedAnnotationID)
        XCTAssertNil(session.commentDraft)
        XCTAssertEqual(session.annotations[session.pages[0].id]?.count, 1, "annotations stay; only the tool state resets")
        await session.close()
    }
}
