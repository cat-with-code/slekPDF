import AppKit
import SwiftUI

/// One key combination, e.g. ⌃⌘W. `key` is a lowercase letter, a symbol, or one of ↑ ↓ ← → ⌫ ⇥ ↩.
struct KeyShortcut: Hashable, Codable {
    enum Modifier: String, Codable, CaseIterable {
        case control, option, shift, command   // display order on macOS: ⌃ ⌥ ⇧ ⌘

        var glyph: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    var key: String
    var modifiers: Set<Modifier>

    init(_ key: String, _ modifiers: Set<Modifier> = [.command]) {
        self.key = key
        self.modifiers = modifiers
    }

    /// "⌥⌘S", as in menus and tooltips.
    var display: String { modifierGlyphs + keyGlyph }
    var modifierGlyphs: String { Modifier.allCases.filter(modifiers.contains).map(\.glyph).joined() }
    var keyGlyph: String { key == "-" ? "−" : key.uppercased() }
    /// Key caps for Shortcut Rows: modifiers together, then the key (Figma Key Caps).
    var keyCaps: [String] { modifiers.isEmpty ? [keyGlyph] : [modifierGlyphs, keyGlyph] }

    /// Preferences rule (Keyboard Shortcuts panel): custom shortcuts must include ⌘, ⌥ or ⌃.
    var isValidCustom: Bool { !modifiers.isDisjoint(with: [.command, .option, .control]) }

    var keyboardShortcut: KeyboardShortcut {
        var flags: EventModifiers = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return KeyboardShortcut(keyEquivalent, modifiers: flags)
    }

    private var keyEquivalent: KeyEquivalent {
        switch key {
        case "↑": .upArrow
        case "↓": .downArrow
        case "←": .leftArrow
        case "→": .rightArrow
        case "⌫": .delete
        case "⇥": .tab
        case "↩": .return
        default: KeyEquivalent(Character(key))
        }
    }

    /// For native menu items (`NSMenuItem.keyEquivalent`).
    var menuKeyEquivalent: String {
        switch key {
        case "↑": "\u{F700}"
        case "↓": "\u{F701}"
        case "←": "\u{F702}"
        case "→": "\u{F703}"
        case "⌫": "\u{8}"
        case "⇥": "\t"
        case "↩": "\r"
        default: key
        }
    }

    var menuModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    /// The combination a key press makes, or nil for a key that can't be a shortcut.
    init?(event: NSEvent) {
        let special: [UInt16: String] = [126: "↑", 125: "↓", 123: "←", 124: "→", 51: "⌫", 48: "⇥", 36: "↩"]
        var mods = Set<Modifier>()
        let flags = event.modifierFlags
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        if let symbol = special[event.keyCode] {
            self.init(symbol, mods)
            return
        }
        guard let first = event.charactersIgnoringModifiers?.first, !first.isWhitespace else { return nil }
        // A shifted symbol (?, +) already carries the Shift: store the symbol alone, as the menus do.
        if !first.isLetter, !first.isNumber, mods.contains(.shift), !"-=,./;'[]\\`".contains(first) { mods.remove(.shift) }
        self.init(String(first).lowercased(), mods)
    }
}

/// Every command in the Keyboard Shortcuts panel (Figma 251:284), grouped like the menus, with its default keys.
enum ShortcutCommand: String, CaseIterable, Codable {
    // Slek PDF
    case preferences, quit
    // File
    case openPDF, close, saveWork, saveACopy, export, print
    // Edit
    case undo, redo, cut, copy, paste, selectAll, find, focusSearch, nextMatch, previousMatch
    // View
    case read, organizePages, annotate, khmerOCR, exportWorkspace, zoomIn, zoomOut, fitPage, showPageSidebar, showInspector, enterFullScreen
    // Document
    case previousPage, nextPage, goToPage, rotateLeft, rotateRight, movePageEarlier, movePageLater, deleteSelectedPages
    // Tools
    case selectTool, editTextTool, addTextTool, highlightTool, commentTool, recognizeText, reviewOCR, markReviewed
    // Window & Help
    case minimize, showNextTab, showPreviousTab, slekPDFHelp, keyboardShortcuts
    // No default keys; can be given a custom shortcut.
    case fitWidth, mergePDFs, splitIntoPDFs, insertPages, exportSearchablePDF, about, developer, releaseNotes, privacyLicenses, reportProblem, zoomWindow

    enum Group: CaseIterable {
        case custom, slekPDF, file, edit, view, document, tools, windowHelp

        var title: CopyKey {
            switch self {
            case .custom: .custom
            case .slekPDF: .slekPDF
            case .file: .file
            case .edit: .edit
            case .view: .view
            case .document: .document2
            case .tools: .tools
            case .windowHelp: .windowHelp
            }
        }
    }

