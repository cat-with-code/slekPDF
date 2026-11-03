import PDFKit
import XCTest
@testable import SlekPDF

/// Annotate step 1: the annotation model follows its page, undoes, counts as unsaved, saves into editable work,
/// comes back on reopen without duplicates, and obeys the print options.
@MainActor
final class AnnotationModelTests: XCTestCase {
    private let khmer = "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"

    private func open(_ url: URL) async throws -> DocumentSession {
        let session = DocumentSession()
        await session.open(url)
        XCTAssertNotNil(session.document, "could not open \(url.lastPathComponent)")
        return session
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle(for: AnnotationModelTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
    }

    private func samples(on session: DocumentSession) -> [PageAnnotation] {
        let page = session.document!.page(at: 0)!.bounds(for: .mediaBox)
        let box = CGRect(x: page.minX + 40, y: page.minY + 40, width: 300, height: 60)
        return [
            PageAnnotation(bounds: box, content: .textBox(text: khmer, style: TextBoxStyle(fontSize: 16, italic: true, underline: true))),
            PageAnnotation(bounds: box, content: .highlight(HighlightInfo(lines: [box.insetBy(dx: 0, dy: 20)], text: "ពិនិត្យ"))),
            PageAnnotation(bounds: CGRect(x: box.minX, y: box.maxY, width: 20, height: 20),
                           content: .comment(CommentInfo(text: "សូមពិនិត្យម្ដងទៀត", author: "Dara", date: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                                         quote: "ពិនិត្យ", replies: [.init(author: "Sokha", text: "បាទ", date: Date(timeIntervalSinceReferenceDate: 800_000_100))]))),
        ]
    }

    private func slekAnnotations(_ page: PDFPage?) -> [SlekPDFAnnotation] { page?.annotations.compactMap { $0 as? SlekPDFAnnotation } ?? [] }

    func testAddingMarksUnsavedShowsOnThePageAndUndoes() async throws {
        let session = try await open(fixture())
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        let note = samples(on: session)[0]

        undo.beginUndoGrouping(); session.addAnnotation(note, toPageAt: 1); undo.endUndoGrouping()
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(slekAnnotations(session.document?.page(at: 1)).map(\.model), [note])
        XCTAssertTrue(slekAnnotations(session.document?.page(at: 0)).isEmpty)

        var moved = note
        moved.bounds.origin.x += 10
        undo.beginUndoGrouping(); session.updateAnnotation(moved); undo.endUndoGrouping()
        XCTAssertEqual(slekAnnotations(session.document?.page(at: 1)).map(\.model), [moved])

        undo.undo()
        XCTAssertEqual(slekAnnotations(session.document?.page(at: 1)).map(\.model), [note])
        undo.undo()
        XCTAssertTrue(slekAnnotations(session.document?.page(at: 1)).isEmpty)
        XCTAssertFalse(session.hasUnsavedChanges)
        await session.close()
    }

    func testAnnotationsFollowTheirPageThroughReorderRotateAndDelete() async throws {
        let session = try await open(fixture())
        let note = samples(on: session)[0]
        session.addAnnotation(note, toPageAt: 2)
        let ids = session.pages.map(\.id)

        session.movePages([ids[2]], to: 0)
        session.selectedPageIDs = [ids[2]]
        session.rotateSelectedPages()
        XCTAssertEqual(slekAnnotations(session.document?.page(at: 0)).map(\.model), [note])

        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        undo.beginUndoGrouping(); session.deleteSelectedPages(); undo.endUndoGrouping()
        XCTAssertTrue((0..<session.pageCount).allSatisfy { slekAnnotations(session.document?.page(at: $0)).isEmpty })
        undo.undo()
        XCTAssertEqual(slekAnnotations(session.document?.page(at: 0)).map(\.model), [note])
        await session.close()
    }

    func testSavedWorkReopensWithTheSameAnnotationsAndResavesWithoutDuplicates() async throws {
        let sourceURL = try fixture()
        let sourceBytes = try Data(contentsOf: sourceURL)
        let session = try await open(sourceURL)
        let added = samples(on: session)
        for (index, annotation) in added.enumerated() { session.addAnnotation(annotation, toPageAt: index) }
        let ids = session.pages.map(\.id)
        session.movePages([ids[2]], to: 0)  // pages now: source 2, 0, 1 → comment, text box, highlight
        session.selectedPageIDs = [ids[2]]
        session.rotateSelectedPages()

        let first = FileManager.default.temporaryDirectory.appendingPathComponent("annotated-\(UUID()).pdf")
        try await session.saveWork(to: first)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes, "the source file changed")
        await session.close()

        let reopened = try await open(first)
        let expected = [added[2], added[0], added[1]]
        XCTAssertFalse(reopened.hasUnsavedChanges)
        XCTAssertEqual(reopened.document?.page(at: 0)?.rotation, 90)
        for (index, annotation) in expected.enumerated() {
            let stored = reopened.annotations[reopened.pages[index].id] ?? []
            XCTAssertEqual(stored.count, 1, "page \(index)")
            XCTAssertTrue(stored.first?.sameContent(as: annotation) == true, "page \(index): \(String(describing: stored.first))")
            // Drawn once, by Slek: the saved copy PDFKit loaded from the file was taken off the page.
            let page = reopened.document?.page(at: index)
            XCTAssertEqual(page?.annotations.count, 1, "page \(index): \(String(describing: page?.annotations))")
            XCTAssertEqual(slekAnnotations(page).count, 1)
        }

        // Resaving the reopened work keeps one of each.
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("annotated-\(UUID()).pdf")
        try await reopened.saveWork(to: second)
        await reopened.close()
        let again = try PDFiumDocument(url: second)
        XCTAssertEqual(try (0..<3).map { try again.slekAnnotations(page: $0).count }, [1, 1, 1])
        // Other PDF readers see standard annotations with the Unicode text.
        let kit = try XCTUnwrap(PDFDocument(url: second))
        XCTAssertEqual(kit.page(at: 1)?.annotations.first?.type, "FreeText")
        XCTAssertEqual(kit.page(at: 1)?.annotations.first?.contents, khmer)
        XCTAssertEqual(kit.page(at: 2)?.annotations.first?.type, "Highlight")
        XCTAssertEqual(kit.page(at: 0)?.annotations.first?.type, "Text")
    }

