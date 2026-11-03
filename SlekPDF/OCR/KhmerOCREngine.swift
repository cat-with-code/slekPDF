import CoreGraphics
import Darwin
import Foundation
import ONNXRuntimeC

/// KhmerOCR (github.com/seanghay/KhmerOCR, MIT): a text-line detector and a Khmer line recognizer trained on 3 million
/// lines in 800+ Khmer fonts, run with ONNX Runtime. Pre/post-processing follows the reference `khmerocr/__init__.py`.
/// ONNX Runtime is opened with `dlopen` (the shipped library is arm64-only), so `load()` returns nil where it cannot
/// run and callers keep using Tesseract. Not thread-safe: use from one queue (OCRWorker).
nonisolated final class KhmerOCREngine {
    /// A detected region in image pixels (origin top-left).
    struct Box: Equatable {
        var rect: CGRect
        var isText: Bool
        var score: Float
    }

    struct Reading: Equatable {
        let text: String
        /// Mean probability of the decoded characters, 0–1.
        let confidence: Double
        /// Regular, Italic, Bold, BoldItalic, Moul or MoulLight.
        let font: String
    }

    enum EngineError: Error { case runtime(String) }

    /// The recognizer's alphabet (index + 3 = model class; 0 is the CTC blank). Khmer only.
    private static let tokens = Array("កខគឃងចឆជឈញដឋឌឍណតថទធនបផពភមយរលវឝឞសហឡអឣឤឥឦឧឩឪឫឬឭឮឯឰឱឲឳាិីឹឺុូួើឿៀេែៃោៅំះៈ៉៊់៌៍៎៏័៑្។៕៖ៗ៘៛៝០១២៣៤៥៦៧៨៩៳".unicodeScalars)
    private static let fonts = ["Regular", "Italic", "Bold", "BoldItalic", "Moul", "MoulLight"]

    private let api: UnsafePointer<OrtApi>
    private let env: OpaquePointer
    private let detector: OpaquePointer
    private let recognizer: OpaquePointer
    private let memory: OpaquePointer
    private let detectorOutput: String

    /// The bundled engine, or nil when ONNX Runtime or the models are not available here (e.g. on Intel Macs).
    static func load(bundle: Bundle = .main) -> KhmerOCREngine? {
        guard let library = bundle.privateFrameworksURL?.appendingPathComponent("libonnxruntime.dylib"),
              let models = bundle.url(forResource: "khmerocr", withExtension: "bundle") else { return nil }
        return try? KhmerOCREngine(library: library, models: models)
    }

    init(library: URL, models: URL) throws {
        guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
            throw EngineError.runtime(String(cString: dlerror()))
        }
        typealias GetApiBase = @convention(c) () -> UnsafePointer<OrtApiBase>?
        guard let symbol = dlsym(handle, "OrtGetApiBase"),
              let base = unsafeBitCast(symbol, to: GetApiBase.self)(),
              let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else { throw EngineError.runtime("no ONNX Runtime API") }
        self.api = api
        var env: OpaquePointer?
        try Self.check(api, api.pointee.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "SlekPDF", &env))
        self.env = env!
        var options: OpaquePointer?
        try Self.check(api, api.pointee.CreateSessionOptions(&options))
        defer { api.pointee.ReleaseSessionOptions(options) }
        try Self.check(api, api.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        try Self.check(api, api.pointee.SetIntraOpNumThreads(options, 2))
        func session(_ name: String) throws -> OpaquePointer {
            var session: OpaquePointer?
            try Self.check(api, api.pointee.CreateSession(env, models.appendingPathComponent(name).path, options, &session))
            return session!
        }
        detector = try session("det.onnx")
        recognizer = try session("rec.onnx")
        var memory: OpaquePointer?
        try Self.check(api, api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
        self.memory = memory!
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try Self.check(api, api.pointee.GetAllocatorWithDefaultOptions(&allocator))
        var name: UnsafeMutablePointer<CChar>?
        try Self.check(api, api.pointee.SessionGetOutputName(detector, 0, allocator, &name))
        detectorOutput = name.map { String(cString: $0) } ?? "output0"
        if let name { _ = api.pointee.AllocatorFree(allocator, name) }
    }

    deinit {
        api.pointee.ReleaseSession(detector)
        api.pointee.ReleaseSession(recognizer)
        api.pointee.ReleaseMemoryInfo(memory)
        api.pointee.ReleaseEnv(env)
    }

    // MARK: Detection

    /// Text and figure regions, grouped into lines (top to bottom, each left to right).
    func detectLines(_ image: CGImage) throws -> [[Box]] {
        let side = 1024
        let ratio = min(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
        let width = Int(CGFloat(image.width) * ratio), height = Int(CGFloat(image.height) * ratio)
        // Letterbox: the page scaled into the top-left of a black 1024 × 1024 canvas, RGB planes, 0–1.
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: side - height, width: width, height: height))
        }
        var input = [Float](repeating: 0, count: 3 * side * side)
        for i in 0..<(side * side) {
            input[i] = Float(rgba[i * 4]) / 255
            input[side * side + i] = Float(rgba[i * 4 + 1]) / 255
            input[2 * side * side + i] = Float(rgba[i * 4 + 2]) / 255
        }
        let (output, shape) = try run(detector, input: "images", data: &input, shape: [1, 3, Int64(side), Int64(side)], outputs: [detectorOutput])[0]
        // Output [1, 4 + classes, N]: centre x, centre y, width, height, then class scores (0 = figure, 1 = text).
        guard shape.count == 3 else { return [] }
        let rows = Int(shape[1]), count = Int(shape[2])
        var boxes: [Box] = []
        for i in 0..<count {
            var best = 0, score: Float = 0
            for c in 4..<rows where output[c * count + i] > score {
                score = output[c * count + i]
                best = c - 4
            }
            guard score > 0.25 else { continue }
            let cx = output[i], cy = output[count + i], w = output[2 * count + i], h = output[3 * count + i]
            boxes.append(Box(rect: CGRect(x: CGFloat(cx - w / 2), y: CGFloat(cy - h / 2), width: CGFloat(w), height: CGFloat(h)),
                             isText: best == 1, score: score))
        }
        let kept = Self.dropContained(Self.nms(boxes, threshold: 0.45)).map { box -> Box in
            var scaled = box
            scaled.rect = CGRect(x: box.rect.minX / ratio, y: box.rect.minY / ratio, width: box.rect.width / ratio, height: box.rect.height / ratio)
            return scaled
        }
        return Self.lines(kept)
    }

    /// Greedy non-maximum suppression over all classes (as the reference).
    static func nms(_ boxes: [Box], threshold: CGFloat) -> [Box] {
        var order = boxes.sorted { $0.score > $1.score }
        var kept: [Box] = []
        while let first = order.first {
            kept.append(first)
            order = order.dropFirst().filter { box in
                let inter = first.rect.intersection(box.rect)
                guard !inter.isNull else { return true }
                let overlap = inter.width * inter.height
                return overlap / (first.rect.width * first.rect.height + box.rect.width * box.rect.height - overlap) <= threshold
            }
        }
        return kept
    }

    /// Drops a text box lying mostly (≥ 80 %) inside a larger text box: NMS keeps such pairs (low overlap ratio), and
    /// both would be read, duplicating the words.
    static func dropContained(_ boxes: [Box]) -> [Box] {
        boxes.filter { box in
            !boxes.contains { other in
                guard other != box, box.isText, other.isText, other.rect.width * other.rect.height > box.rect.width * box.rect.height else { return false }
                let inter = other.rect.intersection(box.rect)
                return !inter.isNull && inter.width * inter.height >= 0.8 * box.rect.width * box.rect.height
            }
        }
    }

    /// Reading lines: sorted by top edge (figures by bottom edge); a box starts a new line when its edge is more than
    /// half the previous box's height away; each line left to right.
    static func lines(_ boxes: [Box]) -> [[Box]] {
        func key(_ box: Box) -> CGFloat { box.isText ? box.rect.minY : box.rect.maxY }
        let sorted = boxes.sorted { key($0) < key($1) }
        guard var current = sorted.first.map({ [$0] }) else { return [] }
        var lines: [[Box]] = []
        for box in sorted.dropFirst() {
            let previous = current[current.count - 1]
            if abs(key(box) - key(previous)) < previous.rect.height * 0.5 {
                current.append(box)
            } else {
                lines.append(current.sorted { $0.rect.minX < $1.rect.minX })
                current = [box]
            }
        }
        lines.append(current.sorted { $0.rect.minX < $1.rect.minX })
        return lines
    }

    // MARK: Recognition

    /// Reads one line image (any size; scaled to 32 px high, grayscale).
    func recognize(_ image: CGImage) throws -> Reading {
        let height = 32
        let width = max(1, Int(CGFloat(image.width) / CGFloat(image.height) * CGFloat(height)))
        var gray = [UInt8](repeating: 255, count: width * height)
        gray.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var input = gray.map { Float($0) / 255 }
        let outputs = try run(recognizer, input: "input", data: &input, shape: [1, 1, Int64(height), Int64(width)],
                              outputs: ["logits", "font_logits"])
        let (logits, shape) = outputs[0]
        guard shape.count == 3 else { return Reading(text: "", confidence: 0, font: "Regular") }
        let steps = Int(shape[0]), classes = Int(shape[2])
        var text = String.UnicodeScalarView(), probabilities: [Double] = [], previous = -1
        for t in 0..<steps {
            let row = logits[(t * classes)..<((t + 1) * classes)]
            let maxLogit = row.max() ?? 0
            let sum = row.reduce(0) { $0 + exp(Double($1 - maxLogit)) }
            let best = row.indices.max { row[$0] < row[$1] }! - t * classes
            if best != previous, best != 0 {
                if best - 3 >= 0, best - 3 < Self.tokens.count { text.append(Self.tokens[best - 3]) }
                probabilities.append(1 / sum)  // softmax of the best class: exp(0) / Σ exp(x − max)
            }
            previous = best
        }
        let fonts = outputs[1].data
        let font = fonts.indices.max { fonts[$0] < fonts[$1] }.map { Self.fonts[min($0, Self.fonts.count - 1)] } ?? "Regular"
        return Reading(text: String(text), confidence: probabilities.isEmpty ? 0 : probabilities.reduce(0, +) / Double(probabilities.count),
                       font: font)
    }

    // MARK: ONNX Runtime

    private func run(_ session: OpaquePointer, input name: String, data: inout [Float], shape: [Int64],
                     outputs names: [String]) throws -> [(data: [Float], shape: [Int64])] {
        var value: OpaquePointer?
        try data.withUnsafeMutableBytes { buffer in
            try shape.withUnsafeBufferPointer { dims in
                try Self.check(api, api.pointee.CreateTensorWithDataAsOrtValue(memory, buffer.baseAddress, buffer.count, dims.baseAddress, dims.count,
                                                                                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &value))
            }
        }
        defer { api.pointee.ReleaseValue(value) }
        var results = [OpaquePointer?](repeating: nil, count: names.count)
        let inputName = strdup(name)
        let outputNames = names.map { UnsafePointer(strdup($0)) }
        defer {
            free(inputName)
            outputNames.forEach { free(UnsafeMutablePointer(mutating: $0)) }
        }
        var inputNames: [UnsafePointer<CChar>?] = [UnsafePointer(inputName)]
        var inputs: [OpaquePointer?] = [value]
        try outputNames.withUnsafeBufferPointer { outputs in
            try Self.check(api, api.pointee.Run(session, nil, &inputNames, &inputs, 1, outputs.baseAddress, names.count, &results))
        }
        defer { results.forEach { api.pointee.ReleaseValue($0) } }
        return try results.map { result in
            var info: OpaquePointer?
            try Self.check(api, api.pointee.GetTensorTypeAndShape(result, &info))
            defer { api.pointee.ReleaseTensorTypeAndShapeInfo(info) }
            var count = 0
            try Self.check(api, api.pointee.GetDimensionsCount(info, &count))
            var dims = [Int64](repeating: 0, count: count)
            try Self.check(api, api.pointee.GetDimensions(info, &dims, count))
            var elements = 0
            try Self.check(api, api.pointee.GetTensorShapeElementCount(info, &elements))
            var pointer: UnsafeMutableRawPointer?
            try Self.check(api, api.pointee.GetTensorMutableData(result, &pointer))
            let floats = pointer.map { Array(UnsafeBufferPointer(start: $0.assumingMemoryBound(to: Float.self), count: elements)) } ?? []
            return (floats, dims)
        }
    }

    private static func check(_ api: UnsafePointer<OrtApi>, _ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "ONNX Runtime error"
        api.pointee.ReleaseStatus(status)
        throw EngineError.runtime(message)
    }
}
