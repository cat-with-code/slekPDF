import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Prototype 02 Organize pages: Page Organizer canvas (110:350) and Organize Panel (110:351), with
/// 20 Delete pages?, 23 Pages deleted, 42 Save work and 43 Work saved. Changes apply to a new copy only.
struct OrganizeCanvas: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var draggedID: DocumentSession.PageRef.ID?

    private let columns = [GridItem(.adaptive(minimum: 152, maximum: 152), spacing: DSSpace.s24, alignment: .topLeading)]

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.s16) {
                    VStack(alignment: .leading, spacing: DSSpace.s4) {
                        Text(language(.pageOverview)).dsText(.title).foregroundColor(DSColor.textPrimary)
                        Text(CopyCatalog.shared.count(.fmtNPagesSelected, language, session.selectedPageIDs.count))
                            .dsText(.caption).foregroundColor(DSColor.textSecondary)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: DSSpace.s24) {
                        ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                            PageTile(index: index, page: page, isDragging: draggedID != nil)
                                .onDrag {
                                    draggedID = page.id
                                    if !session.selectedPageIDs.contains(page.id) { session.selectedPageIDs = [page.id] }
                                    return NSItemProvider(object: page.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: PageDropDelegate(target: index, session: session, draggedID: $draggedID))
                        }
                    }
                    HStack(spacing: DSSpace.s8) {
                        DSButton(.moveEarlier, icon: .left) { session.movePages(by: -1) }
                            .disabled(session.selectedPageIndices.first.map { $0 == 0 } ?? true)
                        DSButton(.moveLater, icon: .right) { session.movePages(by: 1) }
                            .disabled(session.selectedPageIndices.last.map { $0 >= session.pages.count - 1 } ?? true)
                    }
                    Text(language(.dragPagesToReorderOrUseMoveEarl)).dsText(.caption).foregroundColor(DSColor.textTertiary)
                }
                .padding(.horizontal, DSSpace.s24)
                .padding(.top, 64)
                .padding(.bottom, DSSpace.s24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            PageNavigationPill().padding(.top, DSSpace.s12)
        }
        .background(DSColor.backgroundCanvas)
        .background {
            // Move Page Earlier / Later from Preferences ▸ Keyboard Shortcuts (default ⌥⌘↑ / ⌥⌘↓).
            Button("") { session.movePages(by: -1) }.shortcut(.movePageEarlier).opacity(0).disabled(session.isModalPresented)
            Button("") { session.movePages(by: 1) }.shortcut(.movePageLater).opacity(0).disabled(session.isModalPresented)
        }
    }
}

private extension AppLanguage {
    func callAsFunction(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, self) }
}

/// Figma "Page Thumbnail" (104:113), Size=Large: 144 × 196 page with a selection checkbox and "Page N".
private struct PageTile: View {
    let index: Int
    let page: DocumentSession.PageRef
    var isDragging = false
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var isTargeted = false

    private var isSelected: Bool { session.selectedPageIDs.contains(page.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s8) {
            ZStack {
                DSColor.backgroundPage
                if let image = session.thumbnail(for: index, size: CGSize(width: 144, height: 196)) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 144, height: 196)
            .overlay(Rectangle().strokeBorder(isSelected ? DSColor.accentDefault : DSColor.borderSubtle, lineWidth: isSelected ? 2 : DSStroke.default))
            .dsElevation(.raised)
            .contentShape(Rectangle())
            .onTapGesture { select(extending: NSEvent.modifierFlags) }
            Toggle(isOn: Binding(get: { isSelected }, set: { on in
                if on { session.selectedPageIDs.insert(page.id) } else { session.selectedPageIDs.remove(page.id) }
            })) { EmptyView() }
                .toggleStyle(PageCheckboxStyle(label: CopyCatalog.shared.format(.fmtPageN, language, index + 1)))
        }
        .padding(DSSpace.s4)
        .overlay(alignment: .leading) {
            // Drop Indicator: where the dragged pages will land.
            if isDragging, isTargeted {
                Capsule().fill(DSColor.accentDefault).frame(width: 3).padding(.vertical, DSSpace.s4).offset(x: -DSSpace.s12)
            }
        }
        .onDrop(of: [.text], isTargeted: $isTargeted) { _ in false }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Click selects one page; ⌘-click toggles; ⇧-click selects a range.
    private func select(extending flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            if isSelected { session.selectedPageIDs.remove(page.id) } else { session.selectedPageIDs.insert(page.id) }
        } else if flags.contains(.shift), let anchor = session.selectedPageIndices.first {
            let range = min(anchor, index)...max(anchor, index)
            session.selectedPageIDs = Set(range.map { session.pages[$0].id })
        } else {
            session.selectedPageIDs = [page.id]
        }
        session.goToPage(index)
    }
}

