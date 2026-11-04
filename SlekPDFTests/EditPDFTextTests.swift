import AppKit
import PDFKit
import XCTest
@testable import SlekPDF

/// Edit PDF text (Figma PDF Text Line 556:525): a click on a line of the PDF's own text opens it for typing with its
/// text; committing covers the original line and draws the new text; the source PDF never changes; saved work keeps
/// the edit editable.
@MainActor
final class EditPDFTextTests: XCTestCase {
    private func open(_ url: URL? = nil) async throws -> DocumentSession {
        FontRegistry.registerBundledFonts()
        let session = DocumentSession()
        await session.open(try url ?? XCTUnwrap(Bundle(for: EditPDFTextTests.self).url(forResource: "khmer-multipage", withExtension: "pdf")))
        XCTAssertNotNil(session.document)
        session.workspace = .annotate
        return session
    }

    private func edits(_ session: DocumentSession, page: Int = 0) -> [(PageAnnotation, TextEditInfo)] {
        (session.annotations[session.pages[page].id] ?? []).compactMap { annotation in
            if case let .textEdit(info) = annotation.content { (annotation, info) } else { nil }
        }
    }

    private func firstLine(_ session: DocumentSession) async throws -> EditableLine {
        let found = await session.editableLines(onPageAt: 0)
        let lines = try XCTUnwrap(found)
        return try XCTUnwrap(lines.first { $0.text.unicodeScalars.contains { (0x1780...0x17FF).contains($0.value) } })
    }

    func testEditPDFTextIsTheDefaultTool() async throws {
        let session = try await open()
        XCTAssertEqual(session.annotateTool, .editText)
        await session.close()
    }

