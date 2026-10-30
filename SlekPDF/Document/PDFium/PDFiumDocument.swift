import Foundation
import PDFium

/// Errors reported by PDFium's `FPDF_GetLastError`.
nonisolated enum PDFiumError: Error, Equatable {
    case file, format, password, security, page, unknown(UInt)
    case saveFailed

    static func last() -> PDFiumError {
        switch FPDF_GetLastError() {
        case UInt(FPDF_ERR_FILE): .file
        case UInt(FPDF_ERR_FORMAT): .format
        case UInt(FPDF_ERR_PASSWORD): .password
        case UInt(FPDF_ERR_SECURITY): .security
        case UInt(FPDF_ERR_PAGE): .page
        case let code: .unknown(code)
        }
    }
}

/// PDFium is used for Khmer text extraction/search and for writing delivered copies without
/// redrawing original pages (see docs/spikes/01-pdfkit-khmer.md). PDFKit still displays pages.
/// PDFium is not thread-safe: use all PDFium objects from one thread/actor at a time (main actor for now;
/// later a dedicated actor or a sandboxed helper process).
nonisolated final class PDFiumDocument {
    private static let initialized: Bool = {
        FPDF_InitLibrary()
        return true
    }()

    let handle: FPDF_DOCUMENT

    init(url: URL, password: String? = nil) throws {
        _ = Self.initialized
        guard let document = url.withUnsafeFileSystemRepresentation({ path in FPDF_LoadDocument(path, password) }) else {
            throw PDFiumError.last()
        }
        handle = document
    }

    /// New empty document.
    init() {
        _ = Self.initialized
        handle = FPDF_CreateNewDocument()
    }

    deinit {
        FPDF_CloseDocument(handle)
    }

    var pageCount: Int { Int(FPDF_GetPageCount(handle)) }

    /// Unicode text of a page as PDFium extracts it (what Chrome copies and searches).
    func text(ofPage index: Int) throws -> String {
        try withTextPage(index) { textPage in
            let count = FPDFText_CountChars(textPage)
            guard count > 0 else { return "" }
            var buffer = [UInt16](repeating: 0, count: Int(count) + 1)
            let written = FPDFText_GetText(textPage, 0, count, &buffer)
            return String(decoding: buffer.prefix(max(Int(written) - 1, 0)), as: UTF16.self)
        }
    }

    /// Number of matches of `query` on a page (case-insensitive by default).
    func matchCount(of query: String, onPage index: Int) throws -> Int {
        try withTextPage(index) { textPage in
            let needle = Array(query.utf16) + [0]
            guard let search = FPDFText_FindStart(textPage, needle, 0, 0) else { return 0 }
            defer { FPDFText_FindClose(search) }
            var count = 0
            while FPDFText_FindNext(search) != 0 { count += 1 }
            return count
        }
    }

    /// Draws page `sourceIndex` of `layer` on top of page `index` as a form XObject.
    /// The original page content stays in place; only a new content stream for the form object is added.
    func overlay(page index: Int, with layer: PDFiumDocument, layerPage sourceIndex: Int = 0) throws {
        guard let xObject = FPDF_NewXObjectFromPage(handle, layer.handle, Int32(sourceIndex)) else { throw PDFiumError.page }
        defer { FPDF_CloseXObject(xObject) }
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        guard let form = FPDF_NewFormObjectFromXObject(xObject) else { throw PDFiumError.page }
        FPDFPage_InsertObject(page, form)
        guard FPDFPage_GenerateContent(page) != 0 else { throw PDFiumError.saveFailed }
    }

    /// Saves to `url`. `incremental` appends changes after the original bytes, leaving them untouched.
    func save(to url: URL, incremental: Bool = true) throws {
        let data = try PDFiumWriter.write { writer in
            FPDF_SaveAsCopy(handle, writer, FPDF_DWORD(incremental ? FPDF_INCREMENTAL : FPDF_NO_INCREMENTAL))
        }
        try data.write(to: url, options: .atomic)
    }

    private func withTextPage<T>(_ index: Int, _ body: (FPDF_TEXTPAGE) throws -> T) throws -> T {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        guard let textPage = FPDFText_LoadPage(page) else { throw PDFiumError.page }
        defer { FPDFText_ClosePage(textPage) }
        return try body(textPage)
    }
}

/// Bridges PDFium's C write callback to a Swift `Data` buffer.
/// The callback only receives the `FPDF_FILEWRITE` pointer, so the buffer's box is stored right after it.
nonisolated private enum PDFiumWriter {
    final class Box { var data = Data() }

    static func write(_ save: (UnsafeMutablePointer<FPDF_FILEWRITE>) -> FPDF_BOOL) throws -> Data {
        let box = Box()
        let stride = MemoryLayout<FPDF_FILEWRITE>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: stride + MemoryLayout<UnsafeRawPointer>.stride,
                                                   alignment: MemoryLayout<FPDF_FILEWRITE>.alignment)
        defer { raw.deallocate() }
        let writer = raw.bindMemory(to: FPDF_FILEWRITE.self, capacity: 1)
        writer.initialize(to: FPDF_FILEWRITE(version: 1, WriteBlock: { this, bytes, size in
            guard let this, let bytes else { return 0 }
            let slot = UnsafeMutableRawPointer(this).advanced(by: MemoryLayout<FPDF_FILEWRITE>.stride)
            let box = Unmanaged<Box>.fromOpaque(slot.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
            box.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(size))
            return 1
        }))
        raw.advanced(by: stride).storeBytes(of: UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque()), as: UnsafeRawPointer.self)
        let ok = withExtendedLifetime(box) { save(writer) }
        guard ok != 0 else { throw PDFiumError.saveFailed }
        return box.data
    }
}
