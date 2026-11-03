import Foundation

/// Figma Recognition Settings (129:231).
struct OCRSettings: Equatable {
    enum Scope: Hashable { case all, current, custom }

    var language: OCRLanguage = .khmerEnglish
    var scope: Scope = .all
    var customRange = ""
    var skipPagesWithText = true
}

/// A recognition run (Figma 12 Recognizing text…, and the inspector's Running state).
struct OCRJob: Equatable {
    /// Page indices when the run started.
    let pages: [Int]
    var finished = 0
    /// Page number (1-based) being recognized now.
    var currentNumber: Int?
    let startedAt = Date()

    var fraction: Double { pages.isEmpty ? 1 : Double(finished) / Double(pages.count) }

    /// Minutes left, from the average time per finished page; nil until a page has finished.
    func minutesLeft(now: Date = Date()) -> Int? {
        guard finished > 0 else { return nil }
        let perPage = now.timeIntervalSince(startedAt) / Double(finished)
        return Int((perPage * Double(pages.count - finished) / 60).rounded(.up))
    }
}

extension OCRLanguage {
    /// Tesseract model names.
    var tesseract: String {
        switch self {
        case .khmer: "khm"
        case .khmerEnglish: "khm+eng"
        case .english: "eng"
        }
    }

    /// As in Preferences: language names in their own script.
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .khmer: "ខ្មែរ"
        case .khmerEnglish: CopyCatalog.shared.string(.khmerEnglish, language)
        case .english: "English"
        }
    }
}

extension DocumentSession {
    /// Resolution pages are rendered at for OCR (spike 02: best + Sauvola at 300 dpi).
    static let ocrPPI = 300

    /// The pages the settings select (current indices), or nil for an invalid custom range (41).
    var ocrPageIndices: [Int]? {
        switch ocrSettings.scope {
        case .all: return Array(pages.indices)
        case .current: return pages.indices.contains(currentPageIndex) ? [currentPageIndex] : nil
        case .custom:
            guard let groups = PageRanges.parse(ocrSettings.customRange, pageCount: pages.count) else { return nil }
            var seen = Set<Int>()
            return groups.flatMap { $0 }.filter { seen.insert($0).inserted }
        }
    }

    /// Recognize text: asks first (39) when the pages have corrections or reviews that would be replaced.
    func requestRecognition(_ language: AppLanguage) {
        commitTextEditing()
        guard ocrJob == nil, let indices = ocrPageIndices, !indices.isEmpty else { return }
        if indices.contains(where: { ocrResults[pages[$0].id]?.hasReviewWork == true }) {
            pendingOCRPages = indices
            organizeDialog = .recognizeAgain
            return
        }
        startRecognition(indices, language)
    }

    /// Pages among `pendingOCRPages` whose review work would be replaced (39's count).
    var reviewedPendingPageCount: Int {
        pendingOCRPages.filter { pages.indices.contains($0) && ocrResults[pages[$0].id]?.hasReviewWork == true }.count
    }

    /// Runs OCR page by page in the background. Each finished page is kept (Cancel keeps them); a page that fails or
    /// times out is skipped. Results follow the PageRef, so reordering pages meanwhile is fine.
    /// Returns the task so tests can wait for it.
    @discardableResult
    func startRecognition(_ indices: [Int], _ language: AppLanguage) -> Task<Void, Never>? {
        guard let id = pdfiumID, ocrJob == nil, !indices.isEmpty else { return nil }
        let flag = CancelFlag()
        ocrCancel = flag
        ocrJob = OCRJob(pages: indices)
        organizeDialog = .recognizing
        let refs = indices.filter { pages.indices.contains($0) }.map { pages[$0] }
        let languages = ocrSettings.language.tesseract
        let skipText = ocrSettings.skipPagesWithText
        let ppi = Self.ocrPPI
        return Task { [weak self] in
            var recognized = 0
            for ref in refs {
                guard !flag.isCancelled, let self else { break }
                self.ocrJob?.currentNumber = (self.pages.firstIndex { $0.id == ref.id } ?? 0) + 1
                defer { self.ocrJob?.finished += 1 }
                if skipText, await PDFiumService.shared.hasUsableText(id, page: ref.source) { continue }
                guard let image = await PDFiumService.shared.renderForOCR(id, page: ref.source, quarterTurns: ref.quarterTurns,
                                                                          ppi: CGFloat(ppi)) else { continue }
                guard let result = try? await OCRWorker.shared.recognize(image, ppi: ppi, languages: languages,
                                                                          isCancelled: { flag.isCancelled }) else { continue }
                let rects = await PDFiumService.shared.pageRects(id, result.lines.map(\.pixelRect), page: ref.source,
                                                                 quarterTurns: ref.quarterTurns, ppi: CGFloat(ppi))
                let lines = zip(result.lines, rects).map { OCRLine(bounds: $1, text: $0.text, confidence: $0.confidence) }
                guard !flag.isCancelled, self.pages.contains(where: { $0.id == ref.id }) else { continue }
                self.setOCR(OCRPage(lines: lines, languages: languages, date: Date(), quarterTurns: ref.quarterTurns), for: ref.id)
                if !lines.isEmpty { recognized += 1 }
            }
            self?.finishRecognition(cancelled: flag.isCancelled, recognizedPages: recognized, language)
        }
    }

    /// Cancel (12 or the inspector's progress bar): stops during the current page; finished pages are kept.
    func cancelRecognition() {
        ocrCancel?.cancel()
    }

    /// Run in background (12): hides the dialog; the inspector keeps showing progress.
    func runRecognitionInBackground() {
        if organizeDialog == .recognizing { organizeDialog = nil }
    }

    private func finishRecognition(cancelled: Bool, recognizedPages: Int, _ language: AppLanguage) {
        ocrJob = nil
        ocrCancel = nil
        if organizeDialog == .recognizing { organizeDialog = nil }
        if cancelled {
            toasts.show(.default, CopyCatalog.shared.string(.recognitionStoppedFinishedPagesAreKept, language))
        } else if recognizedPages == 0 {
            toasts.show(.default, CopyCatalog.shared.string(.noTextWasFoundOnThesePages, language))
        } else {
            toasts.show(.success, CopyCatalog.shared.count(.fmtRecognizedTextOnNPages, language, recognizedPages))
        }
    }
}
