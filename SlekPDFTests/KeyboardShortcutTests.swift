import XCTest
@testable import SlekPDF

/// Preferences ▸ Keyboard Shortcuts model (Figma 251:284): defaults, conflicts, replace, persistence.
@MainActor
final class KeyboardShortcutTests: XCTestCase {
    private func store() -> ShortcutStore {
        ShortcutStore(defaults: UserDefaults(suiteName: "shortcuts-\(UUID())")!)
    }

    func testDefaultsMatchTheKeyboardShortcutsPanel() {
        let store = store()
        XCTAssertEqual(store.shortcut(.openPDF)?.display, "⌘O")
        XCTAssertEqual(store.shortcut(.saveACopy)?.display, "⇧⌘S")
        XCTAssertEqual(store.shortcut(.showPageSidebar)?.display, "⌥⌘S")
        XCTAssertEqual(store.shortcut(.enterFullScreen)?.display, "⌃⌘F")
        XCTAssertEqual(store.shortcut(.zoomOut)?.display, "⌘−")
        XCTAssertEqual(store.shortcut(.previousPage)?.display, "⌘↑")
        XCTAssertEqual(store.shortcut(.showPreviousTab)?.display, "⌃⇧⇥")
        XCTAssertEqual(store.shortcut(.saveACopy)?.keyCaps, ["⇧⌘", "S"])
        XCTAssertNil(store.shortcut(.fitWidth))
        XCTAssertFalse(ShortcutCommand.selectTool.isEditable, "V is a canvas tool key")
    }

    func testDefaultsHaveNoDuplicateKeys() {
        let shortcuts = ShortcutCommand.allCases.compactMap(\.defaultShortcut)
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
    }

    func testConflictReplaceAndRemove() {
        let store = store()
        let keys = KeyShortcut("s", [.command])
        XCTAssertEqual(store.conflict(for: keys, excluding: .fitWidth), .saveWork)
        store.replace(keys, for: .fitWidth)
        XCTAssertEqual(store.shortcut(.fitWidth), keys)
        XCTAssertNil(store.shortcut(.saveWork), "Replace takes the keys away from Save work")
        XCTAssertEqual(store.customCommands, [.fitWidth])
        store.set(nil, for: .fitWidth)
        XCTAssertTrue(store.customCommands.isEmpty)
        store.restoreDefaults()
        XCTAssertEqual(store.shortcut(.saveWork), keys)
    }

    func testChangesPersist() {
        let defaults = UserDefaults(suiteName: "shortcuts-\(UUID())")!
        let first = ShortcutStore(defaults: defaults)
        first.set(KeyShortcut("w", [.control, .command]), for: .export)
        first.set(nil, for: .print)
        let second = ShortcutStore(defaults: defaults)
        XCTAssertEqual(second.shortcut(.export)?.display, "⌃⌘W")
        XCTAssertNil(second.shortcut(.print))
        XCTAssertEqual(second.shortcut(.openPDF)?.display, "⌘O")
    }

    func testCustomShortcutsNeedCommandOptionOrControl() {
        XCTAssertFalse(KeyShortcut("k", []).isValidCustom)
        XCTAssertFalse(KeyShortcut("k", [.shift]).isValidCustom)
        XCTAssertTrue(KeyShortcut("k", [.option]).isValidCustom)
    }
}
