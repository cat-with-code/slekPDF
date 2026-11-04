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
        // A tall picture box among the lines used to glue two text lines together; pictures are grouped apart.
        var picture = box(400, 0, 300, 400)
        picture.isText = false
        let withPicture = KhmerOCREngine.lines([box(0, 0, 80, 20), box(0, 60, 80, 20)])
        XCTAssertEqual(withPicture.count, 2)
        XCTAssertFalse(KhmerOCREngine.lines([box(0, 0, 80, 20), picture, box(0, 60, 80, 20)]).isEmpty)
    }

    func testABoxOverTwoLinesIsCutAtTheGap() throws {
        // Two lines 60 px apart; the detector's box covers both (as on a title page's list).
        let image = try render(["សញ្ញាចរាចរណ៍", "", "", "ភ្លើងសញ្ញា"], size: 30)
        func box(_ y: CGFloat, _ h: CGFloat) -> KhmerOCREngine.Box {
            KhmerOCREngine.Box(rect: CGRect(x: 40, y: y, width: 500, height: h), isText: true, score: 0.9)
        }
        // Three ordinary lines elsewhere set the usual height (about 46 px).
        let ordinary = [box(1000, 46), box(1100, 46), box(1200, 46)]
        let tall = box(30, CGFloat(image.height) - 60)
        let split = KhmerOCREngine.splitTallBoxes(ordinary + [tall], in: image)
        XCTAssertEqual(split.count, ordinary.count + 2, "\(split.map(\.rect))")
        XCTAssertEqual(KhmerOCREngine.splitTallBoxes(ordinary, in: image).count, ordinary.count, "ordinary lines are left alone")
    }

    /// A seal's bottom text (“MINISTRY OF …” around the circle, tops inward) is unrolled into a straight strip and read.
    func testTextAroundACircleIsUnrolledAndRead() throws {
        let side = 1200, center = CGPoint(x: 600, y: 600)
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 64, nil)
        let text = "MINISTRY OF PUBLIC WORKS"
        let radius: CGFloat = 540  // the letters' baseline (outer side: tops point inward)
        let advances = text.map { CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: String($0),
                                                              attributes: [.font: font])), nil, nil, nil) }
        var phi = .pi / 2 + CGFloat(advances.reduce(0, +)) / radius / 2  // image angle (y down); bottom = π/2
        for (character, advance) in zip(text, advances) {
            let mid = phi - CGFloat(advance) / radius / 2
            // CoreGraphics is y-up: the glyph's position and its rotation (tops toward the centre).
            let x = center.x + radius * cos(phi), y = CGFloat(side) - (center.y + radius * sin(phi))
            context.saveGState()
            context.translateBy(x: x, y: y)
            context.rotate(by: .pi / 2 - mid)
            context.textPosition = .zero
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [.font: font])), context)
            context.restoreGState()
            phi -= CGFloat(advance) / radius
        }
        let image = try XCTUnwrap(context.makeImage())
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        XCTAssertTrue(RingText.isRoundCandidate(rect, page: CGSize(width: 2480, height: 3508)))
        XCTAssertFalse(RingText.isRoundCandidate(CGRect(x: 0, y: 0, width: 1000, height: 2000), page: CGSize(width: 2480, height: 3508)))
        let strips = RingText.strips(of: image, circleIn: rect)
        XCTAssertEqual(strips.count, 2)
        let bottom = try XCTUnwrap(strips.last)
        XCTAssertGreaterThan(bottom.pageRect.minY, center.y, "the bottom arc")
        let models = try XCTUnwrap(OCRModelSet.best.directory())
        let english = try TesseractEngine(languages: "eng", models: models)
        let end = CGFloat(bottom.image.width) * CGFloat(RingText.endFraction)
        let middle = try XCTUnwrap(bottom.image.cropping(to: CGRect(x: end, y: 0, width: CGFloat(bottom.image.width) - 2 * end,
                                                                   height: CGFloat(bottom.image.height)).integral))
        let read = try english.recognize(middle, ppi: 300, deadline: 10, singleLine: true)
        XCTAssertTrue(read.text.contains("MINISTRY") && read.text.contains("PUBLIC"), read.text)
        XCTAssertEqual(OCRWorker.trimmingStrayEnds("3 MINISTRY OF PUBLIC WORKS i"), "MINISTRY OF PUBLIC WORKS")
    }

    func testMarkOnlyLinesAreDroppedAndSplitWordsRejoined() {
        XCTAssertTrue(OCRWorker.isNoise("+. :=4>32»--+-"), "round seal text")
        XCTAssertTrue(OCRWorker.isNoise("---------------”-”””-"), "a ruled line")
        XCTAssertFalse(OCRWorker.isNoise("R1-01 R1-02 R1-03"))
        XCTAssertFalse(OCRWorker.isNoise("1 - 15"))
        XCTAssertFalse(OCRWorker.isNoise("ផ្លាកសញ្ញាចរាចរណ៍ (ROAD SIGNS)"))
        let result = OCRResult(text: "a\nb", meanConfidence: 80, lines: [
            OCRResult.Line(text: "ក្រសួងសាធារណការ", pixelRect: .zero, confidence: 90),
            OCRResult.Line(text: "+. :=4>32»--+-", pixelRect: .zero, confidence: 10),
        ])
        XCTAssertEqual(OCRWorker.normalized(result).text, "ក្រសួងសាធារណការ")
        XCTAssertEqual(OCRWorker.join(["ផ្លូវគ", "ោក", "ROAD"]), "ផ្លូវគោក ROAD")
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
