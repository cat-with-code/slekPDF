import AppKit
import XCTest
@testable import SlekPDF

/// The running app's (test host's) menu bar against the Figma menus on the Menu Bar page (Menu / Slek PDF 154:333,
/// File 103:349, Edit 154:365, View 154:422, Document 154:489, Tools 154:539, Window 154:584, Help 154:626) and the
/// shortcuts in the Keyboard Shortcuts panel (251:284), in Khmer and in English.
@MainActor
final class MenuBarTests: XCTestCase {
    /// One expected row: a copy key and its shortcut in Figma notation, or a separator.
    private enum Row: Equatable {
        case item(CopyKey, String?)
        case separator
    }

    private static func i(_ key: CopyKey, _ shortcut: String? = nil) -> Row { .item(key, shortcut) }
    private static let sep = Row.separator

    private static let topLevel: [CopyKey] = [.menuSlekPDF, .menuFile, .menuEdit, .menuView, .menuDocument, .menuTools, .menuWindow, .menuHelp]

    /// Full menus, except Edit (macOS may append Start Dictation…) and Window (AppKit adds tab items and the
    /// window list), which are compared as prefixes.
    private static let menus: [(rows: [Row], isPrefix: Bool)] = [
        ([i(.menuAboutSlekPDF), i(.menuDeveloper), sep, i(.menuPreferences, "⌘,"), sep, i(.menuQuitSlekPDF, "⌘Q")], false),
        ([i(.menuOpenPDF, "⌘O"), i(.menuOpenRecent), sep, i(.menuSaveWork, "⌘S"), i(.menuSaveACopy, "⇧⌘S"), i(.menuExport, "⌘E"), sep,
          i(.menuMergePDFs), i(.menuPrint, "⌘P"), sep, i(.menuClose, "⌘W")], false),
        ([i(.menuUndo, "⌘Z"), i(.menuRedo, "⇧⌘Z"), sep, i(.menuCut, "⌘X"), i(.menuCopy, "⌘C"), i(.menuPaste, "⌘V"), i(.menuSelectAll, "⌘A"), sep,
          i(.menuFind, "⌘F"), i(.menuFindNext, "⌘G"), i(.menuFindPrevious, "⇧⌘G")], true),
        ([i(.menuRead, "⌘1"), i(.menuOrganizePages, "⌘2"), i(.menuAnnotate, "⌘3"), i(.menuKhmerOCR, "⌘4"), i(.menuExport2, "⌘5"), sep,
          i(.menuZoomIn, "⌘+"), i(.menuZoomOut, "⌘−"), i(.menuFitPage, "⌘0"), i(.menuFitWidth), sep,
          i(.menuShowPageSidebar, "⌥⌘S"), i(.menuShowInspector, "⌥⌘I"), sep, i(.menuEnterFullScreen, "⌃⌘F"), sep,
          i(.menuAppearance), i(.menuInterfaceLanguage)], false),
        ([i(.menuPreviousPage, "⌘↑"), i(.menuNextPage, "⌘↓"), i(.menuGoToPage, "⌘L"), sep,
          i(.menuRotateLeft, "⌘["), i(.menuRotateRight, "⌘]"), i(.menuDeleteSelectedPages, "⌘⌫"), sep,
          i(.menuInsertPagesFromFile), i(.menuSplitIntoPDFs), i(.menuMergePDFs)], false),
        ([i(.menuSelect), i(.menuAddKhmerText), i(.menuHighlightText), i(.menuAddComment), sep,
          i(.menuRecognizeText, "⌥⌘R"), i(.menuReviewOCR, "⌥⌘O"), sep, i(.menuExport, "⌘E"), i(.menuExportSearchablePDF)], false),
        ([i(.menuMinimize, "⌘M"), i(.menuZoom)], true),
        ([i(.menuSlekPDFHelp, "⌘?"), i(.menuOnlineDocumentation), i(.menuKeyboardShortcuts, "⌘/"), sep,
          i(.menuPrivacyLicenses), i(.menuReleaseNotes), sep, i(.menuReportAProblem)], false),
    ]

