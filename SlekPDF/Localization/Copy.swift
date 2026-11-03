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

    /// English plural variants of "fmt: N results on M pages" (Khmer has no plural form).
    func resultsSummary(results: Int, pages: Int, _ language: AppLanguage) -> String {
        let entry = entries[CopyKey.fmtNResultsOnMPages.rawValue] ?? [:]
        let template: String? = switch (language, results, pages) {
        case (.en, 1, _): entry["en_result1"]
        case (.en, _, 1): entry["en_page1"]
        default: entry[language.rawValue]
        }
        return (template ?? "{0} / {1}")
            .replacingOccurrences(of: "{0}", with: language.number(results))
            .replacingOccurrences(of: "{1}", with: language.number(pages))
    }

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

extension AppLanguage {
    /// Numbers as the prototype shows them: Khmer digits (០–៩) in the Khmer interface.
    func number(_ value: Int) -> String {
        let latin = String(value)
        guard self == .km else { return latin }
        return String(latin.unicodeScalars.map { scalar in
            guard let digit = Int(String(scalar)) else { return Character(scalar) }
            return Character(Unicode.Scalar(0x17E0 + UInt32(digit))!)
        })
    }
}

extension CopyCatalog {
    /// Fills `{0}`, `{1}`… in a template entry. Integers use the language's digits.
    /// `format` with an English singular variant (`en_one`) when `count` is 1; Khmer has one form.
    func count(_ key: CopyKey, _ language: AppLanguage, _ count: Int, _ arguments: Any...) -> String {
        var text = (language == .en && count == 1 ? entries[key.rawValue]?["en_one"] : nil) ?? string(key, language)
        for (index, argument) in ([count] + arguments).enumerated() {
            let value = (argument as? Int).map(language.number) ?? "\(argument)"
            text = text.replacingOccurrences(of: "{\(index)}", with: value)
        }
        return text
    }

    /// `format`, using the English singular variant (`en_one`) when `singular` is true.
    func variant(_ key: CopyKey, _ language: AppLanguage, singular: Bool, _ arguments: Any...) -> String {
        var text = (language == .en && singular ? entries[key.rawValue]?["en_one"] : nil) ?? string(key, language)
        for (index, argument) in arguments.enumerated() {
            let value = (argument as? Int).map(language.number) ?? "\(argument)"
            text = text.replacingOccurrences(of: "{\(index)}", with: value)
        }
        return text
    }

    func format(_ key: CopyKey, _ language: AppLanguage, _ arguments: Any...) -> String {
        var text = string(key, language)
        for (index, argument) in arguments.enumerated() {
            let value = (argument as? Int).map(language.number) ?? "\(argument)"
            text = text.replacingOccurrences(of: "{\(index)}", with: value)
        }
        return text
    }
}