    var group: Group {
        switch self {
        case .preferences, .quit, .about, .developer: .slekPDF
        case .openPDF, .close, .saveWork, .saveACopy, .export, .print, .mergePDFs: .file
        case .undo, .redo, .cut, .copy, .paste, .selectAll, .find, .focusSearch, .nextMatch, .previousMatch: .edit
        case .read, .organizePages, .annotate, .khmerOCR, .exportWorkspace, .zoomIn, .zoomOut, .fitPage, .fitWidth, .showPageSidebar,
             .showInspector, .enterFullScreen: .view
        case .previousPage, .nextPage, .goToPage, .rotateLeft, .rotateRight, .movePageEarlier, .movePageLater, .deleteSelectedPages,
             .splitIntoPDFs, .insertPages: .document
        case .selectTool, .editTextTool, .addTextTool, .highlightTool, .commentTool, .recognizeText, .reviewOCR, .markReviewed, .exportSearchablePDF: .tools
        case .minimize, .showNextTab, .showPreviousTab, .slekPDFHelp, .keyboardShortcuts, .zoomWindow, .releaseNotes, .privacyLicenses,
             .reportProblem: .windowHelp
        }
    }

    /// Row title in Preferences ▸ Keyboard Shortcuts (Figma copy).
    var title: CopyKey {
        switch self {
        case .preferences: .preferences2
        case .quit: .quitSlekPDF
        case .openPDF: .openPDF2
        case .close: .close
        case .saveWork: .saveWork
        case .saveACopy: .saveACopy2
        case .export: .export2
        case .print: .print2
        case .undo: .undo
        case .redo: .redo
        case .cut: .cut
        case .copy: .copy
        case .paste: .paste
        case .selectAll: .selectAll
        case .find: .find
        case .focusSearch: .focusSearchField
        case .nextMatch: .nextMatch
        case .previousMatch: .previousMatch
        case .read: .read
        case .organizePages: .organizePages
        case .annotate: .annotate
        case .khmerOCR: .khmerOCR
        case .exportWorkspace: .export
        case .zoomIn: .zoomIn
        case .zoomOut: .zoomOut
        case .fitPage: .fitPage
        case .showPageSidebar: .showPageSidebar2
        case .showInspector: .showInspector2
        case .enterFullScreen: .enterFullScreen
        case .previousPage: .previousPage
        case .nextPage: .nextPage
        case .goToPage: .goToPage
        case .rotateLeft: .rotateLeft
        case .rotateRight: .rotateRight
        case .movePageEarlier: .movePageEarlier
        case .movePageLater: .movePageLater
        case .deleteSelectedPages: .deleteSelectedPages
        case .selectTool: .select
        case .editTextTool: .editPDFText2
        case .addTextTool: .addKhmerText
        case .highlightTool: .highlightText
        case .commentTool: .addComment
        case .recognizeText: .recognizeText2
        case .reviewOCR: .reviewOCR
        case .markReviewed: .markReviewed
        case .minimize: .minimize
        case .showNextTab: .showNextTab
        case .showPreviousTab: .showPreviousTab
        case .slekPDFHelp: .slekPDFHelp
        case .keyboardShortcuts: .keyboardShortcuts
        case .fitWidth: .menuFitWidth
        case .mergePDFs: .menuMergePDFs
        case .splitIntoPDFs: .menuSplitIntoPDFs
        case .insertPages: .menuInsertPagesFromFile
        case .exportSearchablePDF: .menuExportSearchablePDF
        case .about: .menuAboutSlekPDF
        case .developer: .menuDeveloper
        case .releaseNotes: .menuReleaseNotes
        case .privacyLicenses: .menuPrivacyLicenses
        case .reportProblem: .menuReportAProblem
        case .zoomWindow: .menuZoom
        }
    }

    /// Menu title for the Add custom shortcut command picker ("File ▸ Merge PDFs…").
    var menuTitle: CopyKey {
        switch self {
        case .minimize, .showNextTab, .showPreviousTab, .zoomWindow: return .menuWindow
        default: break
        }
        switch group {
        case .slekPDF, .custom: return .menuSlekPDF
        case .file: return .menuFile
        case .edit: return .menuEdit
        case .view: return .menuView
        case .document: return .menuDocument
        case .tools: return .menuTools
        case .windowHelp: return .menuHelp
        }
    }

