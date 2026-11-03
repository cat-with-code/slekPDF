import CoreGraphics
import CoreImage
import Foundation
import Tesseract

/// Bundled Tesseract model sets (Resources/tessdata-*.bundle; khm + eng).
nonisolated enum OCRModelSet: String, CaseIterable, Sendable {
    /// tessdata_fast 4.1.0 — 5.5 MB
    case fast = "tessdata-fast"
    /// tessdata_best 4.1.0 — 23.5 MB
    case best = "tessdata-best"

    func directory(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: rawValue, withExtension: "bundle")
    }
}

nonisolated struct OCRResult: Sendable {
    let text: String
    /// Tesseract's mean word confidence, 0–100. A review aid, not a correctness score.
    let meanConfidence: Int
    /// Text lines in reading order, with their boxes in image pixels (origin top-left).
    var lines: [Line] = []

    struct Line: Sendable, Equatable {
        let text: String
        let pixelRect: CGRect
        /// 0–100, as `meanConfidence`.
        let confidence: Double
    }
}

nonisolated enum OCRError: Error {
    case modelsMissing, initFailed(Int32), recognitionFailed, cancelledOrTimedOut
}

/// How Tesseract turns the page into black and white before recognition.
nonisolated enum OCRThresholding: Int, Sendable {
    /// Tesseract's default global Otsu threshold.
    case otsu = 0
    /// Local (Sauvola) threshold — copes with grey or uneven paper.
    case sauvola = 2
}

/// Image clean-up before OCR (Core Image).
nonisolated enum OCRPreprocessor {
    /// Median filter against grain, then Core Image's document enhancer (whitens the background, sharpens text).
    static func clean(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIMedianFilter")
            .applyingFilter("CIDocumentEnhancer", parameters: ["inputAmount": 1.0])
            .cropped(to: image.extent)
    }
}

/// Local Khmer/English OCR with Tesseract (LSTM engine). Not thread-safe: one engine per worker.
nonisolated final class TesseractEngine {
    private let handle: OpaquePointer

    init(languages: String = "khm+eng", models: URL, thresholding: OCRThresholding = .sauvola) throws {
        guard let api = TessBaseAPICreate() else { throw OCRError.initFailed(-1) }
        let status = models.withUnsafeFileSystemRepresentation { path in
            TessBaseAPIInit2(api, path, languages, OEM_LSTM_ONLY)
        }
        guard status == 0 else {
            TessBaseAPIDelete(api)
            throw OCRError.initFailed(status)
        }
        handle = api
        TessBaseAPISetVariable(api, "thresholding_method", String(thresholding.rawValue))
    }

    deinit {
        TessBaseAPIEnd(handle)
        TessBaseAPIDelete(handle)
    }

    /// Recognizes a rendered page. The image is converted to 8-bit grayscale; `ppi` is the render resolution.
    /// Stops early (throws `.cancelledOrTimedOut`) when `isCancelled` returns true or after `deadline` seconds.
    func recognize(_ image: CGImage, ppi: Int, deadline: TimeInterval? = nil,
                   isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> OCRResult {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw OCRError.recognitionFailed }

        TessBaseAPISetImage(handle, pixels, Int32(width), Int32(height), 1, Int32(width))
        TessBaseAPISetSourceResolution(handle, Int32(ppi))

        let monitor = TessMonitorCreate()
        defer { TessMonitorDelete(monitor) }
        let cancelBox = CancelBox(isCancelled)
        let boxPointer = Unmanaged.passRetained(cancelBox)
        defer { boxPointer.release() }
        TessMonitorSetCancelThis(monitor, boxPointer.toOpaque())
        TessMonitorSetCancelFunc(monitor) { context, _ in
            guard let context else { return false }
            return Unmanaged<CancelBox>.fromOpaque(context).takeUnretainedValue().isCancelled()
        }
        if let deadline { TessMonitorSetDeadlineMSecs(monitor, Int32(deadline * 1000)) }
        guard TessBaseAPIRecognize(handle, monitor) == 0, !isCancelled() else { throw OCRError.cancelledOrTimedOut }

        guard let cText = TessBaseAPIGetUTF8Text(handle) else { throw OCRError.recognitionFailed }
        defer { TessDeleteText(cText) }
        return OCRResult(text: String(cString: cText), meanConfidence: Int(TessBaseAPIMeanTextConf(handle)), lines: lines())
    }

    /// The recognized text lines (after `recognize`), skipping empty ones.
    private func lines() -> [OCRResult.Line] {
        guard let iterator = TessBaseAPIGetIterator(handle) else { return [] }
        defer { TessResultIteratorDelete(iterator) }
        let page = TessResultIteratorGetPageIterator(iterator)
        var result: [OCRResult.Line] = []
        repeat {
            guard let cLine = TessResultIteratorGetUTF8Text(iterator, RIL_TEXTLINE) else { continue }
            let text = String(cString: cLine).trimmingCharacters(in: .whitespacesAndNewlines)
            TessDeleteText(cLine)
            var left: Int32 = 0, top: Int32 = 0, right: Int32 = 0, bottom: Int32 = 0
            guard !text.isEmpty, TessPageIteratorBoundingBox(page, RIL_TEXTLINE, &left, &top, &right, &bottom) != 0 else { continue }
            result.append(OCRResult.Line(text: text,
                                         pixelRect: CGRect(x: Int(left), y: Int(top), width: Int(right - left), height: Int(bottom - top)),
                                         confidence: Double(TessResultIteratorConfidence(iterator, RIL_TEXTLINE))))
        } while TessResultIteratorNext(iterator, RIL_TEXTLINE) != 0
        return result
    }
}

nonisolated private final class CancelBox {
    let isCancelled: @Sendable () -> Bool
    init(_ isCancelled: @escaping @Sendable () -> Bool) { self.isCancelled = isCancelled }
}
