import CoreText
import XCTest
@testable import SlekPDF

/// KhmerOCR engine (ONNX Runtime, arm64) and the per-page routing helpers.
@MainActor
final class KhmerOCREngineTests: XCTestCase {
    private func engine() throws -> KhmerOCREngine {
        #if arch(arm64)
        return try XCTUnwrap(KhmerOCREngine.load(), "ONNX Runtime or the KhmerOCR models are missing from the app bundle")
        #else
        throw XCTSkip("ONNX Runtime ships arm64-only; Intel Macs use Tesseract")
        #endif
    }

    /// White image with `lines` of Khmer text (Noto Sans Khmer), 300 dpi-like scale.
    private func render(_ lines: [String], size: CGFloat = 40) throws -> CGImage {
        FontRegistry.registerBundledFonts()
        let width = 1600, height = 120 + lines.count * Int(size * 2.2)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("NotoSansKhmer-Regular" as CFString, size, nil)
        for (index, text) in lines.enumerated() {
            context.textPosition = CGPoint(x: 60, y: CGFloat(height) - 80 - CGFloat(index) * size * 2.2)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), context)
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testReadsAKhmerLine() throws {
        let engine = try engine()
        let text = "សេចក្តីជូនដំណឹង"
        let image = try render([text])
        // The recognizer reads the tight boxes its detector finds (as in OCRWorker).
        let box = try XCTUnwrap(engine.detectLines(image).first?.first { $0.isText })
        let reading = try engine.recognize(try XCTUnwrap(image.cropping(to: box.rect.integral)))
        XCTAssertEqual(reading.text, text)
        XCTAssertGreaterThan(reading.confidence, 0.9)
    }

    func testDetectsLinesTopToBottomAndReadsThem() throws {
        let engine = try engine()
        let texts = ["ព្រះរាជាណាចក្រកម្ពុជា", "ជាតិ សាសនា ព្រះមហាក្សត្រ"]
        let image = try render(texts)
        let lines = try engine.detectLines(image).filter { $0.contains(where: \.isText) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertLessThan(lines[0][0].rect.minY, lines[1][0].rect.minY, "top line first")
        let first = try lines[0].filter(\.isText).map { try engine.recognize(XCTUnwrap(image.cropping(to: $0.rect.integral))).text }.joined()
        XCTAssertEqual(first, texts[0])
    }

    func testNMSContainmentAndLineGrouping() {
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ score: Float = 0.9) -> KhmerOCREngine.Box {
            KhmerOCREngine.Box(rect: CGRect(x: x, y: y, width: w, height: h), isText: true, score: score)
        }
        let overlapping = [box(0, 0, 100, 20, 0.9), box(2, 1, 100, 20, 0.8), box(300, 0, 50, 20)]
        XCTAssertEqual(KhmerOCREngine.nms(overlapping, threshold: 0.45).count, 2)
        XCTAssertEqual(KhmerOCREngine.dropContained([box(0, 0, 400, 30), box(10, 2, 100, 26), box(500, 0, 50, 30)]).count, 2,
                       "a box inside a longer one would be read twice")
        let lines = KhmerOCREngine.lines([box(200, 4, 80, 20), box(0, 0, 80, 20), box(0, 60, 80, 20)])
        XCTAssertEqual(lines.map { $0.map(\.rect.minX) }, [[0, 200], [0]])
    }

    func testEnglishBoxesNeedLatinTextAndConfidence() {
        func result(_ text: String, _ confidence: Int) -> OCRResult { OCRResult(text: text, meanConfidence: confidence) }
        XCTAssertTrue(OCRWorker.isEnglish(result("SYNTHETIC TEST DATA", 90), confidence: 75))
        XCTAssertTrue(OCRWorker.isEnglish(result("Invoice 2026-11", 80), confidence: 75))
        XCTAssertFalse(OCRWorker.isEnglish(result("SYNTHETIC", 50), confidence: 75), "not confident")
        XCTAssertFalse(OCRWorker.isEnglish(result("ឯកសារ Doc", 95), confidence: 75), "mostly Khmer")
        XCTAssertFalse(OCRWorker.isEnglish(nil, confidence: 60))
    }
}
