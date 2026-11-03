import PDFKit
import XCTest
@testable import SlekPDF

/// Print Sheet (Figma 188:179) Slek PDF section: which existing annotations print.
@MainActor
final class PrintOptionsTests: XCTestCase {
    private func annotation(_ subtype: PDFAnnotationSubtype) -> PDFAnnotation {
        PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: subtype, withProperties: nil)
    }

    func testDefaultPrintsDocumentAndAnnotations() {
        let options = PrintOptions()
        XCTAssertTrue(options.prints(annotation(.freeText)))
        XCTAssertTrue(options.prints(annotation(.highlight)))
        XCTAssertTrue(options.prints(annotation(.text)))
        XCTAssertFalse(options.commentsSummary)
    }

    func testIncludeOptionsAndDocumentOnly() {
        let options = PrintOptions()
        options.addedText = false
        XCTAssertFalse(options.prints(annotation(.freeText)))
        XCTAssertTrue(options.prints(annotation(.highlight)))
        options.highlights = false
        XCTAssertFalse(options.prints(annotation(.highlight)))
        options.addedText = true
        options.content = .documentOnly
        XCTAssertFalse(options.prints(annotation(.freeText)))
        XCTAssertFalse(options.prints(annotation(.text)))
    }
}
