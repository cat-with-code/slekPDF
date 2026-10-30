import Foundation

/// Recently opened PDFs, shared by all windows. Stored as app-scoped security-scoped bookmarks
/// so the sandboxed app can reopen them after relaunch.
@MainActor
final class RecentDocuments: ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id: Data { bookmark }
        var bookmark: Data
        var name: String
        var lastOpened: Date
    }

    @Published private(set) var entries: [Entry] = []
    /// Resolved file per entry (nil = moved, deleted or no longer readable). Filled by `refresh()`,
    /// never during a view update.
    @Published private(set) var resolvedURLs: [Data: URL] = [:]
    private let defaults: UserDefaults
    private let key = "recentDocuments"
    private let limit = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
        refresh()
    }

    func add(_ url: URL) {
        guard let bookmark = Self.bookmark(for: url) else { return }
        entries.removeAll { resolve($0.bookmark)?.0.standardizedFileURL == url.standardizedFileURL }
        entries.insert(Entry(bookmark: bookmark, name: url.lastPathComponent, lastOpened: Date()), at: 0)
        entries = Array(entries.prefix(limit))
        save()
        refresh()
    }

    func url(for entry: Entry) -> URL? { resolvedURLs[entry.bookmark] }

    /// Resolves every entry (disk access): call when the start screen appears or after a change.
    /// Stale bookmarks are renewed in place.
    func refresh() {
        var resolved: [Data: URL] = [:]
        var renewed = false
        for index in entries.indices {
            guard let (url, fresh) = resolve(entries[index].bookmark) else { continue }
            if let fresh {
                entries[index].bookmark = fresh
                renewed = true
            }
            resolved[entries[index].bookmark] = url
        }
        if renewed { save() }
        resolvedURLs = resolved
    }

    /// Security-scoped for files the user picked or dropped; a plain bookmark for files the app can
    /// already read (the sandbox refuses security scope for those).
    private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    /// The file a bookmark points to if it still exists and is readable, plus renewed bookmark data when stale.
    private func resolve(_ bookmark: Data) -> (URL, Data?)? {
        var stale = false
        let url = (try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { return nil }
        // Check while holding the sandbox access the bookmark grants; outside it, user files look absent.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return (url, stale ? Self.bookmark(for: url) : nil)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}

nonisolated enum DisplayPath {
    /// The user's real home folder (inside the sandbox, NSHomeDirectory() is the app container).
    static let home: String = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }()

    /// "~/Documents/School" for a file in that folder.
    static func folder(of url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}

nonisolated enum RecentDateFormatter {
    /// Figma: "Yesterday 16:40" / "Monday" / "12 Oct" (Khmer: "ម្សិលមិញ ១៦:៤០" / "ថ្ងៃច័ន្ទ" / "១២ តុលា").
    static func string(_ date: Date, language: AppLanguage, now: Date = Date(), calendar: Calendar = .current) -> String {
        let locale = Locale(identifier: language == .km ? "km_KH@numbers=khmr" : "en_GB")
        let formatter = DateFormatter()
        formatter.locale = locale
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0, 1:
            let relative = RelativeDateTimeFormatter()
            relative.locale = locale
            relative.dateTimeStyle = .named
            relative.formattingContext = .beginningOfSentence
            formatter.dateFormat = "HH:mm"
            return relative.localizedString(from: DateComponents(day: -days)) + " " + formatter.string(from: date)
        case 2..<7:
            formatter.dateFormat = "EEEE"
            return (language == .km ? "ថ្ងៃ" : "") + formatter.string(from: date)
        default:
            formatter.dateFormat = "d MMM"
            return formatter.string(from: date)
        }
    }
}
