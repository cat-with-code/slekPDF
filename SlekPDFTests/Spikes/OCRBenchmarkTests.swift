import XCTest
@testable import SlekPDF

/// OCR benchmark on the user's TestDocuments (kept outside the repo; copy them to the app container's
/// tmp/TestDocuments to run). Writes the recognized text of each document to tmp/ocr-bench/<doc>.<engine>.txt
/// (pages separated by form feed, as the ground-truth .txt files); Tools/ocr-eval scores them. Not a check: it runs only
/// with TEST_RUNNER_OCR_BENCH=1 (and OCR_BENCH_ENGINE=current for the Tesseract-only path).
@MainActor
final class OCRBenchmarkTests: XCTestCase {
    static let documents = [
        "digital/01_khmer_community_notice", "digital/02_english_project_memo", "digital/03_bilingual_library_guide",
        "digital/04_khmer_training_notes", "digital/05_english_service_report",
        "scanned/06_khmer_clean_scan", "scanned/07_english_skewed_scan", "scanned/08_bilingual_dim_photo",
        "scanned/09_khmer_noisy_photocopy", "scanned/10_english_low_resolution_packet",
        "tables/11_bilingual_digital_invoice", "tables/12_khmer_digital_timetable", "tables/13_english_digital_inventory",
        "tables/14_bilingual_scanned_scores", "tables/15_khmer_scanned_price_list",
    ]