    /// Defaults from the Keyboard Shortcuts panel and the menus.
    var defaultShortcut: KeyShortcut? {
        let cmd: Set<KeyShortcut.Modifier> = [.command]
        switch self {
        case .preferences: return KeyShortcut(",", cmd)
        case .quit: return KeyShortcut("q", cmd)
        case .openPDF: return KeyShortcut("o", cmd)
        case .close: return KeyShortcut("w", cmd)
        case .saveWork: return KeyShortcut("s", cmd)
        case .saveACopy: return KeyShortcut("s", [.shift, .command])
        case .export: return KeyShortcut("e", cmd)
        case .print: return KeyShortcut("p", cmd)
        case .undo: return KeyShortcut("z", cmd)
        case .redo: return KeyShortcut("z", [.shift, .command])
        case .cut: return KeyShortcut("x", cmd)
        case .copy: return KeyShortcut("c", cmd)
        case .paste: return KeyShortcut("v", cmd)
        case .selectAll: return KeyShortcut("a", cmd)
        case .find: return KeyShortcut("f", cmd)
        case .focusSearch: return KeyShortcut("k", cmd)
        case .nextMatch: return KeyShortcut("g", cmd)
        case .previousMatch: return KeyShortcut("g", [.shift, .command])
        case .read: return KeyShortcut("1", cmd)
        case .organizePages: return KeyShortcut("2", cmd)
        case .annotate: return KeyShortcut("3", cmd)
        case .khmerOCR: return KeyShortcut("4", cmd)
        case .exportWorkspace: return KeyShortcut("5", cmd)
        case .zoomIn: return KeyShortcut("+", cmd)
        case .zoomOut: return KeyShortcut("-", cmd)
        case .fitPage: return KeyShortcut("0", cmd)
        case .showPageSidebar: return KeyShortcut("s", [.option, .command])
        case .showInspector: return KeyShortcut("i", [.option, .command])
        case .enterFullScreen: return KeyShortcut("f", [.control, .command])
        case .previousPage: return KeyShortcut("↑", cmd)
        case .nextPage: return KeyShortcut("↓", cmd)
        case .goToPage: return KeyShortcut("l", cmd)
        case .rotateLeft: return KeyShortcut("[", cmd)
        case .rotateRight: return KeyShortcut("]", cmd)
        case .movePageEarlier: return KeyShortcut("↑", [.option, .command])
        case .movePageLater: return KeyShortcut("↓", [.option, .command])
        case .deleteSelectedPages: return KeyShortcut("⌫", cmd)
        case .selectTool: return KeyShortcut("v", [])
        case .editTextTool: return KeyShortcut("e", [])
        case .addTextTool: return KeyShortcut("t", [])
        case .highlightTool: return KeyShortcut("h", [])
        case .commentTool: return KeyShortcut("c", [])
        case .recognizeText: return KeyShortcut("r", [.option, .command])
        case .reviewOCR: return KeyShortcut("o", [.option, .command])
        case .markReviewed: return KeyShortcut("↩", [])
        case .minimize: return KeyShortcut("m", cmd)
        case .showNextTab: return KeyShortcut("⇥", [.control])
        case .showPreviousTab: return KeyShortcut("⇥", [.control, .shift])
        case .slekPDFHelp: return KeyShortcut("?", cmd)
        case .keyboardShortcuts: return KeyShortcut("/", cmd)
        case .fitWidth, .mergePDFs, .splitIntoPDFs, .insertPages, .exportSearchablePDF, .about, .developer, .releaseNotes,
             .privacyLicenses, .reportProblem, .zoomWindow:
            return nil
        }
    }

    /// Single-key tool keys (V, T, H, C, ↩) belong to the canvas and can't be changed.
    var isEditable: Bool { defaultShortcut.map(\.isValidCustom) ?? true }
}

/// The user's keyboard shortcuts: Figma defaults plus changes, stored on this Mac. Menus read their keys here,
/// so a change applies immediately.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    /// A stored nil means the user removed that command's shortcut.
    @Published private(set) var overrides: [ShortcutCommand: KeyShortcut?] = [:]
    private let defaults: UserDefaults
    private let key = "keyboardShortcutOverrides"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode([String: KeyShortcut?].self, from: data) {
            for (name, value) in stored {
                if let command = ShortcutCommand(rawValue: name) { overrides[command] = .some(value) }
            }
        }
    }

    func shortcut(_ command: ShortcutCommand) -> KeyShortcut? {
        if let override = overrides[command] { return override }
        return command.defaultShortcut
    }

    func isChanged(_ command: ShortcutCommand) -> Bool { overrides[command] != nil }

    /// Commands that have a shortcut only because the user added one (Figma "Custom" group).
    var customCommands: [ShortcutCommand] {
        ShortcutCommand.allCases.filter { $0.defaultShortcut == nil && shortcut($0) != nil }
    }

    /// The other command already using these keys, if any.
    func conflict(for shortcut: KeyShortcut, excluding command: ShortcutCommand?) -> ShortcutCommand? {
        ShortcutCommand.allCases.first { $0 != command && self.shortcut($0) == shortcut }
    }

    func set(_ shortcut: KeyShortcut?, for command: ShortcutCommand) {
        if shortcut == command.defaultShortcut {
            overrides.removeValue(forKey: command)
        } else {
            overrides[command] = .some(shortcut)
        }
        save()
    }

    /// Gives the keys to `command`, taking them away from whichever command had them.
    func replace(_ shortcut: KeyShortcut, for command: ShortcutCommand) {
        if let other = conflict(for: shortcut, excluding: command) { set(nil, for: other) }
        set(shortcut, for: command)
    }

    func restoreDefaults() {
        overrides = [:]
        save()
    }

    private func save() {
        var stored: [String: KeyShortcut?] = [:]
        for (command, value) in overrides { stored[command.rawValue] = .some(value) }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
    }
}

extension View {
    /// The user's current keys for a menu command (none if removed).
    func shortcut(_ command: ShortcutCommand) -> some View {
        keyboardShortcut(ShortcutStore.shared.shortcut(command)?.keyboardShortcut)
    }
}
