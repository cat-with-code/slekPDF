import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Where new files go: the Preferences export folder when the app has access to it, otherwise a system panel
/// (the sandbox only allows writing where the user chose). `release` ends the folder access afterwards.
@MainActor
enum SaveDestination {
    struct Access {
        let url: URL
        let release: () -> Void
    }

    static func file(named fileName: String, _ appState: AppState) -> Access? {
        if let folder = appState.exportFolder, folder.startAccessingSecurityScopedResource() {
            return Access(url: folder.appendingPathComponent(fileName)) { folder.stopAccessingSecurityScopedResource() }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Access(url: url) {}
    }

    static func folder(_ appState: AppState) -> Access? {
        if let folder = appState.exportFolder, folder.startAccessingSecurityScopedResource() {
            return Access(url: folder) { folder.stopAccessingSecurityScopedResource() }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Access(url: url) {}
    }
}

private extension AppLanguage {
    func callAsFunction(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, self) }
}

extension DocumentSession {
    /// 22 New PDF saved: "New PDF saved to <folder>" with Show in Finder.
    func showSaved(_ urls: [URL], _ language: AppLanguage) {
        guard let folder = urls.first?.deletingLastPathComponent() else { return }
        toasts.show(.success, CopyCatalog.shared.format(.fmtNewPDFSavedToFolder, language, folder.lastPathComponent),
                    action: DSInlineAction(title: language(.showInFinder)) { NSWorkspace.shared.activateFileViewerSelecting(urls) })
    }

    /// Closes the window after "Don’t save" or a finished save; continues quitting if that started it.
    func closeWindowAfterDecision() {
        let quit = quitAfterClose
        window?.performClose(nil)
        if quit { DispatchQueue.main.async { NSApp.terminate(nil) } }
    }
}

// MARK: - 19 Merge PDFs (Merge PDFs Sheet 145:98)

struct MergeSheet: View {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        /// nil = the open document (with its page changes).
        let url: URL?
        let name: String
        let pageCount: Int
        let bytes: Int64
        let isLocked: Bool
    }

    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var appState: AppState
    @Environment(\.appLanguage) private var language
    @State private var items: [Item] = []
    @State private var selected: Item.ID?
    @State private var fileName = ""
    @State private var dragged: Item.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s16) {
            VStack(alignment: .leading, spacing: DSSpace.s4) {
                Text(language(.mergePDFs2)).dsText(.title).foregroundColor(DSColor.textPrimary)
                Text(language(.filesAreCombinedInThisOrderIntoA)).dsText(.body).foregroundColor(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: DSSpace.s6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item, number: index + 1)
                        .onDrag { dragged = item.id; return NSItemProvider(object: item.id.uuidString as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { _ in moveDragged(to: index) }
                }
            }
            HStack(spacing: DSSpace.s8) {
                DSButton(.addFiles, icon: .folderOpen, size: .small, action: addFiles)
                Text(CopyCatalog.shared.count(.fmtNFilesMPagesInTotal, language, items.count, items.reduce(0) { $0 + $1.pageCount }))
                    .dsText(.caption).foregroundColor(DSColor.textTertiary)
            }
            DSTextField(label: .newFileName, text: $fileName)
            HStack(spacing: DSSpace.s8) {
                Spacer()
                DSButton(.cancel) { session.organizeDialog = nil }.keyboardShortcut(.cancelAction)
                // Locked files must be unlocked (or removed) before merging.
                DSButton(.mergePDFs2, style: .primary, action: merge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.count < 2 || items.contains(where: \.isLocked) || fileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DSSpace.s24)
        .frame(width: 480)
        .background(RoundedRectangle(cornerRadius: DSRadius.lg).fill(DSColor.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.lg).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .dsElevation(.dialog)
        .accessibilityAddTraits(.isModal)
        .background {
            // File List Item: ⌘↑ / ⌘↓ move the selected row.
            Button("") { moveSelected(by: -1) }.keyboardShortcut(.upArrow).opacity(0)
            Button("") { moveSelected(by: 1) }.keyboardShortcut(.downArrow).opacity(0)
        }
        .onAppear(perform: start)
    }

    /// Figma "File List Item" (145:97).
    private func row(_ item: Item, number: Int) -> some View {
        let isSelected = item.id == selected
        return HStack(spacing: DSSpace.s8) {
            DSIcon.drag.image(size: 16).foregroundColor(DSColor.textTertiary)
            Text(language.number(number)).dsText(.labelSmall).foregroundColor(DSColor.textTertiary)
            DSIcon.fileTypePdf.image(size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name).dsText(.label).foregroundColor(DSColor.textPrimary).lineLimit(1).truncationMode(.tail)
                Text(CopyCatalog.shared.count(.fmtNPagesSize, language, item.pageCount,
                                              ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)))
                    .dsText(.caption).foregroundColor(DSColor.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.isLocked { DSBadge(label: language(.passwordNeeded), tone: .warning) }
            DSIconButton(.close, size: 24, iconSize: 14) { items.removeAll { $0.id == item.id } }
                .dsTooltip(.menuClose)
        }
        .padding(.leading, DSSpace.s8)
        .padding(.trailing, DSSpace.s4)
        .padding(.vertical, DSSpace.s8)
        .background(RoundedRectangle(cornerRadius: DSRadius.md).fill(isSelected ? DSColor.backgroundSelected : DSColor.backgroundSurface))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.md).strokeBorder(isSelected ? DSColor.accentDefault : DSColor.borderSubtle, lineWidth: DSStroke.default))
        .contentShape(Rectangle())
        .onTapGesture { selected = item.id }
    }

    private func start() {
        fileName = language(.mergedDocumentPdf)
        guard items.isEmpty, let name = session.fileName else { return }
        let bytes = (try? session.url?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        items = [Item(url: nil, name: name, pageCount: session.pageCount, bytes: bytes, isLocked: false)]
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let document = PDFDocument(url: url)
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            items.append(Item(url: url, name: url.lastPathComponent, pageCount: document?.pageCount ?? 0, bytes: bytes,
                              isLocked: document?.isLocked ?? true))
        }
    }

    private func moveSelected(by offset: Int) {
        guard let selected, let index = items.firstIndex(where: { $0.id == selected }), items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset)
    }

    private func moveDragged(to target: Int) -> Bool {
        defer { dragged = nil }
        guard let dragged, let from = items.firstIndex(where: { $0.id == dragged }) else { return false }
        let item = items.remove(at: from)
        items.insert(item, at: min(target, items.count))
        return true
    }

    private func merge() {
        var name = fileName.trimmingCharacters(in: .whitespaces)
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        let sources: [PDFiumService.PageSource] = items.flatMap { item -> [PDFiumService.PageSource] in
            guard let url = item.url else { return session.editedPageSources() }
            return (0..<item.pageCount).map { .file(url, page: $0) }
        }
        session.organizeDialog = nil
        guard let destination = SaveDestination.file(named: name, appState) else { return }
        Task {
            defer { destination.release() }
            do {
                try await PDFiumService.shared.writePDF(sources, to: destination.url)
                session.showSaved([destination.url], language)
            } catch {
                session.toasts.show(.error, error.localizedDescription)
            }
        }
    }
}

