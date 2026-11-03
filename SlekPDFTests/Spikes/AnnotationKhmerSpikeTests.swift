import AppKit
import CoreText
import PDFKit
import XCTest
@testable import SlekPDF

/// Annotate step 1 (docs/plans/annotate.md): can an added Khmer text box be stored in saved work so that it
/// (a) comes back in Slek with its text and style, (b) keeps the exact Unicode text, and (c) is drawn correctly by
/// renderers that do not shape Khmer? The appearance is CoreText-shaped glyph outlines, so (c) is checked by
/// comparing each renderer's ink with CoreText drawing the same text directly.
@MainActor
final class AnnotationKhmerSpikeTests: XCTestCase {
    private let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-spike")
    private let text = "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"
    private let rect = CGRect(x: 72, y: 600, width: 360, height: 90)
    private let scale: CGFloat = 3

    func testKhmerTextBoxSurvivesSaveAndRendersWithoutShaping() throws {
        FontRegistry.registerBundledFonts()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let style = TextBoxStyle(fontSize: 18, bold: true)

        // A blank A4 page, a text box on it, saved and reopened.
        let blankURL = outDir.appendingPathComponent("blank.pdf")
        var media = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(blankURL as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let document = try PDFiumDocument(url: blankURL)
        try document.addTextBox(page: 0, rect: rect, text: text, style: style)
        let savedURL = outDir.appendingPathComponent("text-box.pdf")
        try document.save(to: savedURL)

        // (a) + (b): back in Slek, exactly.
        let reopened = try PDFiumDocument(url: savedURL)
        let boxes = try reopened.textBoxes(page: 0)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes.first?.text.unicodeScalars.map(\.value), text.unicodeScalars.map(\.value), "Unicode changed")
        XCTAssertEqual(boxes.first?.style, style)
        XCTAssertEqual(boxes.first.map { $0.rect.insetBy(dx: -0.01, dy: -0.01).contains(rect) }, true, "\(String(describing: boxes.first?.rect))")
        let kitAnnotation = try XCTUnwrap(PDFDocument(url: savedURL)?.page(at: 0)?.annotations.first)
        XCTAssertEqual(kitAnnotation.type, "FreeText")
        XCTAssertEqual(kitAnnotation.contents, text, "PDFKit reads different text")

        // (c): ink compared with CoreText drawing the text itself.
        let pdfiumImage = try XCTUnwrap(reopened.render(page: 0, scale: scale))
        let pdfKitImage = try pdfKitImage(savedURL)
        let referenceImage = try referenceImage(style: style)
        try writePNG(pdfiumImage, "pdfium.png")
        try writePNG(pdfKitImage, "pdfkit.png")
        try writePNG(referenceImage, "coretext.png")
        let reference = try mask(of: referenceImage), pdfium = try mask(of: pdfiumImage), pdfKit = try mask(of: pdfKitImage)
        // Edges differ by anti-aliasing (CoreText smooths text; the box is a filled path), so ink counts as matching
        // within 1 px (at 3×). Unshaped or misplaced Khmer moves whole marks, far beyond that.
        let pdfiumMatch = matching(pdfium, reference), pdfKitMatch = matching(pdfKit, reference)
        print("ANNOTATION-SPIKE ink: reference=\(reference.count) pdfium=\(pdfium.count) \(pdfiumMatch) pdfkit=\(pdfKit.count) \(pdfKitMatch) out=\(outDir.path)")
        XCTAssertGreaterThan(reference.count, 1000, "reference drew nothing")
        XCTAssertGreaterThan(min(pdfiumMatch.0, pdfiumMatch.1), 0.98, "PDFium draws the box differently from CoreText")
        XCTAssertGreaterThan(min(pdfKitMatch.0, pdfKitMatch.1), 0.98, "PDFKit draws the box differently from CoreText")
    }

    // MARK: - Helpers

    private var pixelSize: (width: Int, height: Int) { (Int(595 * scale), Int(842 * scale)) }

    /// CoreText drawing the same text in the same box: what the text should look like.
    private func referenceImage(style: TextBoxStyle) throws -> CGImage {
        let context = try bitmap()
        context.scaleBy(x: scale, y: scale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineSpacing
        let font = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
        let string = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph,
                                                                    .foregroundColor: NSColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1)])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
        return try XCTUnwrap(context.makeImage())
    }

    private func pdfKitImage(_ url: URL) throws -> CGImage {
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let context = try bitmap()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return try XCTUnwrap(context.makeImage())
    }

    private func bitmap() throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: pixelSize.width, height: pixelSize.height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height))
        return context
    }

    /// Indices of dark pixels.
    private func mask(of image: CGImage) throws -> Set<Int> {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Set(pixels.indices.filter { pixels[$0] < 128 })
    }

    /// Share of `a`'s ink within 1 px of `b`'s ink, and of `b`'s within 1 px of `a`'s.
    private func matching(_ a: Set<Int>, _ b: Set<Int>) -> (Double, Double) {
        let width = pixelSize.width
        func near(_ index: Int, _ set: Set<Int>) -> Bool {
            for dy in -1...1 { for dx in -1...1 where set.contains(index + dy * width + dx) { return true } }
            return false
        }
        func share(_ x: Set<Int>, _ y: Set<Int>) -> Double { x.isEmpty ? 0 : Double(x.filter { near($0, y) }.count) / Double(x.count) }
        return (share(a, b), share(b, a))
    }

    private func writePNG(_ image: CGImage, _ name: String) throws {
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: outDir.appendingPathComponent(name))
    }
}
