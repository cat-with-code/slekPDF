import AppKit
import SwiftUI

/// Native menu bar, built to the Figma "Desktop Menu Bar" (296:1555) and the Menu / … components on the
/// Menu Bar page: Slek PDF · File · Edit · View · Document · Tools · Window · Help, in that order.
///
/// Items the app owns are SwiftUI buttons whose titles come from the `menu: …` copy keys, so they follow the
/// live Khmer/English switch. Items macOS owns (Undo, Cut/Copy/Paste, Select All, Dictation, the Window menu)
/// stay native so the responder chain keeps working; `MainMenuLocalizer` gives them and the menu titles the
/// same copy. Items for screens that are not built yet are shown, in Figma's order, but disabled.
struct AppCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var recents: RecentDocuments
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @FocusedObject private var session: DocumentSession?

    var body: some Commands {
        AppMenuCommands(language: appState.language, session: session)
        FileMenuCommands(language: appState.language, recents: recents, session: session)
        EditAndViewCommands(appState: appState, session: session)
        DocumentAndToolsCommands(language: appState.language, session: session)
        HelpMenuCommands(language: appState.language, session: session)
    }
}

private extension AppLanguage {
    func callAsFunction(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, self) }
}

private extension Optional where Wrapped == DocumentSession {
    /// A window is focused and no in-window dialog (password, can't open) blocks it.
    var isAvailable: Bool { self?.isModalPresented == false }
    /// …and it shows a document.
    var hasDocument: Bool { isAvailable && self?.document != nil }
    /// A window can show an About/Help panel (also replacing one that is already open).
    var canShowPanel: Bool { self != nil && self?.openError == nil }

    func show(_ panel: AppPanel) { self?.panel = panel }
}

/// Slek PDF menu (154:333): About · Developer | Preferences… | Quit. Services and Hide are left out as designed.
private struct AppMenuCommands: Commands {
    let language: AppLanguage
    let session: DocumentSession?

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(language(.menuAboutSlekPDF)) { session.show(.about(.about)) }  // D-27
                .shortcut(.about)
                .disabled(!session.canShowPanel)
            Button(language(.menuDeveloper)) { session.show(.developer) }  // D-31
                .shortcut(.developer)
                .disabled(!session.canShowPanel)
        }
        CommandGroup(replacing: .appSettings) {
            Button(language(.menuPreferences)) { session.show(.preferences(.general)) }  // D-10
                .shortcut(.preferences)
                .disabled(!session.canShowPanel)
        }
        CommandGroup(replacing: .systemServices) {}
        CommandGroup(replacing: .appVisibility) {}
        CommandGroup(replacing: .appTermination) {
            Button(language(.menuQuitSlekPDF)) { NSApp.terminate(nil) }
                .shortcut(.quit)
        }
    }
}

/// File menu (103:349): Open PDF… · Open Recent ▸ | Save work · Save a copy… · Export… | Merge PDFs… · Print… | Close.
private struct FileMenuCommands: Commands {
    let language: AppLanguage
    @ObservedObject var recents: RecentDocuments
    let session: DocumentSession?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(language(.menuOpenPDF)) { session?.isImporterPresented = true }
                .shortcut(.openPDF)
                .disabled(!session.isAvailable)
            Menu(language(.menuOpenRecent)) {
                // Only files that still resolve; `recents.refresh()` touches the disk, so it is never called from here.
                ForEach(recents.entries.filter { recents.url(for: $0) != nil }) { entry in
                    Button(entry.name) {
                        guard let session, let url = recents.url(for: entry) else { return }
                        Task { await session.open(url) }
                    }
                }
                Divider()
                Button(language(.menuClearMenu)) { recents.clear() }
                    .disabled(recents.entries.isEmpty)
            }
            .disabled(!session.isAvailable)
        }
        CommandGroup(replacing: .saveItem) {
            // 42/43 Save work; Save a copy and 05 Export are not built yet.
            Button(language(.menuSaveWork)) { session?.requestSaveWork(language) }.shortcut(.saveWork).disabled(!session.hasDocument)
            Button(language(.menuSaveACopy)) {}.shortcut(.saveACopy).disabled(true)
            Button(language(.menuExport)) {}.shortcut(.export).disabled(true)
        }
        CommandGroup(replacing: .printItem) {
            // 19 Merge PDFs is not built yet.
            Button(language(.menuMergePDFs)) {}.shortcut(.mergePDFs).disabled(true)
            Button(language(.menuPrint)) { session.map { PrintController.print($0, language: language) } }  // D-25
                .shortcut(.print)
                .disabled(!session.hasDocument)
            Divider()
            // Closes whatever window is in front (document, About panel), like the standard item.
            Button(language(.menuClose)) { NSApp.keyWindow?.performClose(nil) }
                .shortcut(.close)
        }
    }
}

