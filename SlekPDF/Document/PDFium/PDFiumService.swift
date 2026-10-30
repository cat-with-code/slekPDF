import Foundation

/// Serial executor for every PDFium call in the app: PDFium is not thread-safe at the library level,
/// so all documents from all windows share this one actor.
@globalActor
actor PDFiumActor {
    static let shared = PDFiumActor()
}

/// Owns every open `PDFiumDocument`. Documents are opened and closed here, so PDFium's
/// `FPDF_CloseDocument` never runs on another thread.
@PDFiumActor
final class PDFiumService {
    static let shared = PDFiumService()

    struct DocumentID: Hashable, Sendable {
        fileprivate let raw = UUID()
    }

    private var documents: [DocumentID: PDFiumDocument] = [:]

    /// Opens the file (the caller must hold security-scoped access while it stays open). Returns the page count.
    func open(url: URL, password: String? = nil) throws -> (id: DocumentID, pageCount: Int) {
        let document = try PDFiumDocument(url: url, password: password)
        let id = DocumentID()
        documents[id] = document
        return (id, document.pageCount)
    }

    func close(_ id: DocumentID) {
        documents[id] = nil
    }
}
