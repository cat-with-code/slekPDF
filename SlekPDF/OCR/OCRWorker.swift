import CoreGraphics
import Foundation

/// Runs OCR off the main thread, one page at a time, on its own serial queue (the engines are not thread-safe and a
/// page takes about a second — too long to hold a Swift concurrency thread). Engines are loaded once and kept.
///
/// Khmer pages use KhmerOCR (detector + Khmer recognizer) with Tesseract for what KhmerOCR cannot read; measured on the
/// TestDocuments set this halves the error rate (docs/spikes/04-khmerocr.md). Per page:
/// 1. KhmerOCR finds the text boxes and reads each one; Tesseract (English, one line) reads the same box.
/// 2. If most boxes (≥ 80 %) are confidently English, the page is an English page: Tesseract reads it whole.
/// 3. Otherwise each box keeps the English reading when Tesseract is sure it is English (≥ 75), else KhmerOCR's reading,
///    or Tesseract Khmer + English for that box when KhmerOCR is unsure (< 0.9).
/// English-only OCR, and Macs where KhmerOCR cannot run (ONNX Runtime ships arm64-only), use Tesseract as before.
nonisolated final class OCRWorker: @unchecked Sendable {
    static let shared = OCRWorker()

    /// Off for comparisons with the Tesseract-only path (benchmark).
    var usesKhmerOCR = true
    /// The route each page took (“khmerocr 0.12” / “tesseract 0.84”: English share), for the benchmark.
    private(set) var routeLog: [String] = []

    private let queue = DispatchQueue(label: "SlekPDF.OCRWorker", qos: .userInitiated)
    /// Only touched on `queue`.
    private var tesseracts: [String: TesseractEngine] = [:]
    private var khmerOCR: KhmerOCREngine?
    private var triedKhmerOCR = false

    /// Recognizes a page `image`; `isCancelled` is polled during recognition. Tesseract gives a page at most `deadline`
    /// seconds.
    func recognize(_ image: CGImage, ppi: Int, languages: String, deadline: TimeInterval = 60,
                   isCancelled: @escaping @Sendable () -> Bool) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.recognizePage(image, ppi: ppi, languages: languages, deadline: deadline,
                                                                          isCancelled: isCancelled))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Whether Khmer OCR uses KhmerOCR here (loads it on first use; on the queue).
    var khmerOCRAvailable: Bool { queue.sync { khmerEngine() != nil } }

    // MARK: On the queue

    private func tesseract(_ languages: String) throws -> TesseractEngine {
        if let engine = tesseracts[languages] { return engine }
        guard let models = OCRModelSet.best.directory() else { throw OCRError.modelsMissing }
        let engine = try TesseractEngine(languages: languages, models: models)
        tesseracts[languages] = engine
        return engine
    }

    private func khmerEngine() -> KhmerOCREngine? {
        if !triedKhmerOCR {
            triedKhmerOCR = true
            khmerOCR = KhmerOCREngine.load()
        }
        return khmerOCR
    }

    private func recognizePage(_ image: CGImage, ppi: Int, languages: String, deadline: TimeInterval,
                               isCancelled: @escaping @Sendable () -> Bool) throws -> OCRResult {
        let page = try tesseract(languages)
        guard usesKhmerOCR, languages.contains("khm"), let khmer = khmerEngine(),
              let detected = try? khmer.detectLines(image) else {
            return try page.recognize(image, ppi: ppi, deadline: deadline, isCancelled: isCancelled)
        }
        let english = languages.contains("eng") ? try tesseract("eng") : nil
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)

        struct Read {
            let rect: CGRect
            let crop: CGImage
            let khmer: KhmerOCREngine.Reading
            let english: OCRResult?
        }
        var lines: [[Read]] = []
        for line in detected {
            var reads: [Read] = []
            for box in line where box.isText {
                guard !isCancelled() else { throw OCRError.cancelledOrTimedOut }
                // KhmerOCR reads the exact box (as trained); Tesseract gets a little margin.
                let exact = box.rect.intersection(bounds).integral, rect = box.rect.insetBy(dx: -4, dy: -4).intersection(bounds).integral
                guard exact.width >= 2, exact.height >= 2, let tight = image.cropping(to: exact), let crop = image.cropping(to: rect),
                      let reading = try? khmer.recognize(tight) else { continue }
                reads.append(Read(rect: rect, crop: crop, khmer: reading,
                                  english: try? english?.recognize(crop, ppi: ppi, deadline: 5, singleLine: true, isCancelled: isCancelled)))
            }
            if !reads.isEmpty { lines.append(reads) }
        }
        let all = lines.flatMap { $0 }
        let englishShare = Double(all.filter { Self.isEnglish($0.english, confidence: 60) }.count) / Double(max(1, all.count))
        routeLog.append("\(all.isEmpty || englishShare >= 0.8 ? "tesseract" : "khmerocr") \(String(format: "%.2f", englishShare)) of \(all.count)")
        if all.isEmpty || englishShare >= 0.8 {
            return try page.recognize(image, ppi: ppi, deadline: deadline, isCancelled: isCancelled)
        }

        var result: [OCRResult.Line] = []
        for line in lines {
            var parts: [(text: String, confidence: Double)] = []
            for read in line {
                guard !isCancelled() else { throw OCRError.cancelledOrTimedOut }
                if let english = read.english, Self.isEnglish(english, confidence: 75) {
                    parts.append((Self.clean(english.text), Double(english.meanConfidence)))
                } else if read.khmer.confidence < 0.9,
                          let mixed = try? page.recognize(read.crop, ppi: ppi, deadline: 5, singleLine: true, isCancelled: isCancelled),
                          !Self.clean(mixed.text).isEmpty {
                    parts.append((Self.clean(mixed.text), Double(mixed.meanConfidence)))
                } else if !read.khmer.text.isEmpty {
                    parts.append((read.khmer.text, read.khmer.confidence * 100))
                }
            }
            guard !parts.isEmpty else { continue }
            let rect = line.dropFirst().reduce(line[0].rect) { $0.union($1.rect) }
            result.append(OCRResult.Line(text: parts.map(\.text).joined(separator: " "), pixelRect: rect,
                                         confidence: parts.map(\.confidence).reduce(0, +) / Double(parts.count)))
        }
        let mean = result.isEmpty ? 0 : result.map(\.confidence).reduce(0, +) / Double(result.count)
        return OCRResult(text: result.map(\.text).joined(separator: "\n"), meanConfidence: Int(mean), lines: result)
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Tesseract read a box as English: mostly Latin letters and digits, and confident.
    static func isEnglish(_ result: OCRResult?, confidence: Int) -> Bool {
        guard let result, result.meanConfidence >= confidence else { return false }
        let visible = result.text.unicodeScalars.filter { !$0.properties.isWhitespace }
        let latin = visible.filter { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil) }.count
        return latin >= max(1, Int((Double(visible.count) * 0.6).rounded(.up)))
    }
}

/// A cancel flag readable from the OCR queue.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
