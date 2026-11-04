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
    /// Word + Excel: the workbook (36 checks both names; 38 retries only this one).
    var excelURL: URL?
    /// 38: the Word file that was saved.
    var wordURL: URL?
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

    /// Word + Excel: the workbook's name with .xlsx.
    var exportExcelFileName: String {
        let name = exportSettings.excelFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? defaultExcelFileName : name
        return (base as NSString).pathExtension.lowercased() == "xlsx" ? base : "\(base).xlsx"
    }

    /// Export: Excel needs tables (17); asks 36 when a file exists, else writes.
    func requestExport(_ language: AppLanguage, _ appState: AppState) {
        commitTextEditing()
        guard exportJob == nil, let indices = exportPageIndices, !indices.isEmpty else { return }
        let format = exportSettings.format
        if format.writesExcel, !exportTablesDetected {
            Task { [weak self] in
                await self?.detectExportTables()
                self?.requestExport(language, appState)
            }
            return
        }
        if format.writesExcel, includedExportTables.isEmpty {
            organizeDialog = .noTables
            return
        }
        guard let access = exportFolderAccess(appState) else { return }
        let url = access.url.appendingPathComponent(exportFileName)
        let excelURL = format == .wordExcel ? access.url.appendingPathComponent(exportExcelFileName) : nil
        let clash = [url, excelURL].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        if let clash {
            pendingExport = PendingExport(indices: indices, url: clash == url ? url : clash, access: access, excelURL: excelURL, wordURL: url)
            organizeDialog = .exportExists
            return
        }
        runExport(indices, to: url, excelURL: excelURL, access: access, language)
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
    func runExport(_ indices: [Int], to url: URL, excelURL: URL? = nil, only: ExportFormat? = nil,
                   access: SaveDestination.Access, _ language: AppLanguage) -> Task<Void, Never> {
        let flag = CancelFlag()
        let name = url.lastPathComponent
        exportJob = ExportJob(fileName: name, total: indices.count, cancel: flag)
        showExportProgress(language)
        var settings = exportSettings
        if let only { settings.format = only }
        let tables = settings.format == .searchablePDF ? [] : includedExportTables
        let sheets = convertedExportTables(language)
        return Task { [weak self] in
            defer { access.release() }
            guard let self else { return }
            defer { self.exportJob = nil }
            let content = await self.exportPages(indices, includeAddedText: settings.includeAddedText, tables: tables, language: language) { done in
                self.exportJob?.done = done
                self.showExportProgress(language)
            }
            guard !flag.isCancelled else {
                self.toasts.dismiss()
                return
            }
            do {
                switch settings.format {
                case .word, .wordExcel:
                    let document = ConvertedDocument(title: (name as NSString).deletingPathExtension, blocks: content.flatMap(\.blocks))
                    try DOCXWriter.data(for: document).write(to: url, options: .atomic)
                    if settings.format == .wordExcel, let excelURL {
                        do {
                            try XLSXWriter.data(for: sheets).write(to: excelURL, options: .atomic)
                        } catch {
                            // 38: the Word file is kept; only the workbook is retried.
                            self.toasts.dismiss()
                            self.pendingExport = PendingExport(indices: indices, url: excelURL, wordURL: url)
                            self.organizeDialog = .excelFailed
                            return
                        }
                    }
                case .excel:
                    try XLSXWriter.data(for: sheets).write(to: url, options: .atomic)
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

/// Figma Export Panel (572:465): Format as a list (icon, name, one-line description; the suggested one is marked),
/// Pages and options, file name and Save to (folder · Change…), then the review issues and the Export button at the
/// bottom with the safety note. The canvas shows the output preview (ExportCanvas).
struct ExportInspector: View {
    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var appState: AppState
    @Environment(\.appLanguage) private var language

    var body: some View {
        let format = session.exportSettings.format
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.s16) {
                    HStack {
                        DSLabel(.export, style: .heading).foregroundColor(DSColor.textPrimary)
                        Spacer()
                        DSIconButton(.right, size: 24, iconSize: 14) { session.setInspectorVisible(false) }
                            .dsTooltip(.hideInspector, shortcut: "⌥⌘I")
                    }
                    VStack(alignment: .leading, spacing: DSSpace.s6) {
                        DSLabel(.format, style: .labelSmall).foregroundColor(DSColor.textSecondary)
                        ForEach(ExportFormat.allCases, id: \.self) { option in
                            FormatRow(format: option, isSelected: option == format, isSuggested: option == suggestion) {
                                formatBinding.wrappedValue = option
                            }
                        }
                        if format == .searchablePDF {
                            DSLabel(session.exportPreview.allSatisfy(\.hasText) ? .selectSearchAndCopyNowWorkOnReco
                                    : .onlyThePageImagesAreKeptThereIsNoTextToSearchYet, style: .caption)
                                .foregroundColor(DSColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    DSDivider()
                    options(format)
                    DSDivider()
                    VStack(alignment: .leading, spacing: DSSpace.s12) {
                        DSTextField(label: outputNameLabel(format), text: $session.exportSettings.fileName, autofocus: false,
                                    onSubmit: { session.requestExport(language, appState) })
                        if format == .wordExcel {
                            DSTextField(label: .excelOutputName, text: $session.exportSettings.excelFileName, autofocus: false,
                                        onSubmit: { session.requestExport(language, appState) })
                        }
                        saveTo
                    }
                    Spacer(minLength: 0)
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in ExportIssueRow(issue: issue) }
                    VStack(alignment: .leading, spacing: DSSpace.s8) {
                        DSButton(exportLabel(format), icon: .download, style: .primary, fullWidth: true) { session.requestExport(language, appState) }
                            .disabled(session.exportJob != nil || (session.exportPageIndices?.isEmpty ?? true))
                        DSLabel(.exportCreatesANewFileTheSourcePD, style: .caption).foregroundColor(DSColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DSSpace.s16)
                // The Export button sits at the bottom when everything fits.
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DSColor.backgroundSurface)
        .onAppear {
            if session.exportSettings.fileName.isEmpty { session.exportSettings.fileName = session.defaultExportFileName(for: format) }
            if session.exportSettings.excelFileName.isEmpty { session.exportSettings.excelFileName = session.defaultExcelFileName }
        }
    }

    @ViewBuilder private func options(_ format: ExportFormat) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.s12) {
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
            if format.writesExcel {
                ForEach(Array(tablesInScope.enumerated()), id: \.element.id) { number, table in
                    DSCheckbox(text: CopyCatalog.shared.format(.fmtTableNPageM, language, number + 1, session.pageNumber(of: table) ?? 1),
                               isOn: includedBinding(table.id))
                }
                DSButton(.selectTableRegion, icon: .table, fullWidth: true) { session.exportTableSelecting = true }
                if session.exportTableSelecting {
                    DSLabel(.dragOverATableOnTheSourcePage, style: .caption).foregroundColor(DSColor.textAccent)
                }
            }
            DSCheckbox(label: .includeAddedText, isOn: $session.exportSettings.includeAddedText)
        }
    }

    /// Save to: the folder, and Change….
    private var saveTo: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            DSLabel(.saveTo, style: .labelSmall).foregroundColor(DSColor.textSecondary)
            HStack(spacing: DSSpace.s8) {
                DSIcon.folderOpen.image(size: 16).foregroundColor(DSColor.textSecondary)
                Text(folderName).dsText(.body).foregroundColor(folder == nil ? DSColor.textTertiary : DSColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: DSSpace.s8)
                DSButton(.change, size: .small) { session.chooseExportFolder() }
            }
        }
    }

    private var folder: URL? { session.exportSettings.folder ?? appState.exportFolder }
    private var folderName: String { folder.map { FileManager.default.displayName(atPath: $0.path) } ?? language(.notSelected) }

    /// What needs a look before exporting: pages with no text, and uncertain OCR lines nobody reviewed.
    private var issues: [ExportIssue] {
        var list: [ExportIssue] = []
        let empty = session.exportPreview.filter { !$0.hasText }.map(\.number)
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

    private var tablesInScope: [ExportTable] {
        let scope = Set((session.exportPageIndices ?? []).filter { session.pages.indices.contains($0) }.map { session.pages[$0].id })
        return session.exportTables.filter { scope.contains($0.pageID) }
    }

    /// Word + Excel when the pages have text and tables (marked Suggested in the list).
    private var suggestion: ExportFormat? {
        guard session.exportTablesDetected, !tablesInScope.isEmpty else { return nil }
        return .wordExcel
    }

    private func includedBinding(_ id: ExportTable.ID) -> Binding<Bool> {
        Binding(get: { session.exportTables.first { $0.id == id }?.included ?? false },
                set: { value in
                    if let index = session.exportTables.firstIndex(where: { $0.id == id }) { session.exportTables[index].included = value }
                })
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

    private func outputNameLabel(_ format: ExportFormat) -> CopyKey {
        switch format {
        case .word, .wordExcel: .wordOutputName
        case .excel: .excelOutputName
        case .searchablePDF: .pdfOutputName
        case .plainText: .textOutputName
        }
    }

    private func exportLabel(_ format: ExportFormat) -> CopyKey {
        switch format {
        case .word: .exportWordFile
        case .excel: .exportExcelFile
        case .wordExcel: .exportBothFiles
        case .searchablePDF: .exportSearchablePDF
        case .plainText: .exportTextUTF8
        }
    }

    /// One format in the list (Figma Export Panel · Format row).
    private struct FormatRow: View {
        let format: ExportFormat
        let isSelected: Bool
        let isSuggested: Bool
        let action: () -> Void
        @Environment(\.appLanguage) private var language
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: DSSpace.s12) {
                    icon.image(size: 24).foregroundColor(isSelected ? DSColor.textAccent : DSColor.textSecondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(language(title)).dsText(.bodyStrong).foregroundColor(DSColor.textPrimary)
                        Text(language(subtitle)).dsText(.caption).foregroundColor(DSColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if isSuggested { DSBadge(label: language(.suggested), tone: .accent) }
                }
                .padding(.horizontal, DSSpace.s12)
                .padding(.vertical, DSSpace.s8)
                .background(RoundedRectangle(cornerRadius: DSRadius.md)
                    .fill(isSelected ? DSColor.backgroundSelected : isHovered ? DSColor.backgroundHover : .clear))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.md)
                    .strokeBorder(isSelected ? DSColor.accentDefault : DSColor.borderSubtle, lineWidth: isSelected ? 1.5 : DSStroke.default))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        private var icon: DSIcon {
            switch format {
            case .word, .wordExcel: .fileWord
            case .excel: .fileExcel
            case .searchablePDF: .filePdf
            case .plainText: .fileTxt
            }
        }

        private var title: CopyKey {
            switch format {
            case .word: .word
            case .excel: .excel
            case .wordExcel: .wordExcel
            case .searchablePDF: .searchablePDF
            case .plainText: .plainText
            }
        }

        private var subtitle: CopyKey {
            switch format {
            case .word: .editableDocument
            case .excel: .tablesAsSpreadsheets
            case .wordExcel: .documentAndItsTables
            case .searchablePDF: .pagesWithSearchableText
            case .plainText: .textOnlyUTF8
            }
        }
    }
}

// MARK: - Canvas (Figma KM · 05 Export Word — refined: the output preview alone)

struct ExportCanvas: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var bannerDismissed = false
    /// Word + Excel: which output is shown.
    @State private var tab: ExportFormat = .word

    private struct PreviewKey: Equatable {
        let revision: Int
        let pages: [Int]?
        let include: Bool
        let tables: [ExportTable]
    }

    var body: some View {
        let format = session.exportSettings.format
        ZStack(alignment: .top) {
            Group {
                if session.exportTableSelecting {
                    // Select table region: drag over the table on the source page.
                    OCRSourcePage(showsRegions: false, tableRegions: tableRegions, onRegionSelected: { rect in
                        Task {
                            await session.addExportTable(in: rect, onPageAt: session.currentPageIndex)
                            session.exportTableSelecting = false
                        }
                    })
                } else {
                    ExportOutputPreview(showsExcel: format == .excel || (format == .wordExcel && tab == .excel))
                }
            }
            .padding(.top, 64)
            .padding([.horizontal, .bottom], DSSpace.s24)
            HStack {
                if format == .wordExcel, !session.exportTableSelecting {
                    DSSegmentedControl(selection: $tab, segments: [.init(value: .word, title: language(.wordPreview)),
                                                                   .init(value: .excel, title: language(.excelPreview))])
                        .fixedSize()
                } else {
                    Text(language(session.exportTableSelecting ? .sourcePage : previewTitle(format)))
                        .dsText(.caption).foregroundColor(DSColor.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, DSSpace.s24)
            .padding(.top, DSSpace.s16)
            PageNavigationPill().padding(.top, DSSpace.s12)
            if !changedPages.isEmpty, !bannerDismissed {
                // Figma 40: pages turned after recognition.
                DSBanner(tone: .warning, title: language(.pagesChangedAfterRecognition),
                         message: CopyCatalog.shared.variant(.fmtPagesNWereRotatedAfterOCR, language, singular: changedPages.count == 1,
                                                             RecognizingDialog.pageList(changedPages, language)),
                         action: DSInlineAction(title: language(.reviewOCR)) { session.workspace = .khmerOCR },
                         onClose: { bannerDismissed = true })
                    .frame(maxWidth: 440)
                    .padding(.top, 56)
            }
        }
        .background(DSColor.backgroundCanvas)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear { tab = format == .excel ? .excel : .word }
        .onChange(of: format) { tab = $0 == .excel ? .excel : .word }
        .task(id: PreviewKey(revision: session.contentRevision, pages: session.exportPageIndices,
                             include: session.exportSettings.includeAddedText, tables: session.exportTables)) {
            if !session.exportTablesDetected { await session.detectExportTables() }
            session.exportPreview = await session.exportPages(session.exportPageIndices ?? [],
                                                              includeAddedText: session.exportSettings.includeAddedText,
                                                              tables: session.includedExportTables, language: language)
        }
    }

    private func previewTitle(_ format: ExportFormat) -> CopyKey {
        switch format {
        case .word, .wordExcel: .wordPreview
        case .excel: .excelPreview
        case .searchablePDF: .searchablePDFPreview
        case .plainText: .textPreviewUTF8
        }
    }

    /// Tables on the page shown (outlined on the source page).
    private var tableRegions: [CGRect] {
        guard session.pages.indices.contains(session.currentPageIndex) else { return [] }
        let pageID = session.pages[session.currentPageIndex].id
        return session.includedExportTables.filter { $0.pageID == pageID }.map(\.region)
    }

    /// Export pages whose OCR was made before the page was turned (indices).
    private var changedPages: [Int] {
        (session.exportPageIndices ?? []).filter { index in
            guard session.pages.indices.contains(index), let ocr = session.ocrResults[session.pages[index].id],
                  let turns = ocr.quarterTurns else { return false }
            return turns != session.pages[index].quarterTurns
        }
    }
}

/// The current page as the chosen format will write it, on a page-shaped sheet (Excel: the table editor).
struct ExportOutputPreview: View {
    let showsExcel: Bool
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var tableIndex = 0

    var body: some View {
        let format = session.exportSettings.format
        if showsExcel {
            excelPreview
        } else if format == .searchablePDF {
            OCRSourcePage(showsRegions: false)
        } else {
            GeometryReader { proxy in
                let sheet = Self.sheetSize(in: proxy.size)
                ScrollView {
                    pageContent(format)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(sheet.width * 0.08)
                }
                .frame(width: sheet.width, height: sheet.height)
                .background(DSColor.backgroundPage)
                .dsElevation(.raised)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
        }
    }

    /// A4 proportions, as large as fits.
    static func sheetSize(in space: CGSize) -> CGSize {
        let ratio: CGFloat = 1.414
        let width = min(space.width, space.height / ratio)
        return CGSize(width: max(width, 1), height: max(width * ratio, 1))
    }

    private var page: ExportPage? { session.exportPreview.first { $0.number == session.currentPageIndex + 1 } }

    @ViewBuilder private func pageContent(_ format: ExportFormat) -> some View {
        if let page {
            if format == .plainText {
                Text(ExportBuilder.plainText(pages: [page]))
                    .dsText(.body).foregroundColor(DSColor.textOnPage).textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: DSSpace.s8) {
                    ForEach(Array(page.blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case let .heading(level, text):
                            Text(text).dsText(level == 1 ? .title : .heading).foregroundColor(DSColor.textOnPage)
                        case let .paragraph(runs):
                            Text(runs.map(\.text).joined()).dsText(.body).foregroundColor(DSColor.textOnPage)
                        case let .table(table):
                            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                                    GridRow {
                                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                            Text(cell.plainText).dsText(.caption).foregroundColor(DSColor.textOnPage)
                                                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                                                .padding(.horizontal, DSSpace.s4)
                                                .border(DSColor.borderOnPage, width: 0.5)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else if session.exportPreview.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else {
            // This page is not in “Pages to include”.
            DSLabel(.pagesWithoutText, style: .body).foregroundColor(DSColor.textTertiary)
        }
    }

    /// Figma Table Editor (131:*): the chosen table's cells, editable; tabs for each table below.
    @ViewBuilder private var excelPreview: some View {
        let tables = session.includedExportTables
        VStack(alignment: .leading, spacing: DSSpace.s12) {
            if tables.isEmpty {
                DSLabel(.noTablesWereDetected, style: .body).foregroundColor(DSColor.textSecondary)
                DSButton(.selectTableRegion, icon: .table, size: .small) { session.exportTableSelecting = true }
            } else {
                let current = tables[min(tableIndex, tables.count - 1)]
                if let index = session.exportTables.firstIndex(where: { $0.id == current.id }) {
                    ExportTableGrid(table: $session.exportTables[index])
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DSSpace.s4) {
                        ForEach(Array(tables.enumerated()), id: \.element.id) { number, table in
                            Button { tableIndex = number } label: {
                                Text(CopyCatalog.shared.format(.fmtTableNPageM2, language, number + 1, session.pageNumber(of: table) ?? 1))
                                    .dsText(number == tableIndex ? .label : .body)
                                    .foregroundColor(number == tableIndex ? DSColor.textPrimary : DSColor.textSecondary)
                                    .padding(.horizontal, DSSpace.s12).padding(.vertical, DSSpace.s4)
                                    .background(Capsule().fill(number == tableIndex ? DSColor.backgroundSurface : .clear))
                                    .overlay(Capsule().strokeBorder(number == tableIndex ? DSColor.borderSubtle : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(DSSpace.s24)
        .frame(maxWidth: 640, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DSRadius.md).fill(DSColor.backgroundSurface))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.md).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        let word = pending.wordURL ?? pending.url
        session.runExport(pending.indices, to: replacing ? word : DocumentSession.freeURL(near: word),
                          excelURL: pending.excelURL.map { replacing ? $0 : DocumentSession.freeURL(near: $0) }, access: access, language)
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

/// Figma 17 No tables were detected: Export to Word instead · Select table region.
struct NoTablesDialog: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        DSDialog(icon: .table, iconColor: DSColor.accentDefault,
                 title: language(.noTablesWereDetected), message: language(.weCouldnTDetectAnyTablesOnTheSel),
                 cancel: .exportToWordInstead, confirm: .selectTableRegion,
                 onCancel: {
                     session.organizeDialog = nil
                     session.exportSettings.format = .word
                     session.exportSettings.fileName = session.defaultExportFileName(for: .word)
                 },
                 onConfirm: {
                     session.organizeDialog = nil
                     session.exportTableSelecting = true
                 })
    }
}

/// Figma 38 Word file saved. Excel file wasn’t.: Show Word file · Retry Excel only.
struct ExcelFailedDialog: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        let pending = session.pendingExport
        DSDialog(icon: .attention, iconColor: DSColor.statusDanger,
                 title: language(.wordFileSavedExcelFileWasnT),
                 message: CopyCatalog.shared.format(.fmtWordSavedInFolderExcelNotWritten, language,
                                                    pending?.wordURL?.lastPathComponent ?? "",
                                                    pending?.wordURL?.deletingLastPathComponent().lastPathComponent ?? "",
                                                    pending?.url.lastPathComponent ?? ""),
                 cancel: .showWordFile, confirm: .retryExcelOnly,
                 onCancel: {
                     if let word = pending?.wordURL { NSWorkspace.shared.activateFileViewerSelecting([word]) }
                     session.pendingExport = nil
                     session.organizeDialog = nil
                 },
                 onConfirm: {
                     session.pendingExport = nil
                     session.organizeDialog = nil
                     guard let pending else { return }
                     session.runExport(pending.indices, to: pending.url, only: .excel,
                                       access: SaveDestination.Access(url: pending.url.deletingLastPathComponent()) {}, language)
                 })
    }
}

/// One table's cells as an editable grid (header row shaded). Edits change what Excel and Word receive.
struct ExportTableGrid: View {
    @Binding var table: ExportTable

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            TextField("", text: Binding(get: { table.rows[row][column] }, set: { table.rows[row][column] = $0 }))
                                .textFieldStyle(.plain)
                                .dsText(row == 0 ? .label : .body)
                                .foregroundColor(DSColor.textPrimary)
                                .padding(.horizontal, DSSpace.s8)
                                .frame(minWidth: 72, minHeight: 30, alignment: .leading)
                                .background(row == 0 ? DSColor.backgroundHover : DSColor.backgroundSurface)
                                .border(DSColor.borderSubtle, width: 0.5)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 220)
        .overlay(Rectangle().strokeBorder(DSColor.borderDefault, lineWidth: DSStroke.default))
    }
}