/// Edit menu (154:365): the native Undo/Redo and pasteboard items, then Find… · Find Next · Find Previous;
/// macOS adds Start Dictation… at the end. View menu (154:422): workspaces ⌘1–⌘5 | zoom | panels | full screen |
/// Appearance ▸ · Interface Language ▸.
private struct EditAndViewCommands: Commands {
    @ObservedObject var appState: AppState
    let session: DocumentSession?

    private var language: AppLanguage { appState.language }

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            let hasDocument = session.hasDocument
            Button(language(.menuFind)) { session?.focusSearch() }
                .shortcut(.find)
                .disabled(!hasDocument)
            Button(language(.menuFindNext)) { session?.nextMatch() }
                .shortcut(.nextMatch)
                .disabled(!hasDocument || session?.searchResults.isEmpty != false)
            Button(language(.menuFindPrevious)) { session?.previousMatch() }
                .shortcut(.previousMatch)
                .disabled(!hasDocument || session?.searchResults.isEmpty != false)
        }
        CommandGroup(replacing: .toolbar) {
            let hasDocument = session.hasDocument
            ForEach(Array(Workspace.allCases.enumerated()), id: \.element) { index, workspace in
                Toggle(language(workspace.menuTitle), isOn: Binding(
                    get: { session?.workspace == workspace },
                    set: { _ in session?.workspace = workspace }
                ))
                .shortcut([ShortcutCommand.read, .organizePages, .annotate, .khmerOCR, .exportWorkspace][index])
                .disabled(!hasDocument)
            }
            Divider()
            // ⌘+ is shown as in Figma; MainWindowView also accepts ⌘= (the same key without Shift).
            Button(language(.menuZoomIn)) { session?.zoomIn() }.shortcut(.zoomIn).disabled(!hasDocument)
            Button(language(.menuZoomOut)) { session?.zoomOut() }.shortcut(.zoomOut).disabled(!hasDocument)
            Button(language(.menuFitPage)) { session?.fitPage() }.shortcut(.fitPage).disabled(!hasDocument)
            Button(language(.menuFitWidth)) { session?.fitWidth() }.shortcut(.fitWidth).disabled(!hasDocument)
            Divider()
            Toggle(language(.menuShowPageSidebar), isOn: Binding(
                get: { session?.isSidebarVisible ?? false },
                set: { session?.setSidebarVisible($0, animated: false) }
            ))
            .shortcut(.showPageSidebar)
            .disabled(!hasDocument)
            Toggle(language(.menuShowInspector), isOn: Binding(
                get: { session?.isInspectorVisible ?? false },
                set: { session?.setInspectorVisible($0, animated: false) }
            ))
            .shortcut(.showInspector)
            .disabled(!hasDocument)
            Divider()
            Button(language(.menuEnterFullScreen)) { NSApp.keyWindow?.toggleFullScreen(nil) }
                .shortcut(.enterFullScreen)
                .disabled(!session.isAvailable)
            Divider()
            // Menu / Appearance (180:1755): Light · Dark | Use System Setting.
            Menu(language(.menuAppearance)) {
                appearanceToggle(.light, .menuLight)
                appearanceToggle(.dark, .menuDark)
                Divider()
                appearanceToggle(.system, .menuUseSystemSetting)
            }
            // Menu / Interface Language (180:1780): each language in its own script.
            Menu(language(.menuInterfaceLanguage)) {
                languageToggle(.km, "ខ្មែរ")
                languageToggle(.en, "English")
            }
        }
    }

    private func appearanceToggle(_ value: AppearancePreference, _ title: CopyKey) -> some View {
        Toggle(language(title), isOn: Binding(get: { appState.appearance == value }, set: { _ in appState.appearance = value }))
    }

    private func languageToggle(_ value: AppLanguage, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { appState.language == value }, set: { _ in appState.language = value }))
    }
}

/// Document menu (154:489) and Tools menu (154:539). Page tools, annotation and OCR are not built yet.
private struct DocumentAndToolsCommands: Commands {
    let language: AppLanguage
    let session: DocumentSession?

