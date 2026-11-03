import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

private extension AppLanguage {
    func callAsFunction(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, self) }
}

/// Document commands that are not tied to one workspace: Insert Pages from File…, Save a copy…, and the Read tools
/// (Select/copy text, Rotate view).
extension DocumentSession {
    // MARK: Insert Pages from File… (Organize menu)

    func requestInsertPages(_ language: AppLanguage) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await !insertPages(from: url) {
                toasts.show(.error, CopyCatalog.shared.format(.fmtFileCouldNotBeOpened, language, url.lastPathComponent))
            }
        }
    }

    /// Inserts every page of `url` after the selected pages (else at the end), selected and undoable. The other file
    /// is only read; saved work copies its pages like the document's own.
    @discardableResult
    func insertPages(from url: URL) async -> Bool {
        guard document != nil, let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { return false }
        if insertedDocuments[url] == nil {
            guard let opened = try? await PDFiumService.shared.open(url: url), opened.pageCount == pdf.pageCount else { return false }
            let pdfPages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }
            insertedDocuments[url] = InsertedDocument(id: opened.id, pages: pdfPages, rotations: pdfPages.map(\.rotation))
        }
        let position = selectedPageIndices.last.map { $0 + 1 } ?? pages.count
        let new = (0..<pdf.pageCount).map { PageRef(source: $0, file: url) }
        setPages(Array(pages[..<position]) + new + Array(pages[position...]), selecting: Set(new.map(\.id)))
        return true
    }

    // MARK: Save a copy… (File menu)

    /// Writes the editable work to a file the person picks; the window keeps working on its own work file.
    func requestSaveACopy(_ language: AppLanguage) {
        commitTextEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedWorkName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await PDFiumService.shared.writePDF(editedPageSources(), to: url)
                showSaved([url], language)
            } catch {
                toasts.show(.error, error.localizedDescription)
            }
        }
    }

    // MARK: Read tools (Inspector 159:554)

    /// Select/copy text: the current page's readable text (reviewed OCR on recognized pages) on the clipboard.
    func copyPageText(_ language: AppLanguage) async {
        guard pages.indices.contains(currentPageIndex), let id = documentID(for: pages[currentPageIndex]) else { return }
        let ref = pages[currentPageIndex]
        let text: String
        if let ocr = ocrResults[ref.id], !ocr.lines.isEmpty {
            text = ocr.text
        } else {
            text = await PDFiumService.shared.textLines(id, page: ref.source).map(\.text).joined(separator: "\n")
        }
        guard !text.isEmpty else {
            let unreadable = await PDFiumService.shared.textLayer(id, page: ref.source) == .unreadable
            toasts.show(.default, language(unreadable ? .recognizeTextToEnableSearchingAndC : .noTextOnThisPageToCopy))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toasts.show(.success, CopyCatalog.shared.format(.fmtCopiedTheTextOfPageN, language, currentPageIndex + 1))
    }

    /// Rotate view: turns the current page 90° clockwise on screen only.
    func rotateView() {
        guard pages.indices.contains(currentPageIndex) else { return }
        let id = pages[currentPageIndex].id
        viewTurns[id] = ((viewTurns[id] ?? 0) + 1) % 4
    }
}

// MARK: - 15 Recovered unfinished work

/// Figma 15: Discard · Not now · Open recovered work, with the recovered file's name and edits.
struct RecoveredWorkDialog: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        let entry = session.recoveryOffer
        DSDialog(icon: .refresh, iconColor: DSColor.statusWarning,
                 title: language(.recoveredUnfinishedWork), message: language(.slekPDFClosedUnexpectedlyTheseEdits),
                 cancel: .notNow, confirm: .openRecoveredWork,
                 secondary: (title: .discard, action: {
                     if let entry { session.recoveryStore.remove(entry.id) }
                     close()
                 }),
                 onCancel: close,
                 onConfirm: {
                     close()
                     if let entry { Task { await session.openRecovered(entry) } }
                 }) {
            if let entry {
                HStack(spacing: DSSpace.s12) {
                    DSIcon.fileTypePdf.image(size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.fileName).dsText(.label).foregroundColor(DSColor.textPrimary).lineLimit(1)
                        Text(CopyCatalog.shared.count(.fmtNEditsLastChangeTime, language, entry.changes, Self.time(entry.date, language)))
                            .dsText(.caption).foregroundColor(DSColor.textTertiary)
                    }
                }
                .padding(.top, DSSpace.s8)
            }
        }
    }

    private func close() {
        session.recoveryOffer = nil
        session.organizeDialog = nil
    }

    /// “today 10:24”, else the date and time (the interface language's digits).
    static func time(_ date: Date, _ language: AppLanguage) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return CopyCatalog.shared.format(.fmtTodayTime, language, language.digits(formatter.string(from: date)))
        }
        formatter.dateFormat = "d/M/yyyy HH:mm"
        return language.digits(formatter.string(from: date))
    }
}
