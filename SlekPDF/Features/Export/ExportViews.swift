import AppKit
import SwiftUI

/// An export being written (Figma 37 Exporting… toast).
struct ExportJob: Equatable {
    let fileName: String
    let total: Int
    var done = 0
    let cancel: CancelFlag

    static func == (a: ExportJob, b: ExportJob) -> Bool { a.fileName == b.fileName && a.total == b.total && a.done == b.done }
}

/// What 36 (already exists) and 14 (could not save) act on.
struct PendingExport {
    let indices: [Int]
    let url: URL
    var access: SaveDestination.Access?
}

private extension AppLanguage {
    func callAsFunction(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, self) }
}

// MARK: - Actions

extension DocumentSession {
    /// Where the export goes: Choose folder…, else the Preferences export folder, else asked now.
    func exportFolderAccess(_ appState: AppState) -> SaveDestination.Access? {
        if let folder = exportSettings.folder { return SaveDestination.Access(url: folder) {} }
        if let folder = appState.exportFolder, folder.startAccessingSecurityScopedResource() {
            return SaveDestination.Access(url: folder) { folder.stopAccessingSecurityScopedResource() }
        }
        return chooseExportFolder()
    }

    /// Choose folder… / Choose another folder… (kept for this window).
    @discardableResult
    func chooseExportFolder() -> SaveDestination.Access? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = exportSettings.folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        exportSettings.folder = url
        return SaveDestination.Access(url: url) {}
    }

    /// The output name with the format's extension.
    var exportFileName: String {
        let name = exportSettings.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? defaultExportFileName(for: exportSettings.format) : name
        let ext = exportSettings.format.fileExtension
        return (base as NSString).pathExtension.lowercased() == ext ? base : "\(base).\(ext)"
    }

    /// Export: asks 36 when the file exists, else writes it.
    func requestExport(_ language: AppLanguage, _ appState: AppState) {
        commitTextEditing()
        guard exportJob == nil, let indices = exportPageIndices, !indices.isEmpty,
              let access = exportFolderAccess(appState) else { return }
        let url = access.url.appendingPathComponent(exportFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            pendingExport = PendingExport(indices: indices, url: url, access: access)
            organizeDialog = .exportExists
            return
        }
        runExport(indices, to: url, access: access, language)
    }

    /// 36 Keep both: the first free “Name 2.ext”, “Name 3.ext”…
    static func freeURL(near url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var number = 2
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }

    /// Writes the export in the background with a progress toast (37); success shows 18, failure 14.
    @discardableResult
    func runExport(_ indices: [Int], to url: URL, access: SaveDestination.Access, _ language: AppLanguage) -> Task<Void, Never> {
        let flag = CancelFlag()
        let name = url.lastPathComponent
        exportJob = ExportJob(fileName: name, total: indices.count, cancel: flag)
        showExportProgress(language)
        let settings = exportSettings
        return Task { [weak self] in
            defer { access.release() }
            guard let self else { return }
            defer { self.exportJob = nil }
            let content = await self.exportPages(indices, includeAddedText: settings.includeAddedText) { done in
                self.exportJob?.done = done
                self.showExportProgress(language)
            }
            guard !flag.isCancelled else {
                self.toasts.dismiss()
                return
            }
            do {
                switch settings.format {
                case .word:
                    let document = ConvertedDocument(title: (name as NSString).deletingPathExtension, blocks: content.flatMap(\.blocks))
                    try DOCXWriter.data(for: document).write(to: url, options: .atomic)
                case .plainText:
                    try Data(ExportBuilder.plainText(pages: content).utf8).write(to: url, options: .atomic)
                case .searchablePDF:
                    let items = content.map { page -> (source: PDFiumService.PageSource, layer: Data?) in
                        let index = page.number - 1
                        let pdfPage = self.document?.page(at: index)
                        let layer = ExportTextLayer.pdfData(pageBox: pdfPage?.bounds(for: .mediaBox) ?? .zero, rotation: pdfPage?.rotation ?? 0,
                                                            ocrLines: page.ocrLines, textBoxes: page.textBoxes)
                        return (self.editedPageSources([index])[0], layer)
                    }
                    try await PDFiumService.shared.writeSearchablePDF(items, to: url)
                }
                self.toasts.show(.success, CopyCatalog.shared.format(.fmtExportFinishedFile, language, name),
                                 action: DSInlineAction(title: language(.showInFinder)) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            } catch {
                self.toasts.dismiss()
                self.pendingExport = PendingExport(indices: indices, url: url)
                self.organizeDialog = .exportFailed
            }
        }
    }

    private func showExportProgress(_ language: AppLanguage) {
        guard let job = exportJob else { return }
        toasts.show(.progress, CopyCatalog.shared.format(.fmtExportingFilePageNOfM, language, job.fileName, min(job.done + 1, job.total), job.total),
                    action: DSInlineAction(title: language(.cancel)) { [weak self] in self?.exportJob?.cancel.cancel() })
    }
}

