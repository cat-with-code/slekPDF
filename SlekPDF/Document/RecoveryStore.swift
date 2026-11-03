import Foundation

/// Recovery copies (Preferences ▸ Keep recovery copies on this Mac; Figma 15 Recovered unfinished work).
/// While a window has unsaved changes, its editable work is written here a few seconds after each change; saving or
/// closing the window removes it. Anything left at launch means Slek PDF closed unexpectedly.
@MainActor
final class RecoveryStore {
    static let shared = RecoveryStore()

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        /// The document's file name, shown in the dialog and used when reopening.
        let fileName: String
        let date: Date
        let changes: Int
    }

    /// Offered once per launch (Not now keeps the copies for next time).
    var offeredThisLaunch = false
    var folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "keepRecoveryCopies") as? Bool ?? true }

    func pdfURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).pdf") }
    private func manifestURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    /// Recovery copies on disk, newest first (entries whose PDF is missing are ignored).
    func entries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: pdfURL($0.id).path) }
            .sorted { $0.date > $1.date }
    }

    /// Writes `session`'s work as recovery copy `id`.
    func write(_ session: DocumentSession, id: UUID) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await PDFiumService.shared.writePDF(session.editedPageSources(), to: pdfURL(id))
        let entry = Entry(id: id, fileName: session.fileName ?? "Document.pdf", date: Date(), changes: session.changesSinceSave)
        try JSONEncoder().encode(entry).write(to: manifestURL(id), options: .atomic)
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: pdfURL(id))
        try? FileManager.default.removeItem(at: manifestURL(id))
    }

    /// The recovery copy under its document's own name (in a private temporary folder), ready to open.
    func openableCopy(of entry: Entry) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Recovered-\(entry.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(entry.fileName)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: pdfURL(entry.id), to: url)
        return url
    }
}