    func testMenuBarMatchesFigmaInBothLanguages() throws {
        settle()
        let languageMenu = try XCTUnwrap(NSApp.mainMenu?.items[3].submenu?.items.last?.submenu, "View ▸ Interface Language")
        let original: AppLanguage = languageMenu.items[0].state == .on ? .km : .en
        defer { choose(original, in: languageMenu) }

        for language in [AppLanguage.km, .en] {
            choose(language, in: languageMenu)
            try assertMenuBar(language)
        }
    }

    func testSubmenusHaveTheirChoicesAndOneCheck() throws {
        settle()
        let view = try XCTUnwrap(NSApp.mainMenu?.items[3].submenu)
        let visible = view.items.filter { !$0.isHidden }
        let appearance = try XCTUnwrap(visible[visible.count - 2].submenu)
        let language = try XCTUnwrap(visible[visible.count - 1].submenu)
        XCTAssertEqual(appearance.items.map { $0.isSeparatorItem ? "—" : "item" }, ["item", "item", "—", "item"])
        XCTAssertEqual(appearance.items.filter { $0.state == .on }.count, 1)
        XCTAssertEqual(language.items.map(\.title), ["ខ្មែរ", "English"])
        XCTAssertEqual(language.items.filter { $0.state == .on }.count, 1)
    }

    /// MainMenuLocalizer re-runs whenever a menu item changes; a pass that changes something on every run
    /// would keep the app busy forever (it once did, flipping a trailing separator twice per pass).
    func testMenusSettleWithoutFurtherChanges() {
        settle()
        let noChange = XCTNSNotificationExpectation(name: NSMenu.didChangeItemNotification)
        noChange.isInverted = true
        MainMenuLocalizer.shared.apply()
        wait(for: [noChange], timeout: 1)
    }

    // MARK: - Helpers

    private func assertMenuBar(_ language: AppLanguage, file: StaticString = #filePath, line: UInt = #line) throws {
        let catalog = CopyCatalog.shared
        let main = try XCTUnwrap(NSApp.mainMenu)
        let tops = main.items.filter { !$0.isHidden && $0.submenu != nil }
        XCTAssertEqual(tops.map(\.title), Self.topLevel.map { catalog.string($0, language) }, "top-level titles [\(language)]", file: file, line: line)
        for (top, expected) in zip(tops, Self.menus) {
            let rows = visibleRows(top.submenu!)
            let wanted = expected.rows.map { row -> String in
                guard case let .item(key, shortcut) = row else { return "—" }
                return catalog.string(key, language) + (shortcut.map { "  " + $0 } ?? "")
            }
            let actual = expected.isPrefix ? Array(rows.prefix(wanted.count)) : rows
            XCTAssertEqual(actual, wanted, "\(top.title) [\(language)]", file: file, line: line)
        }
    }

    /// Visible rows as "Title  ⇧⌘S" or "—".
    private func visibleRows(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isHidden }.map { item in
            if item.isSeparatorItem { return "—" }
            return item.title + (shortcut(item).map { "  " + $0 } ?? "")
        }
    }

    private func shortcut(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let mask = item.keyEquivalentModifierMask
        var text = ""
        if mask.contains(.control) { text += "⌃" }
        if mask.contains(.option) { text += "⌥" }
        if mask.contains(.shift) { text += "⇧" }
        if mask.contains(.command) { text += "⌘" }
        let symbols: [String: String] = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{08}": "⌫", "\u{7F}": "⌫", "-": "−"]
        return text + (symbols[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }

    private func choose(_ language: AppLanguage, in menu: NSMenu) {
        menu.performActionForItem(at: language == .km ? 0 : 1)
        settle()
    }

    /// Lets SwiftUI rebuild the menus and `MainMenuLocalizer` run, then does what opening each menu does:
    /// SwiftUI refreshes a menu's items only when it is about to be shown (the menu titles update at once).
    private func settle(_ seconds: TimeInterval = 0.8) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
        }
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSApp.mainMenu)
    }
}
