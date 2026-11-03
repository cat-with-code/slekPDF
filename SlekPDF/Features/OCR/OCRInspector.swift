import SwiftUI

/// Figma Recognition Settings (129:231), the Khmer OCR inspector: language, page scope (custom range with the 41 error),
/// deskew and skip-text options, Recognize text — or, while running, a progress bar with Cancel and locked settings.
struct OCRInspector: View {
    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var appState: AppState
    @Environment(\.appLanguage) private var language
    @State private var appliedDefault = false

    var body: some View {
        let isRunning = session.ocrJob != nil
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s12) {
                HStack {
                    DSLabel(.recognitionSettings, style: .heading).foregroundColor(DSColor.textPrimary)
                    Spacer()
                    DSIconButton(.right, size: 24, iconSize: 14) { session.setInspectorVisible(false) }
                        .dsTooltip(.hideInspector, shortcut: "⌥⌘I")
                }
                Group {
                    DSDropdown(label: string(.language), selection: $session.ocrSettings.language,
                               options: OCRLanguage.allCases.map { (value: $0, title: $0.title(language)) })
                    DSDropdown(label: string(.pageScope), selection: $session.ocrSettings.scope, options: [
                        (value: OCRSettings.Scope.all, title: string(.allPages)),
                        (value: .current, title: string(.currentPage)),
                        (value: .custom, title: string(.customRange)),
                    ])
                    if session.ocrSettings.scope == .custom {
                        DSTextField(label: .customRange, text: $session.ocrSettings.customRange, errorText: rangeError, autofocus: false,
                                    onSubmit: { session.requestRecognition(language) })
                    }
                    // Needs Tesseract's orientation model (osd), which is not bundled yet: shown, but honestly off.
                    DSCheckbox(label: .correctOrientationDeskew, isOn: .constant(false))
                        .disabled(true)
                        .dsTooltip(.deskewNeedsAnOrientationModelThatIsNotIncludedYet)
                    DSCheckbox(label: .skipPagesWithUsableText, isOn: $session.ocrSettings.skipPagesWithText)
                }
                .disabled(isRunning)
                if let job = session.ocrJob {
                    RecognitionProgress(job: job, showsCancel: true)
                } else {
                    DSButton(.recognizeText, icon: .textRecognition, style: .primary, fullWidth: true) { session.requestRecognition(language) }
                        .disabled(session.ocrPageIndices?.isEmpty ?? true)
                        .dsTooltip(.recognizeText, shortcut: ShortcutStore.shared.shortcut(.recognizeText)?.display)
                }
                DSLabel(.runsOnThisMacNothingIsUploadedE, style: .caption).foregroundColor(DSColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                DSDivider()
                DSButton(.reviewExportOptions, fullWidth: true) { session.workspace = .export }
                DSLabel(.txtSearchablePDFWordOrExcel, style: .caption).foregroundColor(DSColor.textTertiary)
            }
            .padding(DSSpace.s16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DSColor.backgroundSurface)
        .onAppear {
            // Start from the Preferences default once per window; later choices here are kept.
            guard !appliedDefault else { return }
            appliedDefault = true
            if session.ocrResults.isEmpty, session.ocrJob == nil { session.ocrSettings.language = appState.ocrLanguage }
        }
    }

    /// Figma 41: shown once something is typed that is not a valid range for this document.
    private var rangeError: String? {
        let text = session.ocrSettings.customRange.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, session.ocrPageIndices == nil else { return nil }
        return CopyCatalog.shared.count(.fmtDocumentHasNPagesUsePagesLike, language, session.pageCount)
    }

    private func string(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, language) }
}

/// Figma Progress Bar (100:74) for a recognition run: "Recognizing page 2 of 5" · "40% · about 1 minute left".
struct RecognitionProgress: View {
    let job: OCRJob
    var showsCancel: Bool
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        DSProgressBar(label: CopyCatalog.shared.format(.fmtRecognizingPageNOfM, language,
                                                       min(job.finished + 1, job.pages.count), job.pages.count),
                      detail: detail, state: .inProgress(job.fraction),
                      onCancel: showsCancel ? { session.cancelRecognition() } : nil)
    }

    private var detail: String {
        let percent = Int((job.fraction * 100).rounded())
        guard let minutes = job.minutesLeft() else { return "\(language.number(percent))%" }
        if minutes < 1 { return CopyCatalog.shared.format(.fmtNLessThanAMinuteLeft, language, percent) }
        return CopyCatalog.shared.count(.fmtNMinutesLeft, language, minutes, percent)
    }
}

/// Figma 12 Recognizing text…: progress over the window; Run in background hides it, Cancel stops (finished pages stay).
struct RecognizingDialog: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        let job = session.ocrJob
        let pages = job?.pages ?? []
        DSDialog(icon: .textRecognition, iconColor: DSColor.accentDefault,
                 title: CopyCatalog.shared.string(.recognizingText, language),
                 message: CopyCatalog.shared.variant(.fmtLanguagePagesKeepReading, language, singular: pages.count == 1,
                                                     session.ocrSettings.language.title(language), Self.pageList(pages, language)),
                 cancel: .cancel, confirm: nil,
                 secondary: (title: .runInBackground, action: { session.runRecognitionInBackground() }),
                 onCancel: { session.cancelRecognition() }, onConfirm: {}) {
            if let job { RecognitionProgress(job: job, showsCancel: false).padding(.top, DSSpace.s6) }
        }
    }

    /// "1–5", "1–3, 5" (page numbers, the interface language's digits).
    static func pageList(_ indices: [Int], _ language: AppLanguage) -> String {
        var parts: [String] = []
        var start: Int?, previous: Int?
        func close() {
            guard let first = start, let last = previous else { return }
            parts.append(first == last ? language.number(first + 1) : "\(language.number(first + 1))–\(language.number(last + 1))")
        }
        for index in indices.sorted() {
            if let last = previous, index == last + 1 { previous = index; continue }
            close()
            start = index
            previous = index
        }
        close()
        return parts.joined(separator: ", ")
    }
}

/// Figma 39 Recognize these pages again?: Cancel · Save work first · Recognize again (destructive).
struct RecognizeAgainDialog: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        DSDialog(icon: .save, iconColor: DSColor.accentDefault,
                 title: CopyCatalog.shared.string(.recognizeThesePagesAgain, language),
                 message: CopyCatalog.shared.count(.fmtNPagesHaveReviewedCorrections, language, session.reviewedPendingPageCount),
                 cancel: .saveWorkFirst, confirm: .recognizeAgain, confirmStyle: .destructive,
                 secondary: (title: .cancel, action: { session.organizeDialog = nil }), secondaryCancels: true,
                 onCancel: {
                     session.organizeDialog = nil
                     session.requestSaveWork(language)
                 },
                 onConfirm: {
                     session.organizeDialog = nil
                     session.startRecognition(session.pendingOCRPages, language)
                 })
    }
}