/// The Figma Checkbox (95:49) look for the page tile's toggle.
private struct PageCheckboxStyle: ToggleStyle {
    let label: String

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: DSSpace.s8) {
                ZStack {
                    RoundedRectangle(cornerRadius: DSRadius.xs).fill(configuration.isOn ? DSColor.accentDefault : DSColor.backgroundSurface)
                    if configuration.isOn {
                        DSIcon.check.image(size: 12).foregroundColor(DSColor.textOnAccent)
                    } else {
                        RoundedRectangle(cornerRadius: DSRadius.xs).strokeBorder(DSColor.borderStrong, lineWidth: DSStroke.default)
                    }
                }
                .frame(width: 16, height: 16)
                Text(label).dsText(.body).foregroundColor(DSColor.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PageDropDelegate: DropDelegate {
    let target: Int
    let session: DocumentSession
    @Binding var draggedID: DocumentSession.PageRef.ID?

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedID = nil }
        guard draggedID != nil else { return false }
        let firstMoving = session.selectedPageIndices.first ?? target
        // Dropping on a later page puts the pages after it; on an earlier page, before it.
        session.movePages(session.selectedPageIDs, to: target > firstMoving ? target + 1 : target)
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

/// Organize Panel (110:351) in the inspector.
struct OrganizeInspector: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s12) {
                header(.organizePages, .selectedPages)
                DSButton(.rotateSelectedPages, icon: .rotate, fullWidth: true) { session.rotateSelectedPages() }
                    .disabled(session.selectedPageIDs.isEmpty)
                DSButton(.deleteSelectedPages, icon: .delete, style: .destructive, fullWidth: true) { session.requestDeletePages(language) }
                    .disabled(session.selectedPageIDs.isEmpty || session.selectedPageIDs.count >= session.pages.count)
                DSButton(.splitIntoPDFs, icon: .split, fullWidth: true) { session.organizeDialog = .split }  // 21
                    .disabled(session.pageCount < 2)
                DSDivider()
                header(.combineDocuments, .reviewFileOrderBeforeMergingUndoPa)
                DSButton(.mergePDFs, icon: .merge, fullWidth: true) { session.organizeDialog = .merge }  // 19
                DSDivider()
                header(.save, .aNewCopyIsSavedSourceFilesArePr)
                // Export (05–09) is not built yet; Save work (⌘S, toolbar) keeps the page changes meanwhile.
                DSButton(.openExport, icon: .download, style: .primary, fullWidth: true).disabled(true)
            }
            .padding(DSSpace.s16)
        }
        .background(DSColor.backgroundSurface)
        .overlay(alignment: .topTrailing) {
            DSIconButton(.right, size: 24, iconSize: 14) { session.setInspectorVisible(false) }
                .dsTooltip(.hideInspector, shortcut: ShortcutStore.shared.shortcut(.showInspector)?.display)
                .padding(DSSpace.s12)
        }
    }

    private func header(_ title: CopyKey, _ caption: CopyKey) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            Text(language(title)).dsText(.heading).foregroundColor(DSColor.textPrimary)
            Text(language(caption)).dsText(.caption).foregroundColor(DSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Actions shared by the panel, toolbar and menus

extension DocumentSession {
    /// 20 Delete pages? (skipped after "Don’t ask again this session"), then 23 Pages deleted with Undo.
    func requestDeletePages(_ language: AppLanguage) {
        guard !selectedPageIDs.isEmpty, selectedPageIDs.count < pages.count else { return }
        if skipDeleteConfirmation { performDeletePages(language) } else { organizeDialog = .deletePages }
    }

    func performDeletePages(_ language: AppLanguage) {
        organizeDialog = nil
        let removed = deleteSelectedPages()
        guard removed > 0 else { return }
        toasts.show(.default, CopyCatalog.shared.count(.fmtNPagesDeleted, language, removed),
                    action: DSInlineAction(title: CopyCatalog.shared.string(.undo, language)) { [weak self] in
                        self?.undoManager?.undo()
                        self?.toasts.dismiss()
                    })
    }

    /// Save work (⌘S): the first time asks for a name (42); later saves go to the same work file.
    func requestSaveWork(_ language: AppLanguage) {
        if let workURL { Task { await finishSaveWork(to: workURL, language) } } else { organizeDialog = .saveWork }
    }

    /// Suggested work file name (Figma: "Monthly report — work").
    var suggestedWorkName: String {
        ((fileName as NSString?)?.deletingPathExtension ?? "Slek PDF") + " — work"
    }

    /// 43 Work saved, or an error toast that keeps the edits (nothing is lost; the source is untouched).
    func finishSaveWork(to url: URL, _ language: AppLanguage) async {
        do {
            try await saveWork(to: url)
            workURL = url
            toasts.show(.success, CopyCatalog.shared.format(.fmtWorkSavedName, language, url.deletingPathExtension().lastPathComponent))
            if closeAfterSave {
                closeAfterSave = false
                closeWindowAfterDecision()
            }
        } catch {
            closeAfterSave = false
            quitAfterClose = false
            toasts.show(.error, error.localizedDescription)
        }
    }
}

/// 20 Delete pages? and 42 Save work, in the window's modal layer.
struct OrganizeDialogView: View {
    let dialog: DocumentSession.OrganizeDialog
    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var appState: AppState
    @Environment(\.appLanguage) private var language
    @State private var dontAskAgain = false
    @State private var name = ""

    var body: some View {
        switch dialog {
        case .deletePages: deletePages
        case .saveWork: saveWork
        case .merge: MergeSheet()
        case .split: SplitSheet()
        case .closeConfirm: CloseConfirmDialog()
        case .recognizing: RecognizingDialog()  // 12
        case .recognizeAgain: RecognizeAgainDialog()  // 39
        case .exportExists: ExportExistsDialog()  // 36
        case .exportFailed: ExportFailedDialog()  // 14
        case .noTables: NoTablesDialog()  // 17
        case .excelFailed: ExcelFailedDialog()  // 38
        }
    }

    private var deletePages: some View {
        let numbers = session.selectedPageIndices.map { language.number($0 + 1) }
        return DSDialog(icon: .delete, iconColor: DSColor.statusDanger,
                        title: CopyCatalog.shared.count(.fmtDeleteNSelectedPages, language, numbers.count),
                        message: CopyCatalog.shared.variant(.fmtPagesWillBeRemovedFromTheNewCopy, language, singular: numbers.count == 1,
                                                            Self.list(numbers, language)),
                        cancel: .cancel, confirm: .deletePages, confirmStyle: .destructive,
                        onCancel: { session.organizeDialog = nil },
                        onConfirm: {
                            session.skipDeleteConfirmation = dontAskAgain
                            session.performDeletePages(language)
                        }) {
            DSCheckbox(label: .donTAskAgainThisSession, isOn: $dontAskAgain).padding(.top, DSSpace.s6)
        }
    }

    private var saveWork: some View {
        DSDialog(icon: .save, title: language(.saveWork), message: language(.keepYourAddedTextCommentsAndPage),
                 cancel: .cancel, confirm: .save, confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
                 onCancel: {
                     session.organizeDialog = nil
                     session.closeAfterSave = false
                     session.quitAfterClose = false
                 }, onConfirm: save) {
            DSTextField(label: .name, text: $name, helperText: CopyCatalog.shared.format(.fmtSavedInFolder, language, folderName), onSubmit: save)
                .padding(.top, DSSpace.s6)
        }
        .onAppear { name = session.suggestedWorkName }
    }

    private var folderName: String { appState.exportFolder?.lastPathComponent ?? language(.documents) }

    /// Writes into the Preferences export folder when the app has access to it; otherwise the system save panel
    /// opens there (the sandbox only allows writing where the user chose).
    private func save() {
        let fileName = name.trimmingCharacters(in: .whitespaces) + ".pdf"
        session.organizeDialog = nil
        guard let destination = SaveDestination.file(named: fileName, appState) else {
            session.closeAfterSave = false
            session.quitAfterClose = false
            return
        }
        Task {
            await session.finishSaveWork(to: destination.url, language)
            destination.release()
        }
    }

    /// "2 and 3" / "២ និង ៣".
    private static func list(_ items: [String], _ language: AppLanguage) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        let and = language == .km ? " និង " : " and "
        return items.dropLast().joined(separator: language == .km ? " " : ", ") + and + items.last!
    }
}
