import AppKit
import PDFKit
import XCTest
@testable import SlekPDF

/// Annotate step 3 (Figma Added Text Box 125:23, Text Properties 123:292): typing, committing, styling, moving,
/// keys, the on-page editor, and saving while typing.
@MainActor
final class TextBoxTests: XCTestCase {
    private let khmer = "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"

    private func open() async throws -> (DocumentSession, UndoManager) {
        FontRegistry.registerBundledFonts()
        let url = try XCTUnwrap(Bundle(for: TextBoxTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        session.workspace = .annotate
        return (session, UndoManager())
    }

    /// Undo recording starts here (changes made before it are setup, outside any undo group).
    private func record(_ undo: UndoManager, in session: DocumentSession) {
        undo.groupsByEvent = false
        session.undoManager = undo
    }

    private func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func textBoxes(_ session: DocumentSession, page: Int = 0) -> [PageAnnotation] {
        (session.annotations[session.pages[page].id] ?? []).filter { if case .textBox = $0.content { true } else { false } }
    }

    func testOneLineBoxMatchesFigmaAndGrowsWithItsText() {
        FontRegistry.registerBundledFonts()
        let style = TextBoxStyle()
        XCTAssertEqual(KhmerGlyphOutlines.fittedHeight(text: khmer, width: 240, style: style), TextBoxStyle.minimumHeight)
        let three = KhmerGlyphOutlines.fittedHeight(text: "\(khmer)\nក\nខ", width: 240, style: style)
        XCTAssertEqual(three, ceil(3 * 14 * 1.6 + 20), accuracy: 1)
    }

    func testTypingAndCommittingANewBoxIsOneUndoableStep() async throws {
        let (session, undo) = try await open()
        record(undo, in: session)
        session.annotateTool = .text
        session.beginTextBox(onPageAt: 0, at: CGPoint(x: 72, y: 500))
        XCTAssertEqual(session.textEditing?.bounds, CGRect(x: 72, y: 456, width: 240, height: 44))
        XCTAssertNotNil(session.textBoxTarget, "Text Properties edits the box being typed in")
        session.typeInTextBox(khmer)
        session.typeInTextBox("\(khmer)\nបន្ទាត់ទីពីរ")
        XCTAssertGreaterThan(session.textEditing?.bounds.height ?? 0, 44, "grows with the text")
        XCTAssertEqual(session.textEditing?.bounds.maxY, 500, "keeps its top edge")
        XCTAssertTrue(session.hasUnsavedChanges)

        undo.beginUndoGrouping(); session.commitTextEditing(); undo.endUndoGrouping()
        let box = try XCTUnwrap(textBoxes(session).first)
        guard case let .textBox(text, _) = box.content else { return XCTFail("not a text box") }
        XCTAssertEqual(text, "\(khmer)\nបន្ទាត់ទីពីរ")
        XCTAssertEqual(session.selectedAnnotationID, box.id)
        XCTAssertEqual(session.annotateTool, .editText)
        XCTAssertNil(session.textEditing)
        XCTAssertTrue(try XCTUnwrap(session.document?.page(at: 0)?.annotations.compactMap { $0 as? SlekPDFAnnotation }.first).isSelected)

        undo.undo()
        XCTAssertTrue(textBoxes(session).isEmpty)
        XCTAssertFalse(session.hasUnsavedChanges)
        await session.close()
    }

    func testEmptyBoxesAreNotKeptAndClearingABoxRemovesIt() async throws {
        let (session, _) = try await open()
        session.beginTextBox(onPageAt: 0, at: CGPoint(x: 72, y: 500))
        session.typeInTextBox("   ")
        session.commitTextEditing()
        XCTAssertTrue(textBoxes(session).isEmpty)

        session.beginTextBox(onPageAt: 0, at: CGPoint(x: 72, y: 500))
        session.typeInTextBox(khmer)
        session.commitTextEditing()
        let id = try XCTUnwrap(textBoxes(session).first?.id)
        session.beginEditingTextBox(id)
        XCTAssertEqual(session.textEditing?.text, khmer)
        XCTAssertTrue(session.document?.page(at: 0)?.annotations.isEmpty == true, "the page hides the box while the editor shows it")
        session.typeInTextBox("")
        session.commitTextEditing()
        XCTAssertTrue(textBoxes(session).isEmpty)
        await session.close()
    }

    func testTextPropertiesChangeTheSelectedBoxAndUndo() async throws {
        let (session, undo) = try await open()
        session.beginTextBox(onPageAt: 0, at: CGPoint(x: 72, y: 500))
        session.typeInTextBox(khmer)
        session.commitTextEditing()
        record(undo, in: session)

        undo.beginUndoGrouping(); session.changeTextBoxStyle { $0.bold = true; $0.color = TextBoxStyle.Swatch.red.rgb }; undo.endUndoGrouping()
        undo.beginUndoGrouping(); session.changeTextBoxStyle { $0.fontSize = 28 }; undo.endUndoGrouping()
        var style = try XCTUnwrap(session.textBoxTarget?.style)
        XCTAssertTrue(style.bold)
        XCTAssertEqual(style.swatch, .red)
        XCTAssertEqual(style.fontSize, 28)
        XCTAssertGreaterThan(session.textBoxTarget?.bounds.height ?? 0, 44, "bigger text refits the box")

        undo.undo()
        style = try XCTUnwrap(session.textBoxTarget?.style)
        XCTAssertEqual(style.fontSize, 14)
        XCTAssertEqual(session.textBoxTarget?.bounds.height, 44)
        undo.undo()
        XCTAssertEqual(session.textBoxTarget?.style, TextBoxStyle())

        session.selectedAnnotationID = nil
        XCTAssertNil(session.textBoxTarget, "nothing selected: Text Properties is disabled")
        await session.close()
    }

    func testPositionIsFromThePagesTopLeftAndADragIsOneUndo() async throws {
        let (session, undo) = try await open()
        let box = try XCTUnwrap(session.document?.page(at: 0)?.bounds(for: .mediaBox))
        session.beginTextBox(onPageAt: 0, at: CGPoint(x: box.minX + 72, y: box.maxY - 340))
        session.typeInTextBox(khmer)
        session.commitTextEditing()
        XCTAssertEqual(session.textBoxPosition(), CGPoint(x: 72, y: 340))
        record(undo, in: session)

        undo.beginUndoGrouping(); session.setTextBoxPosition(x: 100); undo.endUndoGrouping()
        XCTAssertEqual(session.textBoxPosition(), CGPoint(x: 100, y: 340))

        let original = try XCTUnwrap(session.selectedTextBox)
        for step in 1...5 { session.setTextBoxBounds(original.bounds.offsetBy(dx: CGFloat(step * 10), dy: 0), undoable: false) }
        undo.beginUndoGrouping(); session.finishTextBoxDrag(from: original); undo.endUndoGrouping()
        XCTAssertEqual(session.textBoxPosition(), CGPoint(x: 150, y: 340))
        undo.undo()
        XCTAssertEqual(session.textBoxPosition(), CGPoint(x: 100, y: 340), "one undo for the whole drag")
        await session.close()
    }

    func testKeysForTextBoxes() async throws {
        let (session, _) = try await open()
        XCTAssertTrue(session.handleAnnotateKey(key("t", code: 17)))
        XCTAssertEqual(session.annotateTool, .text)
        session.beginTextBox(onPageAt: 0, at: CGPoint(x: 72, y: 500))
        session.typeInTextBox(khmer)
        XCTAssertTrue(session.handleAnnotateKey(key("\u{1b}", code: 53)), "Esc ends typing")
        let id = try XCTUnwrap(session.selectedAnnotationID)
        let start = try XCTUnwrap(session.selectedTextBox?.bounds)
        XCTAssertTrue(session.handleAnnotateKey(key("\u{f703}", code: 124)))
        XCTAssertTrue(session.handleAnnotateKey(key("\u{f700}", code: 126, flags: .shift)))
        XCTAssertEqual(session.selectedTextBox?.bounds.origin, CGPoint(x: start.minX + 1, y: start.minY + 10))
        XCTAssertTrue(session.handleAnnotateKey(key("\r", code: 36)))
        XCTAssertEqual(session.textEditing?.id, id)
        session.commitTextEditing()
        XCTAssertTrue(session.handleAnnotateKey(key("\u{7f}", code: 51)))
        XCTAssertTrue(textBoxes(session).isEmpty)
        await session.close()
    }

    func testSavingWhileTypingKeepsTheText() async throws {
        let (session, _) = try await open()
        session.beginTextBox(onPageAt: 1, at: CGPoint(x: 72, y: 500))
        session.typeInTextBox(khmer)
        session.changeTextBoxStyle { $0.italic = true; $0.alignment = .center }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("textbox-\(UUID()).pdf")
        try await session.saveWork(to: output)
        XCTAssertNil(session.textEditing)
        XCTAssertFalse(session.hasUnsavedChanges)
        await session.close()

        let stored = try PDFiumDocument(url: output).slekAnnotations(page: 1)
        guard case let .textBox(text, style) = stored.first?.content else { return XCTFail("no text box") }
        XCTAssertEqual(text, khmer)
        XCTAssertTrue(style.italic)
        XCTAssertEqual(style.alignment, .center)
    }

    /// A click (no drag) on an added box opens it for typing; before, a click only selected it and typing went nowhere.
    func testClickingAnAddedBoxStartsTyping() async throws {
        let (session, _) = try await open()
        session.beginTextBox(onPageAt: 0, at: CGPoint(x: 72, y: 500))
        session.typeInTextBox(khmer)
        session.commitTextEditing()
        let box = try XCTUnwrap(textBoxes(session).first)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = KhmerPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        window.contentView = view
        view.document = session.document
        view.session = session
        view.layoutDocumentView()
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let center = view.convert(view.convert(CGPoint(x: box.bounds.midX, y: box.bounds.midY), from: page), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        view.mouseDown(with: mouse(.leftMouseDown))
        XCTAssertEqual(session.textEditing?.id, box.id)
        XCTAssertEqual(session.textEditing?.text, khmer)
        XCTAssertEqual(textBoxes(session).first?.bounds, box.bounds, "a click does not move the box")
        session.commitTextEditing()
        window.orderOut(nil)  // not close(): the test host quits when its last window closes
        await session.close()
    }

    func testOnPageEditorFollowsTheDraftAndTypingReachesTheSession() async throws {
        let (session, _) = try await open()
        let view = KhmerPDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000))
        view.document = session.document
        view.session = session
        session.beginTextBox(onPageAt: 0, at: CGPoint(x: 72, y: 500))
        view.syncTextEditor()
        let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? TextBoxEditor }.first)
        let page = try XCTUnwrap(session.document?.page(at: 0))
        XCTAssertEqual(editor.frame, view.convert(try XCTUnwrap(session.textEditing?.bounds), from: page).integral)
        XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.fontName, "NotoSansKhmer-Regular")
        XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.pointSize ?? 0, 14 * view.scaleFactor, accuracy: 0.01)

        editor.insertText(khmer, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(session.textEditing?.text, khmer)
        session.changeTextBoxStyle { $0.bold = true }
        view.syncTextEditor()
        XCTAssertEqual((editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName, "NotoSansKhmer-Bold")

        editor.cancelOperation(nil)  // Esc
        view.syncTextEditor()
        XCTAssertNil(session.textEditing)
        XCTAssertTrue(view.subviews.compactMap { $0 as? TextBoxEditor }.isEmpty)
        XCTAssertEqual(textBoxes(session).count, 1)
        await session.close()
    }
}
