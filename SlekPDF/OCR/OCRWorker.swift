import CoreGraphics
import Foundation

/// Runs Tesseract off the main thread, one page at a time, on its own serial queue (Tesseract is not thread-safe and a
/// page takes about a second — too long to hold a Swift concurrency thread). The engine (about 100 MB of models) is
/// loaded once and kept while the language stays the same.
nonisolated final class OCRWorker: @unchecked Sendable {
    static let shared = OCRWorker()

    private let queue = DispatchQueue(label: "SlekPDF.OCRWorker", qos: .userInitiated)
    /// Only touched on `queue`.
    private var engine: (languages: String, engine: TesseractEngine)?

    /// Recognizes `image`; `isCancelled` is polled during recognition. A page is given at most `deadline` seconds.
    func recognize(_ image: CGImage, ppi: Int, languages: String, deadline: TimeInterval = 60,
                   isCancelled: @escaping @Sendable () -> Bool) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.engine?.languages != languages {
                        guard let models = OCRModelSet.best.directory() else { throw OCRError.modelsMissing }
                        self.engine = (languages, try TesseractEngine(languages: languages, models: models))
                    }
                    let result = try self.engine!.engine.recognize(image, ppi: ppi, deadline: deadline, isCancelled: isCancelled)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// A cancel flag readable from the OCR queue.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
