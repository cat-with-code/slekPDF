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

/// App-wide UI state. ObservableObject (not @Observable) because the deployment target is macOS 12.
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

    @Published var workspace: Workspace = .read
    @Published var isSidebarVisible = true
    @Published var isCompactSidebarShown = false
    @Published var isInspectorVisible = true

    private let defaults: UserDefaults

    private enum Keys {
        static let language = "interfaceLanguage"
        static let appearance = "appearance"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:)) ?? .km
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    /// Theme is applied app-wide so every window, sheet and menu follows the status-bar switch.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }
}