    var body: some Commands {
        CommandMenu(language(.menuDocument)) {
            let hasDocument = session.hasDocument
            let page = session?.currentPageIndex ?? 0
            Button(language(.menuPreviousPage)) { session?.previousPage() }
                .shortcut(.previousPage)
                .disabled(!hasDocument || page == 0)
            Button(language(.menuNextPage)) { session?.nextPage() }
                .shortcut(.nextPage)
                .disabled(!hasDocument || page >= (session?.pageCount ?? 0) - 1)
            Button(language(.menuGoToPage)) { session?.focusPageField() }
                .shortcut(.goToPage)
                .disabled(!hasDocument)
            Divider()
            // Rotate the selected pages (Organize) or the current page; a page edit, saved with Save work.
            Button(language(.menuRotateLeft)) { session?.rotateSelectedPages(clockwise: false) }.shortcut(.rotateLeft).disabled(!hasDocument)
            Button(language(.menuRotateRight)) { session?.rotateSelectedPages(clockwise: true) }.shortcut(.rotateRight).disabled(!hasDocument)
            Button(language(.menuDeleteSelectedPages)) { session?.requestDeletePages(language) }  // 20 Delete pages?
                .shortcut(.deleteSelectedPages)
                .disabled(!hasDocument || session?.workspace != .organizePages || (session?.selectedPageIDs.isEmpty ?? true)
                          || (session?.selectedPageIDs.count ?? 0) >= (session?.pageCount ?? 0))
            Divider()
            Button(language(.menuInsertPagesFromFile)) {}.shortcut(.insertPages).disabled(true)
            Button(language(.menuSplitIntoPDFs)) {}.shortcut(.splitIntoPDFs).disabled(true)
            Button(language(.menuMergePDFs)) {}.shortcut(.mergePDFs).disabled(true)
        }
        CommandMenu(language(.menuTools)) {
            // Figma shows the tool keys V, T, H and C. They are deliberately not menu key equivalents: a key
            // without a modifier would also fire while typing in a text field. The Annotate canvas will handle them.
            Button(language(.menuSelect)) {}.disabled(true)
            Button(language(.menuAddKhmerText)) {}.disabled(true)
            Button(language(.menuHighlightText)) {}.disabled(true)
            Button(language(.menuAddComment)) {}.disabled(true)
            Divider()
            Button(language(.menuRecognizeText)) {}.shortcut(.recognizeText).disabled(true)
            Button(language(.menuReviewOCR)) {}.shortcut(.reviewOCR).disabled(true)
            Divider()
            Button(language(.menuExport)) {}.shortcut(.export).disabled(true)
            Button(language(.menuExportSearchablePDF)) {}.shortcut(.exportSearchablePDF).disabled(true)
        }
    }
}

/// Help menu (154:626). macOS adds its own search field at the top (Figma's ⌘K hint can't be drawn in it).
/// Each item opens its Prototype screen as an in-window panel (D-28 … D-33).
private struct HelpMenuCommands: Commands {
    let language: AppLanguage
    let session: DocumentSession?

    var body: some Commands {
        CommandGroup(replacing: .help) {
            let enabled = session.canShowPanel
            // ⌘? as in the Keyboard Shortcuts panel (251:284).
            Button(language(.menuSlekPDFHelp)) { session.show(.help) }.shortcut(.slekPDFHelp).disabled(!enabled)  // D-30
            // Links to the Website page in Figma; no public URL exists yet.
            Button(language(.menuOnlineDocumentation)) { if let url = SupportContact.website { NSWorkspace.shared.open(url) } }
                .disabled(SupportContact.website == nil)
            Button(language(.menuKeyboardShortcuts)) { session.show(.preferences(.shortcuts)) }.shortcut(.keyboardShortcuts).disabled(!enabled)  // D-10k
            Divider()
            Button(language(.menuPrivacyLicenses)) { session.show(.about(.licenses)) }.shortcut(.privacyLicenses).disabled(!enabled)  // D-29
            Button(language(.menuReleaseNotes)) { session.show(.releaseNotes) }.shortcut(.releaseNotes).disabled(!enabled)  // D-32
            Divider()
            Button(language(.menuReportAProblem)) { session.show(.reportProblem) }.shortcut(.reportProblem).disabled(!enabled)  // D-33
        }
    }
}

extension Workspace {
    /// View menu titles (Figma uses "Organize Pages" here, "Organize pages" on the tab).
    var menuTitle: CopyKey {
        switch self {
        case .read: .menuRead
        case .organizePages: .menuOrganizePages
        case .annotate: .menuAnnotate
        case .khmerOCR: .menuKhmerOCR
        case .export: .menuExport2
        }
    }
}