// MARK: - Inspector (Export Options 132:409)

struct ExportInspector: View {
    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var appState: AppState
    @Environment(\.appLanguage) private var language

    var body: some View {
        let format = session.exportSettings.format
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s12) {
                HStack {
                    DSLabel(.export, style: .heading).foregroundColor(DSColor.textPrimary)
                    Spacer()
                    DSIconButton(.right, size: 24, iconSize: 14) { session.setInspectorVisible(false) }
                        .dsTooltip(.hideInspector, shortcut: "⌥⌘I")
                }
                DSDropdown(label: language(.fileFormat), selection: formatBinding,
                           options: ExportFormat.allCases.map { (value: $0, title: language($0.title)) })
                DSDropdown(label: language(.pagesToInclude), selection: $session.exportSettings.scope, options: [
                    (value: OCRSettings.Scope.all, title: language(.allPages)),
                    (value: .current, title: language(.currentPage)),
                    (value: .custom, title: language(.customRange)),
                ])
                if session.exportSettings.scope == .custom {
                    DSTextField(label: .customRange, text: $session.exportSettings.customRange, errorText: rangeError, autofocus: false)
                }
                if format == .searchablePDF {
                    // The page image is always kept in this version: the delivery copy never redraws the source.
                    DSCheckbox(label: .keepOriginalPageImages, isOn: .constant(true)).disabled(true)
                }
                DSCheckbox(label: .includeAddedText, isOn: $session.exportSettings.includeAddedText)
                DSLabel(.reviewedOCRCorrectionsAreIncludedC, style: .caption).foregroundColor(DSColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                DSDivider()
                DSTextField(label: outputNameLabel(format), text: $session.exportSettings.fileName, autofocus: false,
                            onSubmit: { session.requestExport(language, appState) })
                DSButton(.chooseFolder, icon: .folderOpen, fullWidth: true) { session.chooseExportFolder() }
                Text(destination).dsText(.caption).foregroundColor(DSColor.textTertiary)
                DSButton(exportLabel(format), icon: .download, style: .primary, fullWidth: true) { session.requestExport(language, appState) }
                    .disabled(session.exportJob != nil || (session.exportPageIndices?.isEmpty ?? true))
                DSLabel(.exportCreatesANewFileTheSourcePD, style: .caption).foregroundColor(DSColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DSSpace.s16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DSColor.backgroundSurface)
        .onAppear {
            if session.exportSettings.fileName.isEmpty { session.exportSettings.fileName = session.defaultExportFileName(for: format) }
        }
    }

    /// Changing the format resets the name to that format's default (keeping a name the person typed, re-extended).
    private var formatBinding: Binding<ExportFormat> {
        Binding(get: { session.exportSettings.format }, set: { format in
            let old = session.exportSettings
            session.exportSettings.format = format
            let typed = (old.fileName as NSString).deletingPathExtension
            let defaultBase = (session.defaultExportFileName(for: old.format) as NSString).deletingPathExtension
            session.exportSettings.fileName = typed.isEmpty || typed == defaultBase
                ? session.defaultExportFileName(for: format) : "\(typed).\(format.fileExtension)"
        })
    }

    private var rangeError: String? {
        let text = session.exportSettings.customRange.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, session.exportPageIndices == nil else { return nil }
        return CopyCatalog.shared.count(.fmtDocumentHasNPagesUsePagesLike, language, session.pageCount)
    }

    private var destination: String {
        guard let folder = session.exportSettings.folder ?? appState.exportFolder else { return language(.destinationNotSelected) }
        return CopyCatalog.shared.format(.fmtDestinationFolder, language, folder.lastPathComponent)
    }

    private func outputNameLabel(_ format: ExportFormat) -> CopyKey {
        switch format {
        case .word: .wordOutputName
        case .searchablePDF: .pdfOutputName
        case .plainText: .textOutputName
        }
    }

    private func exportLabel(_ format: ExportFormat) -> CopyKey {
        switch format {
        case .word: .exportWordFile
        case .searchablePDF: .exportSearchablePDF
        case .plainText: .exportTextUTF8
        }
    }
}

// MARK: - Canvas (Source & output preview)

struct ExportCanvas: View {
    @EnvironmentObject private var session: DocumentSession

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DSSpace.s16) {
                DSLabel(.sourceOutputPreview, style: .caption).foregroundColor(DSColor.textSecondary)
                    .padding(.top, DSSpace.s24)
                HStack(alignment: .top, spacing: DSSpace.s24) {
                    VStack(alignment: .leading, spacing: DSSpace.s8) {
                        DSLabel(.sourcePage, style: .caption).foregroundColor(DSColor.textSecondary)
                        OCRSourcePage(showsRegions: false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    VStack(alignment: .leading, spacing: DSSpace.s8) {
                        DSLabel(.outputPreview, style: .caption).foregroundColor(DSColor.textSecondary)
                        ExportPreviewCard()
                    }
                    .frame(width: 396)
                }
                .padding(.top, DSSpace.s16)
            }
            .padding(.horizontal, DSSpace.s24)
            .padding(.bottom, DSSpace.s24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            PageNavigationPill().padding(.top, DSSpace.s12)
        }
        .background(DSColor.backgroundCanvas)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// Figma Export Preview (133:399) with Review Issues (133:44).
struct ExportPreviewCard: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var content: [ExportPage] = []

    private struct PreviewKey: Equatable {
        let revision: Int
        let pages: [Int]?
        let include: Bool
    }

    var body: some View {
        let format = session.exportSettings.format
        let issues = self.issues
        VStack(alignment: .leading, spacing: DSSpace.s12) {
            HStack {
                Text(language(previewTitle(format))).dsText(.heading).foregroundColor(DSColor.textPrimary)
                Spacer()
                badge(format)
            }
            preview(format)
            DSDivider()
            Text(CopyCatalog.shared.format(.fmtReviewIssuesN, language, issues.count)).dsText(.label).foregroundColor(DSColor.textPrimary)
            ForEach(Array(issues.enumerated()), id: \.offset) { index, issue in
                if index > 0 { DSDivider() }
                ExportIssueRow(issue: issue)
            }
            DSButton(.reviewOCR, icon: .textRecognition, size: .small) { session.workspace = .khmerOCR }
        }
        .padding(DSSpace.s16)
        .background(RoundedRectangle(cornerRadius: DSRadius.md).fill(DSColor.backgroundSurface))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.md).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .task(id: PreviewKey(revision: session.contentRevision, pages: session.exportPageIndices, include: session.exportSettings.includeAddedText)) {
            content = await session.exportPages(session.exportPageIndices ?? [], includeAddedText: session.exportSettings.includeAddedText)
        }
    }

    private func previewTitle(_ format: ExportFormat) -> CopyKey {
        switch format {
        case .word: .wordPreview
        case .searchablePDF: .searchablePDFPreview
        case .plainText: .textPreviewUTF8
        }
    }

    @ViewBuilder private func badge(_ format: ExportFormat) -> some View {
        if format == .searchablePDF {
            if !content.isEmpty, content.allSatisfy(\.hasText) { DSBadge(label: language(.textLayerAligned), tone: .success) }
        } else {
            DSBadge(label: language(.editable))
        }
    }

    @ViewBuilder private func preview(_ format: ExportFormat) -> some View {
        switch format {
        case .word:
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.s8) {
                    ForEach(Array(content.flatMap(\.blocks).prefix(40).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case let .heading(level, text):
                            Text(text).dsText(level == 1 ? .title : .heading).foregroundColor(DSColor.textOnPage)
                        case let .paragraph(runs):
                            Text(runs.map(\.text).joined()).dsText(.body).foregroundColor(DSColor.textOnPage)
                        case .table:
                            EmptyView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSSpace.s24)
            }
            .frame(height: 260)
            .background(DSColor.backgroundPage)
            .overlay(Rectangle().strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        case .searchablePDF:
            if let page = session.document?.page(at: session.currentPageIndex) {
                Image(nsImage: page.thumbnail(of: CGSize(width: 600, height: 600), for: .mediaBox))
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity).frame(height: 220)
                    .padding(DSSpace.s12)
                    .background(RoundedRectangle(cornerRadius: DSRadius.md).fill(DSColor.backgroundHover))
            }
            DSLabel(content.allSatisfy(\.hasText) ? .selectSearchAndCopyNowWorkOnReco : .onlyThePageImagesAreKeptThereIsNoTextToSearchYet,
                    style: .caption)
                .foregroundColor(DSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
        case .plainText:
            ScrollView {
                Text(ExportBuilder.plainText(pages: content).prefix(3000))
                    .dsText(.body).foregroundColor(DSColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(DSSpace.s12)
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: DSRadius.md).fill(DSColor.backgroundHover))
            DSLabel(.pageBreaksAreMarkedTablesBecomeTa, style: .caption).foregroundColor(DSColor.textSecondary)
        }
    }

    /// What needs a look before exporting: pages with no text, and uncertain OCR lines nobody reviewed.
    private var issues: [ExportIssue] {
        var list: [ExportIssue] = []
        let empty = content.filter { !$0.hasText }.map(\.number)
        if !empty.isEmpty {
            let numbers = empty.map { language.number($0) }.joined(separator: ", ")
            list.append(ExportIssue(tone: .warning, title: language(.pagesWithoutText),
                                    detail: CopyCatalog.shared.variant(.fmtPagesNHaveNoText, language, singular: empty.count == 1, numbers),
                                    show: { session.workspace = .khmerOCR }))
        }
        let indices = session.exportPageIndices ?? []
        let uncertain = indices.filter { session.pages.indices.contains($0) }
            .compactMap { session.ocrResults[session.pages[$0].id] }
            .flatMap(\.lines).filter { $0.isUncertain && !$0.reviewed }.count
        if uncertain > 0 {
            list.append(ExportIssue(tone: .info, title: language(.uncertainOCRText),
                                    detail: CopyCatalog.shared.count(.fmtNUncertainLinesNotReviewed, language, uncertain),
                                    show: {
                                        session.ocrReviewFilter = .uncertain
                                        session.workspace = .khmerOCR
                                    }))
        }
        return list
    }
}

struct ExportIssue {
    enum Tone { case warning, info }
    let tone: Tone
    let title: String
    let detail: String
    let show: () -> Void
}

/// Figma Review Issue (133:44): icon, title, detail, Show.
struct ExportIssueRow: View {
    let issue: ExportIssue

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.s8) {
            (issue.tone == .warning ? DSIcon.attention : DSIcon.info).image(size: 16)
                .foregroundColor(issue.tone == .warning ? DSColor.statusWarning : DSColor.textSecondary)
                .padding(.top, DSSpace.s2)
            VStack(alignment: .leading, spacing: 0) {
                Text(issue.title).dsText(.label).foregroundColor(DSColor.textPrimary)
                Text(issue.detail).dsText(.caption).foregroundColor(DSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DSButton(.show, style: .plain, size: .small, action: issue.show)
        }
    }
}

// MARK: - Dialogs 36 and 14

/// Figma 36 “Report.xlsx” already exists: Cancel · Keep both · Replace (destructive).
struct ExportExistsDialog: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        let url = session.pendingExport?.url
        DSDialog(icon: .save, iconColor: DSColor.accentDefault,
                 title: CopyCatalog.shared.format(.fmtFileAlreadyExists, language, url?.lastPathComponent ?? ""),
                 message: CopyCatalog.shared.format(.fmtAFileWithThisNameIsAlreadyInFolder, language,
                                                    url?.deletingLastPathComponent().lastPathComponent ?? ""),
                 cancel: .keepBoth, confirm: .replace, confirmStyle: .destructive,
                 secondary: (title: .cancel, action: {
                     session.pendingExport?.access?.release()
                     session.pendingExport = nil
                     session.organizeDialog = nil
                 }), secondaryCancels: true,
                 onCancel: { finish(replacing: false) },
                 onConfirm: { finish(replacing: true) })
    }

    private func finish(replacing: Bool) {
        guard let pending = session.pendingExport, let access = pending.access else { return }
        session.pendingExport = nil
        session.organizeDialog = nil
        session.runExport(pending.indices, to: replacing ? pending.url : DocumentSession.freeURL(near: pending.url), access: access, language)
    }
}

/// Figma 14 Could not save the export: Cancel · Choose another folder….
struct ExportFailedDialog: View {
    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var appState: AppState
    @Environment(\.appLanguage) private var language

    var body: some View {
        let url = session.pendingExport?.url
        DSDialog(icon: .attention, iconColor: DSColor.statusDanger,
                 title: language(.couldNotSaveTheExport),
                 message: CopyCatalog.shared.format(.fmtFileCouldNotBeCreatedInFolder, language,
                                                    url?.deletingLastPathComponent().lastPathComponent ?? "", url?.lastPathComponent ?? ""),
                 cancel: .cancel, confirm: .chooseAnotherFolder,
                 onCancel: {
                     session.pendingExport = nil
                     session.organizeDialog = nil
                 },
                 onConfirm: {
                     session.pendingExport = nil
                     session.organizeDialog = nil
                     if session.chooseExportFolder() != nil { session.requestExport(language, appState) }
                 })
    }
}
