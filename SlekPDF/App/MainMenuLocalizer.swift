import AppKit
import Combine

/// Gives the parts of the menu bar that SwiftUI and AppKit create — the File/Edit/View/Window/Help titles and
/// the native Undo, pasteboard, Dictation and Window items — the interface language's copy, and hides the
/// system items the Figma menus leave out (Delete, AutoFill, Emoji & Symbols).
///
/// Native items are matched by their action, never by title or position. SwiftUI may rebuild the menus at any
/// time (language change, focus change), so the pass runs again whenever a menu item is added or changed and
/// right before a menu opens; it only writes when something differs, so its own changes end the loop.
@MainActor
final class MainMenuLocalizer {
    static let shared = MainMenuLocalizer()

    private var language: AppLanguage = .km
    private var languageSubscription: AnyCancellable?
    private var shortcutSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var isScheduled = false

    /// Native items' titles, by action.
    private static let titles: [String: CopyKey] = [
        "undo:": .menuUndo,
        "redo:": .menuRedo,
        "cut:": .menuCut,
        "copy:": .menuCopy,
        "paste:": .menuPaste,
        "selectAll:": .menuSelectAll,
        "startDictation:": .menuStartDictation,
        "performMiniaturize:": .menuMinimize,
        "performZoom:": .menuZoom,
        "selectPreviousTab:": .menuShowPreviousTab,
        "selectNextTab:": .menuShowNextTab,
        "arrangeInFront:": .menuBringAllToFront,
    ]

    /// Native items whose keys come from the user's shortcuts (Preferences ▸ Keyboard Shortcuts), by action.
    private static let shortcuts: [String: ShortcutCommand] = [
        "undo:": .undo, "redo:": .redo, "cut:": .cut, "copy:": .copy, "paste:": .paste, "selectAll:": .selectAll,
        "performMiniaturize:": .minimize, "performZoom:": .zoomWindow, "selectNextTab:": .showNextTab, "selectPreviousTab:": .showPreviousTab,
    ]

    /// Native items not in the Figma menus, by action.
    private static let hiddenActions: Set<String> = ["delete:", "orderFrontCharacterPalette:"]
    /// A submenu holding one of these actions is hidden as a whole (Edit ▸ AutoFill).
    private static let hiddenSubmenuActions: Set<String> = ["_handleInsertFromContactsCommand:", "_handleInsertFromPasswordsCommand:"]

    /// Top-level menus SwiftUI creates, by the English title it gives them.
    private static let standardMenus: [(english: String, key: CopyKey)] = [
        ("File", .menuFile), ("Edit", .menuEdit), ("View", .menuView), ("Window", .menuWindow), ("Help", .menuHelp),
    ]

    func start(_ appState: AppState) {
        guard languageSubscription == nil else { return }
        languageSubscription = appState.$language.sink { [weak self] language in
            self?.language = language
            self?.schedule()
        }
        shortcutSubscription = ShortcutStore.shared.objectWillChange.sink { [weak self] in self?.schedule() }
        let center = NotificationCenter.default
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MainMenuLocalizer.shared.schedule() }
            })
        }
        // Opening a menu: correct it now, before it is drawn.
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MainMenuLocalizer.shared.apply() }
        })
        schedule()
    }

    /// Coalesces bursts of menu changes into one pass on the next run-loop turn.
    private func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    func apply() {
        isScheduled = false
        guard let mainMenu = NSApp.mainMenu else { return }
        let catalog = CopyCatalog.shared
        for item in mainMenu.items {
            guard let menu = item.submenu else { continue }
            if let key = standardMenuKey(item, menu) {
                let title = catalog.string(key, language)
                if item.title != title { item.title = title }
                if menu.title != title { menu.title = title }
            }
            localizeItems(in: menu, catalog)
        }
    }

    private func standardMenuKey(_ item: NSMenuItem, _ menu: NSMenu) -> CopyKey? {
        if menu === NSApp.windowsMenu { return .menuWindow }
        if menu === NSApp.helpMenu { return .menuHelp }
        let catalog = CopyCatalog.shared
        return Self.standardMenus.first { entry in
            [entry.english, catalog.string(entry.key, .km), catalog.string(entry.key, .en)].contains(item.title)
        }?.key
    }

    private func localizeItems(in menu: NSMenu, _ catalog: CopyCatalog) {
        for item in menu.items {
            if let action = item.action.map(NSStringFromSelector) {
                if let key = Self.titles[action] {
                    let title = catalog.string(key, language)
                    if item.title != title { item.title = title }
                    if let command = Self.shortcuts[action], !item.isHidden {
                        let shortcut = ShortcutStore.shared.shortcut(command)
                        let equivalent = shortcut?.menuKeyEquivalent ?? ""
                        if item.keyEquivalent != equivalent { item.keyEquivalent = equivalent }
                        let mask = shortcut?.menuModifierMask ?? []
                        if item.keyEquivalentModifierMask != mask { item.keyEquivalentModifierMask = mask }
                    }
                } else if Self.hiddenActions.contains(action), !item.isHidden {
                    item.isHidden = true
                }
            }
            guard let submenu = item.submenu else { continue }
            let hidesWhole = submenu.items.contains { $0.action.map(NSStringFromSelector).map(Self.hiddenSubmenuActions.contains) == true }
            if hidesWhole {
                if !item.isHidden { item.isHidden = true }
            } else {
                localizeItems(in: submenu, catalog)
            }
        }
        tidySeparators(in: menu)
    }

    /// Empty SwiftUI groups (Services, Hide, …) and hidden items leave separators next to each other or at an
    /// edge; show only those that sit between two visible items, as in Figma.
    /// Each separator's state is decided once and written only if it differs: writing it twice in one pass would
    /// post change notifications that schedule the next pass, forever.
    private func tidySeparators(in menu: NSMenu) {
        let items = menu.items
        var shows = [Bool](repeating: false, count: items.count)
        var pendingSeparator: Int?  // a separator waiting for a visible item after it
        var hasItemBefore = false   // a leading separator is never needed
        for (index, item) in items.enumerated() {
            if item.isSeparatorItem {
                if hasItemBefore, pendingSeparator == nil { pendingSeparator = index }
            } else if !item.isHidden {
                if let separator = pendingSeparator { shows[separator] = true }  // trailing ones stay hidden
                pendingSeparator = nil
                hasItemBefore = true
            }
        }
        for (index, item) in items.enumerated() where item.isSeparatorItem && item.isHidden == shows[index] {
            item.isHidden = !shows[index]
        }
    }
}