// MARK: - 21 Split into PDFs → 22 New PDF saved

struct SplitSheet: View {
    enum Mode: Hashable { case everyPage, everyTwo, ranges }

    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var appState: AppState
    @Environment(\.appLanguage) private var language
    @State private var mode: Mode = .everyPage
    @State private var rangesText = ""

    private var parts: [[Int]]? {
        let count = session.pageCount
        switch mode {
        case .everyPage: return (0..<count).map { [$0] }
        case .everyTwo: return stride(from: 0, to: count, by: 2).map { Array($0..<min($0 + 2, count)) }
        case .ranges: return PageRanges.parse(rangesText, pageCount: count)
        }
    }

    var body: some View {
        let count = session.pageCount
        VStack(alignment: .leading, spacing: DSSpace.s16) {
            Text(language(.splitIntoPDFs2)).dsText(.title).foregroundColor(DSColor.textPrimary)
            Text(language(.createANewPDFForEachPartTheOrigi)).dsText(.body).foregroundColor(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DSSpace.s12) {
                radio(.everyPage, CopyCatalog.shared.count(.fmtEveryPageNPDFs, language, count))
                radio(.everyTwo, CopyCatalog.shared.format(.fmtEveryNPagesMPDFs, language, 2, (count + 1) / 2))
                radio(.ranges, language(.byPageRanges))
            }
            VStack(alignment: .leading, spacing: DSSpace.s4) {
                Text(language(.pageRanges)).dsText(.labelSmall).foregroundColor(mode == .ranges ? DSColor.textSecondary : DSColor.textDisabled)
                TextField(language(.s123), text: $rangesText)
                    .textFieldStyle(.plain)
                    .dsText(.body)
                    .padding(.horizontal, DSSpace.s12)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: DSRadius.sm).fill(mode == .ranges ? DSColor.backgroundSurface : DSColor.backgroundDisabled))
                    .overlay(RoundedRectangle(cornerRadius: DSRadius.sm)
                        .strokeBorder(mode == .ranges && !rangesText.isEmpty && parts == nil ? DSColor.statusDanger : DSColor.borderDefault,
                                      lineWidth: DSStroke.default))
                    .disabled(mode != .ranges)
            }
            HStack(spacing: DSSpace.s8) {
                Spacer()
                DSButton(.cancel) { session.organizeDialog = nil }.keyboardShortcut(.cancelAction)
                DSButton(.splitIntoPDFs2, style: .primary, action: split)
                    .keyboardShortcut(.defaultAction)
                    .disabled((parts?.count ?? 0) < 1 || count < 2)
            }
        }
        .padding(DSSpace.s24)
        .frame(width: 448)
        .background(RoundedRectangle(cornerRadius: DSRadius.lg).fill(DSColor.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.lg).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .dsElevation(.dialog)
        .accessibilityAddTraits(.isModal)
    }

    /// Figma "Radio" (95:80).
    private func radio(_ value: Mode, _ title: String) -> some View {
        Button { mode = value } label: {
            HStack(spacing: DSSpace.s8) {
                ZStack {
                    Circle().fill(mode == value ? DSColor.accentDefault : DSColor.backgroundSurface)
                    if mode == value {
                        Circle().fill(DSColor.textOnAccent).frame(width: 6, height: 6)
                    } else {
                        Circle().strokeBorder(DSColor.borderStrong, lineWidth: DSStroke.default)
                    }
                }
                .frame(width: 16, height: 16)
                Text(title).dsText(.body).foregroundColor(DSColor.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? [.isSelected] : [])
    }

    private func split() {
        guard let parts, let base = (session.fileName as NSString?)?.deletingPathExtension else { return }
        session.organizeDialog = nil
        guard let destination = SaveDestination.folder(appState) else { return }
        Task {
            defer { destination.release() }
            var written: [URL] = []
            do {
                for part in parts {
                    let label = part.count == 1 ? "\(part[0] + 1)" : "\(part.first! + 1)–\(part.last! + 1)"
                    let url = destination.url.appendingPathComponent("\(base) — \(label).pdf")
                    try await PDFiumService.shared.writePDF(session.editedPageSources(part), to: url)
                    written.append(url)
                }
                session.showSaved(written, language)
            } catch {
                session.toasts.show(.error, error.localizedDescription)
            }
        }
    }
}

/// "1–2, 3" → [[0, 1], [2]]; Latin or Khmer digits, "-" or "–". nil when a part is empty or out of range.
enum PageRanges {
    static func parse(_ text: String, pageCount: Int) -> [[Int]]? {
        let latin = String(text.unicodeScalars.map { scalar in
            (0x17E0...0x17E9).contains(scalar.value) ? Character(Unicode.Scalar(scalar.value - 0x17E0 + 48)!) : Character(scalar)
        })
        let pieces = latin.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        var parts: [[Int]] = []
        for piece in pieces {
            let bounds = piece.split(whereSeparator: { $0 == "-" || $0 == "–" }).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard bounds.count == 1 || bounds.count == 2, let first = bounds[0] else { return nil }
            guard let last = bounds.count == 2 ? bounds[1] : first, first >= 1, last >= first, last <= pageCount else { return nil }
            parts.append(Array((first - 1)...(last - 1)))
        }
        return parts
    }
}

// MARK: - 16 Save changes before closing?

struct CloseConfirmDialog: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        DSDialog(icon: .save, iconColor: DSColor.accentDefault, title: language(.saveChangesBeforeClosing),
                 message: CopyCatalog.shared.format(.fmtAddedWorkInFileWillBeLost, language, session.fileName ?? ""),
                 cancel: .cancel, confirm: .save,
                 secondary: (title: .donTSave, action: {
                     session.organizeDialog = nil
                     session.discardChanges = true
                     session.closeWindowAfterDecision()
                 }),
                 onCancel: {
                     session.organizeDialog = nil
                     session.quitAfterClose = false
                 },
                 onConfirm: {
                     session.organizeDialog = nil
                     session.closeAfterSave = true
                     session.requestSaveWork(language)
                 })
    }
}
