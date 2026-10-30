import SwiftUI

/// Interface language. Mirrors the Figma Typography collection modes (Khmer is the default).
enum AppLanguage: String, CaseIterable, Sendable {
    case km
    case en
}

/// Khmer/English strings exported from the Figma `Copy/*` variables.
/// The app switches language live (status bar switch, View ▸ Interface Language), independent of the system language,
/// so strings come from this catalog rather than from `Localizable.strings`.
struct CopyCatalog: Sendable {
    private let entries: [String: [String: String]]

    static let shared = CopyCatalog(bundle: .main)

    init(bundle: Bundle) {
        guard let url = bundle.url(forResource: "copy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else {
            assertionFailure("copy.json is missing from the app bundle")
            entries = [:]
            return
        }
        entries = decoded
    }

    var keys: [String] { Array(entries.keys) }

    func string(_ key: CopyKey, _ language: AppLanguage) -> String {
        string(raw: key.rawValue, language)
    }

    func string(raw key: String, _ language: AppLanguage) -> String {
        guard let value = entries[key]?[language.rawValue] else {
            assertionFailure("Missing copy for \(key) [\(language.rawValue)]")
            return key
        }
        return value
    }
}

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .km
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}