    func testBenchmarkCurrentEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TestDocuments")
        guard ProcessInfo.processInfo.environment["OCR_BENCH"] != nil, FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("Benchmark: copy TestDocuments into the container tmp and run with TEST_RUNNER_OCR_BENCH=1 (Tools/ocr-eval/README.md)")
        }
        let engine = ProcessInfo.processInfo.environment["OCR_BENCH_ENGINE"] ?? "routed"
        OCRWorker.shared.usesKhmerOCR = engine != "current"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-bench")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var routes: [String] = []
        defer { try? routes.joined(separator: "\n").write(to: out.appendingPathComponent("routes.\(engine).txt"), atomically: true, encoding: .utf8) }
        for name in Self.documents {
            let session = DocumentSession()
            await session.open(root.appendingPathComponent("\(name).pdf"))
            guard session.document != nil else { XCTFail("cannot open \(name)"); continue }
            session.ocrSettings.skipPagesWithText = false
            session.ocrSettings.language = .khmerEnglish
            let start = Date()
            await session.startRecognition(Array(session.pages.indices), .en)?.value
            let text = session.pages.map { session.ocrResults[$0.id]?.text ?? "" }.joined(separator: "\u{0C}")
            let file = out.appendingPathComponent("\((name as NSString).lastPathComponent).\(engine).txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            // Line boxes (page space) and confidences, for designing per-line engine choice.
            let lines: [[String: Any]] = session.pages.enumerated().flatMap { index, ref in
                (session.ocrResults[ref.id]?.lines ?? []).map { line -> [String: Any] in
                    ["page": index, "text": line.text, "confidence": line.confidence,
                     "x": line.bounds.minX, "y": line.bounds.minY, "w": line.bounds.width, "h": line.bounds.height]
                }
            }
            try JSONSerialization.data(withJSONObject: lines).write(to: out.appendingPathComponent("\((name as NSString).lastPathComponent).\(engine).lines.json"))
            routes.append("\(name) \(String(format: "%.1f", Date().timeIntervalSince(start)))s \(OCRWorker.shared.routeLog.suffix(session.pageCount))")
            await session.close()
        }
    }

    /// Text-layer diagnostics for real PDFs (tmp/RealDocuments, never committed): fonts per page and the rebuilt text,
    /// written to tmp/ocr-bench/<doc>.layer.txt, for tuning the unreadable-layer check.
    func testDumpTextLayersOfRealDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RealDocuments")
        guard ProcessInfo.processInfo.environment["OCR_BENCH"] != nil,
              let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Copy PDFs into the container tmp/RealDocuments and run with TEST_RUNNER_OCR_BENCH=1")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-bench")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for file in files where file.pathExtension.lowercased() == "pdf" {
            let pdf = try PDFiumDocument(url: file)
            var report = ""
            for page in 0..<pdf.pageCount {
                let fonts = try pdf.fontUsage(onPage: page).sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }
                let text = KhmerTextRebuilder.rebuild(try pdf.characters(onPage: page)).text
                report += "=== p\(page + 1) layer=\(PDFiumService.layerQuality(text: text, fonts: try pdf.fontUsage(onPage: page))) "
                    + "\(PDFiumService.khmerLayerSignals(text)) fonts: \(fonts.joined(separator: " "))\n\(text.prefix(400))\n"
            }
            try report.write(to: out.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).layer.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Recognizes tmp/RealDocuments/*-ocr.pdf as the app does (Skip pages with usable text on) and writes each line
    /// with its confidence to tmp/ocr-bench/<doc>.ocr.txt.
    func testRecognizeRealDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RealDocuments")
        guard ProcessInfo.processInfo.environment["OCR_BENCH"] != nil,
              let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("Copy PDFs named *-ocr.pdf into the container tmp/RealDocuments and run with TEST_RUNNER_OCR_BENCH=1")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-bench")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        OCRWorker.shared.usesKhmerOCR = true
        for file in files where file.lastPathComponent.hasSuffix("-ocr.pdf") {
            let session = DocumentSession()
            await session.open(file)
            session.ocrSettings.skipPagesWithText = true
            session.ocrSettings.language = .khmerEnglish
            await session.startRecognition(Array(session.pages.indices), .en)?.value
            var report = ""
            for (index, ref) in session.pages.enumerated() {
                report += "=== p\(index + 1) \(session.ocrResults[ref.id] == nil ? "skipped" : "recognized")\n"
                for line in session.ocrResults[ref.id]?.lines ?? [] {
                    report += String(format: "[%3.0f] ", line.confidence) + line.text + "\n"
                }
            }
            report += OCRWorker.shared.routeLog.suffix(session.pageCount).joined(separator: "\n")
            try report.write(to: out.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).ocr.txt"), atomically: true, encoding: .utf8)
            await session.close()
        }
    }

    /// Re-reads each box KhmerOCR's detector found (tmp/ocr-bench/<doc>.kboxes.json, from Tools/ocr-eval) with Tesseract
    /// as a single line, in English and in Khmer + English, so per-box engine choice can be scored.
    func testBenchmarkTesseractOnKhmerOCRBoxes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TestDocuments")
        let bench = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-bench")
        guard ProcessInfo.processInfo.environment["OCR_BENCH"] != nil,
              FileManager.default.fileExists(atPath: bench.appendingPathComponent("01_khmer_community_notice.kboxes.json").path),
              let models = OCRModelSet.best.directory() else { throw XCTSkip("Run Tools/ocr-eval/kboxes.py first") }
        let english = try TesseractEngine(languages: "eng", models: models)
        let mixed = try TesseractEngine(languages: "khm+eng", models: models)
        for name in Self.documents {
            let stem = (name as NSString).lastPathComponent
            let file = bench.appendingPathComponent("\(stem).kboxes.json")
            guard var pages = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] else { continue }
            let pdf = try PDFiumDocument(url: root.appendingPathComponent("\(name).pdf"))
            for p in pages.indices {
                guard let image = pdf.renderForOCR(page: p, quarterTurns: 0, ppi: 300),
                      var lines = pages[p]["lines"] as? [[[String: Any]]] else { continue }
                for l in lines.indices {
                    for b in lines[l].indices {
                        let box = lines[l][b]
                        let rect = CGRect(x: (box["x1"] as! Int) - 4, y: (box["y1"] as! Int) - 4,
                                          width: (box["x2"] as! Int) - (box["x1"] as! Int) + 8, height: (box["y2"] as! Int) - (box["y1"] as! Int) + 8)
                            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
                        guard let crop = image.cropping(to: rect) else { continue }
                        let e = try? english.recognize(crop, ppi: 300, deadline: 5, singleLine: true)
                        let m = try? mixed.recognize(crop, ppi: 300, deadline: 5, singleLine: true)
                        lines[l][b]["t_eng"] = e?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        lines[l][b]["t_eng_conf"] = e?.meanConfidence ?? 0
                        lines[l][b]["t_mix"] = m?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        lines[l][b]["t_mix_conf"] = m?.meanConfidence ?? 0
                    }
                }
                pages[p]["lines"] = lines
            }
            try JSONSerialization.data(withJSONObject: pages).write(to: bench.appendingPathComponent("\(stem).kboxes.tess.json"))
        }
    }
}