    func testClickingALineOpensItWithItsTextAndCommittingReplacesItInOneUndo() async throws {
        let session = try await open()
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        let line = try await firstLine(session)
        let opened = await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.midX, y: line.box.midY))
        XCTAssertTrue(opened)
        let draft = try XCTUnwrap(session.textEditing)
        XCTAssertEqual(draft.text, line.text, "the editor opens with the line's own text")
        XCTAssertEqual(draft.line?.original, line.text)
        XCTAssertTrue(draft.bounds.contains(draft.line!.cover), "the editor covers the original line")
        XCTAssertLessThan(draft.bounds.height, line.box.height * 2.5, "not a 44 pt text box over neighbouring lines")

        let changed = "សេចក្តីជូនដំណឹងថ្មី"
        session.typeInTextBox(changed)
        undo.beginUndoGrouping()
        session.commitTextEditing()
        undo.endUndoGrouping()
        XCTAssertNil(session.textEditing)
        let (annotation, info) = try XCTUnwrap(edits(session).first)
        XCTAssertEqual(info.text, changed)
        XCTAssertEqual(info.original, line.text)
        XCTAssertTrue(annotation.bounds.contains(info.cover))
        XCTAssertTrue(session.hasUnsavedChanges)

        undo.undo()
        XCTAssertTrue(edits(session).isEmpty, "one undo puts the original back")
        await session.close()
    }

    func testAnUnchangedLineAddsNothingAndAnEmptiedLineIsKept() async throws {
        let session = try await open()
        let line = try await firstLine(session)
        let point = CGPoint(x: line.box.midX, y: line.box.midY)
        await session.beginEditingLine(onPageAt: 0, at: point)
        session.commitTextEditing()
        XCTAssertTrue(edits(session).isEmpty, "opening and closing a line changes nothing")

        await session.beginEditingLine(onPageAt: 0, at: point)
        session.typeInTextBox("")
        session.commitTextEditing()
        XCTAssertEqual(edits(session).first?.1.text, "", "deleting a line's text removes it from the page")

        // Clicking the edited line opens the edit again, not the original text.
        await session.beginEditingLine(onPageAt: 0, at: point)
        XCTAssertEqual(session.textEditing?.id, edits(session).first?.0.id)
        session.commitTextEditing()
        XCTAssertEqual(edits(session).count, 1)
        await session.close()
    }

    func testAnEmptiedLineLeavesThePageColourWhereTheTextWas() async throws {
        let session = try await open()
        let line = try await firstLine(session)
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let before = try darkPixels(page, in: line.box)
        XCTAssertGreaterThan(before, 50, "the line has ink")
        await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.midX, y: line.box.midY))
        session.typeInTextBox("")
        session.commitTextEditing()
        XCTAssertEqual(try darkPixels(page, in: line.box.insetBy(dx: 1, dy: 1)), 0, "the original line is covered")
        await session.close()
    }

    func testSavedWorkKeepsTheEditEditableAndTheSourceUnchanged() async throws {
        let source = try XCTUnwrap(Bundle(for: EditPDFTextTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let sourceBytes = try Data(contentsOf: source)
        let session = try await open(source)
        let line = try await firstLine(session)
        await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.midX, y: line.box.midY))
        session.typeInTextBox("ឯកសារដែលបានកែ")
        session.commitTextEditing()
        let saved = try XCTUnwrap(edits(session).first)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edited-\(UUID()).pdf")
        try await session.saveWork(to: url)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes, "the source PDF is never changed")
        await session.close()

        let reopened = try await open(url)
        let restored = edits(reopened)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.1, saved.1, "text, original, style, cover and baseline come back")
        // Annotation rectangles are stored as 32-bit floats.
        let bounds = try XCTUnwrap(restored.first?.0.bounds)
        for (a, b) in [(bounds.minX, saved.0.bounds.minX), (bounds.minY, saved.0.bounds.minY), (bounds.width, saved.0.bounds.width), (bounds.height, saved.0.bounds.height)] {
            XCTAssertEqual(a, b, accuracy: 0.01)
        }
        let page = try XCTUnwrap(reopened.document?.page(at: 0))
        XCTAssertEqual(page.annotations.count, 1, "drawn once: PDFKit's copy of the saved annotation was taken off")
        await reopened.close()
    }

    func testAScanNeedsOCRFirstThenItsLinesAreEditable() async throws {
        // One blank page: no text layer.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID()).pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let session = try await open(url)
        let point = CGPoint(x: 120, y: 200)
        let opened = await session.beginEditingLine(onPageAt: 0, at: point, language: .en)
        XCTAssertFalse(opened)
        XCTAssertEqual(session.toasts.current?.message, "Click a line of text on the page to edit it. Scanned pages need Khmer OCR first.")

        let ocrLine = OCRLine(bounds: CGRect(x: 100, y: 190, width: 160, height: 24), text: "ព្រះរាជាណាចក្រកម្ពុជា", confidence: 95)
        session.setOCR(OCRPage(lines: [ocrLine], languages: "khm", date: Date()), for: session.pages[0].id)
        let openedAfterOCR = await session.beginEditingLine(onPageAt: 0, at: point)
        XCTAssertTrue(openedAfterOCR)
        XCTAssertEqual(session.textEditing?.text, "ព្រះរាជាណាចក្រកម្ពុជា")
        session.commitTextEditing()
        await session.close()
    }

    func testAnEditKeepsTheLinesColourAndItsFontWhenThisMacHasIt() async throws {
        // A line of grey Helvetica.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grey-\(UUID()).pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let grey = CGColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)
        let text = NSAttributedString(string: "Phnom Penh, Cambodia", attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
                                                                                  .foregroundColor: grey])
        context.textPosition = CGPoint(x: 40, y: 120)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
        let session = try await open(url)
        let line = try await firstLatinLine(session)
        await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.midX, y: line.box.midY))
        let style = try XCTUnwrap(session.textEditing?.style)
        XCTAssertEqual(style.font, "Helvetica")
        for (channel, expected) in zip(style.color, [0.4, 0.4, 0.4]) { XCTAssertEqual(channel, expected, accuracy: 0.02) }
        XCTAssertEqual(style.fontSize, 14, accuracy: 1.5, "sized like the original")
        session.commitTextEditing()
        await session.close()
    }

    func testOnlyInstalledFontsThatCanWriteTheTextAreUsed() {
        XCTAssertEqual(DocumentSession.installedFont("Helvetica", for: "Phnom Penh"), "Helvetica")
        XCTAssertNil(DocumentSession.installedFont("NotAFontOnThisMac-Regular", for: "Phnom Penh"), "missing → bundled font")
        XCTAssertNil(DocumentSession.installedFont("Helvetica", for: "ភ្នំពេញ"), "no Khmer letters → bundled Noto Sans Khmer")
        XCTAssertNil(DocumentSession.installedFont(nil, for: "x"))
    }

    private func firstLatinLine(_ session: DocumentSession) async throws -> EditableLine {
        let found = await session.editableLines(onPageAt: 0)
        return try XCTUnwrap(found?.first)
    }

    /// An edited line of a real PDF (tmp/RealDocuments/cv.pdf, never committed): tmp/edit-real.png, top = before.
    func testRenderAnEditOnARealPDF() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RealDocuments/cv.pdf")
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Set SNAPSHOT_DIR and copy a PDF to tmp/RealDocuments/cv.pdf")
        }
        let session = try await open(url)
        let found = await session.editableLines(onPageAt: 0)
        let lines = try XCTUnwrap(found)
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let area = CGRect(x: 20, y: page.bounds(for: .mediaBox).maxY - 140, width: 420, height: 130)
        func picture() -> NSImage {
            let image = NSImage(size: NSSize(width: area.width * 3, height: area.height * 3))
            image.lockFocus()
            let context = NSGraphicsContext.current!.cgContext
            context.setFillColor(.white)
            context.fill(CGRect(origin: .zero, size: image.size))
            context.scaleBy(x: 3, y: 3)
            context.translateBy(x: -area.minX, y: -area.minY)
            page.draw(with: .mediaBox, to: context)
            image.unlockFocus()
            return image
        }
        let before = picture()
        var report = ""
        let pdf = try PDFiumDocument(url: url)
        let chars = try pdf.characters(onPage: 0)
        for char in chars.prefix(40) where !char.isGenerated {
            let style = try pdf.textStyle(onPage: 0, charIndex: char.index)
            report += "\(char.index) \(String(char.scalar)) \(style.font ?? "-") \(style.color ?? [])\n"
        }
        for line in lines.filter({ area.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }).prefix(4) {
            await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.midX, y: line.box.midY))
            let style = session.textEditing?.style
            report += "\(line.text) | pdf font \(line.font ?? "-") → \(style?.fontName ?? "-") | colour \(style?.color ?? []) | size \(style?.fontSize ?? 0) | pdfium size \(line.fontSize) | box \(line.box) | our width \(style.map { KhmerGlyphOutlines.lineWidth(text: line.text, style: $0) } ?? 0)\n"
            session.typeInTextBox(line.text + "!")
            session.commitTextEditing()
        }
        session.selectedAnnotationID = nil
        let after = picture()
        let both = NSImage(size: NSSize(width: before.size.width, height: before.size.height * 2 + 10))
        both.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: both.size).fill()
        after.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        before.draw(at: NSPoint(x: 0, y: before.size.height + 10), from: .zero, operation: .copy, fraction: 1)
        both.unlockFocus()
        let png = NSBitmapImageRep(data: both.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("edit-real.png"))
        try report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("edit-real.txt"), atomically: true, encoding: .utf8)
        await session.close()
    }

    /// While typing, the editor's text starts at the line's start, sits on the original baseline and fits in the box
    /// (the caret and the text spilled out of it, and the text could drift away from the line's start).
    func testTheEditorSitsOnTheOriginalBaselineAndFitsItsText() async throws {
        let session = try await open()
        let line = try await firstLine(session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = KhmerPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 900))
        window.contentView = view
        view.document = session.document
        view.session = session
        let page = try XCTUnwrap(session.document?.page(at: 0))
        for scale: CGFloat in [1, 2.5] {
            view.autoScales = false
            view.scaleFactor = scale
            view.go(to: line.box.insetBy(dx: -10, dy: -40), on: page)
            view.layoutDocumentView()
            await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.midX, y: line.box.midY))
            view.syncTextEditor()
            let editor = try XCTUnwrap(view.subviews.compactMap { $0 as? TextBoxEditor }.first)
            let layout = try XCTUnwrap(editor.layoutManager)
            layout.ensureLayout(for: editor.textContainer!)
            let used = layout.usedRect(for: editor.textContainer!)
            XCTAssertEqual(layout.location(forGlyphAt: 0).x, 0, accuracy: 0.5, "text starts at the line's start (scale \(scale))")
            XCTAssertLessThanOrEqual(used.maxY, editor.bounds.height + 0.5, "the text and caret fit in the box (scale \(scale))")
            let fragment = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let baselineInView = view.isFlipped ? editor.frame.minY + fragment.minY + layout.location(forGlyphAt: 0).y
                : editor.frame.maxY - fragment.minY - layout.location(forGlyphAt: 0).y
            let expected = view.convert(CGPoint(x: 0, y: try XCTUnwrap(session.textEditing?.line?.baseline)), from: page).y
            XCTAssertEqual(baselineInView, expected, accuracy: 1.5, "on the original baseline (scale \(scale))")
            session.commitTextEditing()
            view.syncTextEditor()
        }
        window.orderOut(nil)
        await session.close()
    }

    /// A visible window after an edit, for capturing with `screencapture -l` (tmp/live-window.txt holds the window
    /// number). Runs only with LIVE_CAPTURE and tmp/RealDocuments/cv.pdf.
    func testLiveWindowAfterAnEdit() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RealDocuments/cv.pdf")
        guard ProcessInfo.processInfo.environment["LIVE_CAPTURE"] != nil, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Set LIVE_CAPTURE and copy a PDF to tmp/RealDocuments/cv.pdf")
        }
        let session = try await open(url)
        let found = await session.editableLines(onPageAt: 0)
        let line = try XCTUnwrap(found?.first)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = KhmerPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        window.contentView = view
        view.document = session.document
        view.session = session
        session.pdfView = view
        view.autoScales = false
        view.scaleFactor = 2
        let page = try XCTUnwrap(session.document?.page(at: 0))
        view.go(to: line.box.insetBy(dx: -10, dy: -60), on: page)
        window.makeKeyAndOrderFront(nil)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("live-window.txt")
        try await Task.sleep(for: .seconds(4))
        let clip = try XCTUnwrap(view.documentView?.enclosingScrollView?.contentView)
        func pageFrame() -> String { "\(view.documentView!.frame) page \(view.documentView!.subviews.first?.frame ?? .zero) convert \(view.convert(CGPoint(x: 0, y: 800), from: page))" }
        var origins = "start \(clip.bounds.origin) \(pageFrame())\n"
        try "before \(window.windowNumber)".write(to: marker, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(4))
        origins += "pre-edit \(clip.bounds.origin) \(pageFrame())\n"
        await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.maxX - 2, y: line.box.midY))
        view.syncTextEditor()
        session.typeInTextBox("EDITED NAME")
        session.commitTextEditing()
        view.syncTextEditor()
        try await Task.sleep(for: .seconds(4))
        origins += "after \(clip.bounds.origin) \(pageFrame())\n"
        try origins.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("origins.txt"), atomically: true, encoding: .utf8)
        try "after \(window.windowNumber)".write(to: marker, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(6))
        window.orderOut(nil)
        await session.close()
    }

    /// The on-page editor over a real PDF's title while typing (tmp/edit-editor.png and .txt). Snapshot runs only.
    func testRenderTheEditorOnARealPDF() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RealDocuments/cv.pdf")
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Set SNAPSHOT_DIR and copy a PDF to tmp/RealDocuments/cv.pdf")
        }
        let session = try await open(url)
        let found = await session.editableLines(onPageAt: 0)
        let line = try XCTUnwrap(found?.first)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = KhmerPDFView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = view
        view.document = session.document
        view.session = session
        view.autoScales = false
        view.scaleFactor = 2
        let page = try XCTUnwrap(session.document?.page(at: 0))
        view.go(to: line.box.insetBy(dx: -10, dy: -40), on: page)
        view.layoutDocumentView()
        await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.maxX - 2, y: line.box.midY))
        view.syncTextEditor()
        let first = try XCTUnwrap(view.subviews.compactMap { $0 as? TextBoxEditor }.first)
        first.setSelectedRange(NSRange(location: 7, length: (first.string as NSString).length - 7))
        first.insertText("", replacementRange: first.selectedRange())
        // Finish, then click the edited line again (the user's flow).
        session.commitTextEditing()
        view.syncTextEditor()
        await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.minX + 20, y: line.box.midY))
        view.syncTextEditor()
        let editor2 = try XCTUnwrap(view.subviews.compactMap { $0 as? TextBoxEditor }.first)
        editor2.layoutManager!.ensureLayout(for: editor2.textContainer!)
        let again = "second: frame \(editor2.frame) glyph0 \(editor2.layoutManager!.location(forGlyphAt: 0)) used \(editor2.layoutManager!.usedRect(for: editor2.textContainer!)) draft \(session.textEditing!.bounds) align \(session.textEditing!.style.alignment)"
        let editor = editor2
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
        let glyph0 = editor.layoutManager!.location(forGlyphAt: 0)
        let used = editor.layoutManager!.usedRect(for: editor.textContainer!)
        let fragment = editor.layoutManager!.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let paragraph = editor.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let report = """
        text \(editor.string) frame \(editor.frame) bounds \(editor.bounds) inset \(editor.textContainerInset)
        container \(editor.textContainer!.size) glyph0 \(glyph0) used \(used) fragment \(fragment)
        alignment \(paragraph?.alignment.rawValue ?? -1) textView.alignment \(editor.alignment.rawValue) font \(editor.font?.fontName ?? "-") \(editor.font?.pointSize ?? 0)
        line box \(line.box) draft bounds \(session.textEditing!.bounds) style \(session.textEditing!.style)
        \(again)
        """
        try report.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("edit-editor.txt"), atomically: true, encoding: .utf8)
        let rep = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("edit-editor.png"))
        session.commitTextEditing()
        window.orderOut(nil)
        await session.close()
    }

    /// Before/after picture of an edited line (tmp/edit-pdf-text.png), for checking placement by eye. Snapshot runs only.
    func testRenderAnEditedLine() async throws {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil else { throw XCTSkip("Set SNAPSHOT_DIR to write snapshots") }
        let session = try await open()
        let line = try await firstLine(session)
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let area = line.box.insetBy(dx: -20, dy: -30)
        func picture() -> NSImage {
            let image = NSImage(size: NSSize(width: area.width * 3, height: area.height * 3))
            image.lockFocus()
            let context = NSGraphicsContext.current!.cgContext
            context.setFillColor(.white)
            context.fill(CGRect(origin: .zero, size: image.size))
            context.scaleBy(x: 3, y: 3)
            context.translateBy(x: -area.minX, y: -area.minY)
            page.draw(with: .mediaBox, to: context)
            image.unlockFocus()
            return image
        }
        let before = picture()
        await session.beginEditingLine(onPageAt: 0, at: CGPoint(x: line.box.midX, y: line.box.midY))
        session.typeInTextBox(line.text + " ថ្មី")
        session.commitTextEditing()
        session.selectedAnnotationID = nil
        let after = picture()
        let both = NSImage(size: NSSize(width: before.size.width, height: before.size.height * 2 + 10))
        both.lockFocus()
        NSColor.systemGray.setFill()
        NSRect(origin: .zero, size: both.size).fill()
        after.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        before.draw(at: NSPoint(x: 0, y: before.size.height + 10), from: .zero, operation: .copy, fraction: 1)
        both.unlockFocus()
        let png = NSBitmapImageRep(data: both.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("edit-pdf-text.png"))
        await session.close()
    }

    /// Pixels darker than mid-grey inside `rect` when the page is drawn as on screen.
    private func darkPixels(_ page: PDFPage, in rect: CGRect) throws -> Int {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width), height = Int(bounds.height)
        var pixels = [UInt8](repeating: 255, count: width * height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
        }
        var count = 0
        for y in Int(rect.minY - bounds.minY)..<Int(rect.maxY - bounds.minY) where y >= 0 && y < height {
            for x in Int(rect.minX - bounds.minX)..<Int(rect.maxX - bounds.minX) where x >= 0 && x < width {
                // Memory rows run top-down.
                if pixels[(height - 1 - y) * width + x] < 128 { count += 1 }
            }
        }
        return count
    }
}
