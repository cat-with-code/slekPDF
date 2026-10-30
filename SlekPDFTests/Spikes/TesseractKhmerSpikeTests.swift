import AppKit
import CoreImage
import PDFKit
import XCTest
@testable import SlekPDF

/// Spike 02: Khmer OCR with the bundled Tesseract, inside the sandboxed app.
/// Renders the Core Text fixture as synthetic "scans" of different quality and reports character error
/// rate (CER, Unicode scalars, NFC, whitespace ignored), confidence, time and memory per model set.
/// Report: ~/Library/Containers/com.example.SlekPDF/Data/tmp/ocr-spike/report.txt (Tools/fixtures/run_ocr_spike.sh)
@MainActor
final class TesseractKhmerSpikeTests: XCTestCase {
    private let bundle = Bundle(for: TesseractKhmerSpikeTests.self)
    private let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-spike")

    func testKhmerOCRAcrossScanQualities() throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let lines = try JSONDecoder().decode([String].self, from: Data(contentsOf: try XCTUnwrap(bundle.url(forResource: "khmer-sample-lines", withExtension: "json"))))
        let expected = lines.joined(separator: "\n")
        let page = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(bundle.url(forResource: "khmer-coretext", withExtension: "pdf")))?.page(at: 0))

        let variants: [(String, Int, (CIImage) -> CIImage)] = [
            ("clean 300 dpi", 300, { $0 }),
            ("low-res 150 dpi", 150, { $0 }),
            ("blurred 300 dpi", 300, { $0.applyingGaussianBlur(sigma: 1.6).cropped(to: $0.extent) }),
            ("skewed 2° 300 dpi", 300, { Self.rotate($0, degrees: 2) }),
            ("noisy, low contrast 300 dpi", 300, { Self.degrade($0) }),
            ("noisy + clean-up 300 dpi", 300, { OCRPreprocessor.clean(Self.degrade($0)) }),
            ("clean + clean-up 300 dpi", 300, { OCRPreprocessor.clean($0) }),
        ]

        var report = ["Khmer OCR spike — Tesseract 5.5.3, khm+eng, LSTM. CER = edit distance / expected scalars (whitespace ignored).", ""]
        var cleanCER: [OCRModelSet: Double] = [:]
        for models in OCRModelSet.allCases {
          for thresholding in [OCRThresholding.otsu, .sauvola] {
            let start = Date()
            let engine = try TesseractEngine(models: try XCTUnwrap(models.directory(in: Bundle(for: AppState.self))), thresholding: thresholding)
            report.append("[\(models.rawValue), \(thresholding)] load \(Self.ms(since: start)) ms, footprint \(Self.footprintMB()) MB")
            for (name, ppi, transform) in variants { try autoreleasepool {
                let image = try Self.render(page, ppi: ppi, transform: transform)
                if models == .fast, thresholding == .otsu { try Self.writePNG(image, to: outDir.appendingPathComponent("scan-\(name.filter(\.isLetter)).png")) }
                let begin = Date()
                let result: OCRResult
                do {
                    result = try engine.recognize(image, ppi: ppi, deadline: 10)
                } catch OCRError.cancelledOrTimedOut {
                    report.append(String(format: "  %-28@ stopped by 10 s deadline after %d ms", name as NSString, Self.ms(since: begin)))
                    return
                }
                let cer = Self.cer(expected: expected, actual: result.text)
                if name == "clean 300 dpi", thresholding == .sauvola { cleanCER[models] = cer }
                report.append(String(format: "  %-28@ CER %5.1f%%  conf %3d  %5d ms  footprint %d MB", name as NSString, cer * 100, result.meanConfidence, Self.ms(since: begin), Self.footprintMB()))
                report.append("    → " + String(result.text.split(separator: "\n").joined(separator: " | ").prefix(220)))
            } }
            report.append("")
          }
        }
        try report.joined(separator: "\n").write(to: outDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
        // Spike gate: OCR runs offline in the sandbox and produces mostly-correct Khmer on a clean page.
        XCTAssertLessThan(cleanCER[.best] ?? 1, 0.25)
    }

    /// Memory of OCR alone (no Core Image): best models + Sauvola, one A4 page at 300 dpi, 5 runs.
    func testOCRMemoryAndSpeedAlone() throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let page = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(bundle.url(forResource: "khmer-coretext", withExtension: "pdf")))?.page(at: 0))
        let size = CGSize(width: 595 * 300 / 72, height: 842 * 300 / 72)
        let image = try XCTUnwrap(page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil))
        var lines = ["OCR alone (tessdata-best, Sauvola, A4 @ 300 dpi = \(image.width)×\(image.height) px)"]
        lines.append("  before engine: \(Self.footprintMB()) MB")
        let load = Date()
        let engine = try TesseractEngine(models: try XCTUnwrap(OCRModelSet.best.directory(in: Bundle(for: AppState.self))))
        lines.append("  engine loaded: \(Self.footprintMB()) MB in \(Self.ms(since: load)) ms")
        for run in 1...5 {
            let begin = Date()
            _ = try engine.recognize(image, ppi: 300)
            lines.append("  run \(run): \(Self.ms(since: begin)) ms, footprint \(Self.footprintMB()) MB")
        }
        try lines.joined(separator: "\n").write(to: outDir.appendingPathComponent("memory.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Rendering and degradation

    private static func render(_ page: PDFPage, ppi: Int, transform: (CIImage) -> CIImage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale = CGFloat(ppi) / 72
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let nsImage = page.thumbnail(of: size, for: .mediaBox)
        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw OCRError.recognitionFailed }
        let output = transform(CIImage(cgImage: cg))
        let context = Self.ciContext
        let white = CIImage(color: .white).cropped(to: output.extent)
        guard let result = context.createCGImage(output.composited(over: white), from: output.extent) else { throw OCRError.recognitionFailed }
        return result
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private static func rotate(_ image: CIImage, degrees: CGFloat) -> CIImage {
        let white = CIImage(color: .white).cropped(to: image.extent)
        let rotated = image.transformed(by: CGAffineTransform(translationX: image.extent.midX, y: image.extent.midY)
            .rotated(by: degrees * .pi / 180).translatedBy(x: -image.extent.midX, y: -image.extent.midY))
        return rotated.composited(over: white).cropped(to: image.extent)
    }

    private static func degrade(_ image: CIImage) -> CIImage {
        let washed = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.55, kCIInputBrightnessKey: 0.12])
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.18, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.18, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.18, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: -0.09, y: -0.09, z: -0.09, w: 0),
            ])
        return washed.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: noise]).applyingGaussianBlur(sigma: 0.6).cropped(to: image.extent)
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }

    // MARK: - Metrics

    static func cer(expected: String, actual: String) -> Double {
        func scalars(_ s: String) -> [Unicode.Scalar] {
            s.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !$0.properties.isWhitespace }
        }
        let a = scalars(expected), b = scalars(actual)
        guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(a.count)
    }

    private static func ms(since date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }

    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }
}