    /// Slek's annotations are drawn by the page (sharp at every zoom) exactly where they were drawn as PDFKit
    /// annotations, also on a rotated page.
    func testThePageDrawsSlekAnnotationsWhereTheyBelong() async throws {
        FontRegistry.registerBundledFonts()
        let session = try await open(fixture())
        XCTAssertTrue(session.document?.page(at: 0) is SlekPDFPage)
        for (index, sample) in samples(on: session).enumerated() { session.addAnnotation(sample, toPageAt: index) }
        session.selectedPageIDs = [session.pages[1].id]
        session.rotateSelectedPages()
        defer { SlekPDFAnnotation.drawsItself = false }
        for index in 0..<2 {
            let page = try XCTUnwrap(session.document?.page(at: index))
            SlekPDFAnnotation.drawsItself = true
            let old = try render(page)
            SlekPDFAnnotation.drawsItself = false
            let new = try render(page)
            let differing = zip(old, new).filter { abs(Int($0) - Int($1)) > 24 }.count
            XCTAssertLessThan(differing, old.count / 2000, "page \(index) (rotation \(page.rotation))")
            XCTAssertNotEqual(new, try render(page, withoutSlek: true), "page \(index): nothing drawn")
        }
        await session.close()
    }

    private func render(_ page: PDFPage, withoutSlek: Bool = false) throws -> [UInt8] {
        let side = 900
        var pixels = [UInt8](repeating: 255, count: side * side)
        let hidden = withoutSlek ? page.annotations.filter { $0 is SlekPDFAnnotation } : []
        hidden.forEach { $0.shouldDisplay = false }
        defer { hidden.forEach { $0.shouldDisplay = true } }
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            page.draw(with: .mediaBox, to: context)
        }
        return pixels
    }

    func testTextBoxIsDrawnOnThePageInsideItsBounds() async throws {
        FontRegistry.registerBundledFonts()
        let session = try await open(fixture())
        let page = try XCTUnwrap(session.document?.page(at: 0))
        let before = try ink(page)
        let note = samples(on: session)[0]
        session.addAnnotation(note, toPageAt: 0)
        let after = try ink(page)
        let bounds = page.bounds(for: .mediaBox)
        let changed = before.indices.filter { before[$0] != after[$0] }
        let inside = changed.filter { index in
            let point = CGPoint(x: bounds.minX + CGFloat(index % Int(bounds.width)) + 0.5, y: bounds.minY + CGFloat(index / Int(bounds.width)) + 0.5)
            return note.bounds.insetBy(dx: -2, dy: -2).contains(point)
        }
        XCTAssertGreaterThan(changed.count, 300, "the text box drew nothing")
        XCTAssertEqual(inside.count, changed.count, "drawing outside the box")
        await session.close()
    }

    func testPrintOptionsFilterSlekAnnotations() async throws {
        let session = try await open(fixture())
        let drawn = samples(on: session).map { SlekPDFAnnotation($0) }
        let options = PrintOptions()
        XCTAssertEqual(drawn.map(options.prints), [true, true, false])
        options.addedText = false
        options.highlights = false
        XCTAssertEqual(drawn.map(options.prints), [false, false, false])
        options.addedText = true
        options.content = .documentOnly
        XCTAssertEqual(drawn.map(options.prints), [false, false, false])
        await session.close()
    }

    /// Grey pixels of `page` at 1 pt per pixel (row 0 = bottom of the media box).
    private func ink(_ page: PDFPage) throws -> [UInt8] {
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
        // CGContext memory rows run top-down; flip so row 0 is the bottom.
        return (0..<height).reversed().flatMap { row in pixels[(row * width)..<((row + 1) * width)] }
    }
}
