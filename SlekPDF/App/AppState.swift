import AppKit
import SwiftUI

/// Workspaces from the Figma "Workspace Tabs" component (98:331).
enum Workspace: CaseIterable, Identifiable {
    case read, organizePages, annotate, khmerOCR, export

    var id: Self { self }

    var title: CopyKey {
        switch self {
        case .read: .read
        case .organizePages: .organizePages
        case .annotate: .annotate
        case .khmerOCR: .khmerOCR
        case .export: .export
        }
    }

    var icon: DSIcon {
        switch self {
        case .read: .bookOpen
        case .organizePages: .viewGridCard
        case .annotate: .comment
        case .khmerOCR: .textRecognition
        case .export: .download
        }
    }
}

/// Preferences ▸ Default OCR language.
enum OCRLanguage: String, CaseIterable {
    case khmer, khmerEnglish, english
}

enum AppearancePreference: String, CaseIterable {
    case system, light, dark

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// App-wide settings shared by all windows (per-window state lives in `DocumentSession`). ObservableObject (not @Observable, which needs macOS 14) because the deployment target is macOS 13.
final class AppState: ObservableObject {
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published var appearance: AppearancePreference {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    // Preferences ▸ General (Figma 10 Preferences). Read by OCR, recovery and export as those features land.
    @Published var ocrLanguage: OCRLanguage {
        didSet { defaults.set(ocrLanguage.rawValue, forKey: Keys.ocrLanguage) }
    }

    @Published var keepRecoveryCopies: Bool {
        didSet { defaults.set(keepRecoveryCopies, forKey: Keys.keepRecoveryCopies) }
    }

    @Published var showOCRConfidenceHints: Bool {
        didSet { defaults.set(showOCRConfidenceHints, forKey: Keys.showOCRConfidenceHints) }
    }

    /// nil = the user's Documents folder. Kept as a security-scoped bookmark so the sandbox allows writing there.
    @Published private(set) var exportFolder: URL?

    private let defaults: UserDefaults

    private enum Keys {
        static let language = "interfaceLanguage"
        static let appearance = "appearance"
        static let ocrLanguage = "defaultOCRLanguage"
        static let keepRecoveryCopies = "keepRecoveryCopies"
        static let showOCRConfidenceHints = "showOCRConfidenceHints"
        static let exportFolder = "defaultExportFolderBookmark"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:)) ?? .km
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearancePreference.init(rawValue:)) ?? .system
        ocrLanguage = defaults.string(forKey: Keys.ocrLanguage).flatMap(OCRLanguage.init(rawValue:)) ?? .khmerEnglish
        keepRecoveryCopies = defaults.object(forKey: Keys.keepRecoveryCopies) as? Bool ?? true
        showOCRConfidenceHints = defaults.object(forKey: Keys.showOCRConfidenceHints) as? Bool ?? true
        if let bookmark = defaults.data(forKey: Keys.exportFolder) {
            var stale = false
            exportFolder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    /// A folder the user picked in an Open panel, or nil for Documents.
    func setExportFolder(_ url: URL?) {
        exportFolder = url
        if let url, let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bookmark, forKey: Keys.exportFolder)
        } else {
            defaults.removeObject(forKey: Keys.exportFolder)
        }
    }

    /// Theme is applied app-wide so every window, sheet and menu follows the status-bar switch.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }
}
