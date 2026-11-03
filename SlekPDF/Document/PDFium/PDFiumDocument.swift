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

    /// How many characters of a page each font draws (font names without the subset prefix, e.g. "LimonS1").
    /// Spaces and characters PDFium generated are not counted.
    func fontUsage(onPage index: Int) throws -> [String: Int] {
        try withTextPage(index) { textPage in
            var usage: [String: Int] = [:]
            var buffer = [CChar](repeating: 0, count: 256)
            for i in 0..<Int(FPDFText_CountChars(textPage)) {
                let code = FPDFText_GetUnicode(textPage, Int32(i))
                guard code > 0x20, FPDFText_IsGenerated(textPage, Int32(i)) != 1 else { continue }
                let length = FPDFText_GetFontInfo(textPage, Int32(i), &buffer, UInt(buffer.count), nil)
                guard length > 0, length <= buffer.count else { continue }
                var name = String(cString: buffer)
                if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
                    name = String(name[name.index(after: plus)...])
                }
                usage[name, default: 0] += 1
            }
            return usage
        }
    }

    /// Every character PDFium reports on a page, with the geometry the Khmer text rebuilder needs.
    func characters(onPage index: Int) throws -> [PDFiumChar] {
        try withTextPage(index) { textPage in
            let count = Int(FPDFText_CountChars(textPage))
            var chars: [PDFiumChar] = []
            chars.reserveCapacity(count)
            for i in 0..<count {
                let code = FPDFText_GetUnicode(textPage, Int32(i))
                guard code != 0, let scalar = Unicode.Scalar(code) else { continue }
                var x = 0.0, y = 0.0, left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
                FPDFText_GetCharOrigin(textPage, Int32(i), &x, &y)
                FPDFText_GetCharBox(textPage, Int32(i), &left, &right, &bottom, &top)
                var invisible = false
                if let object = FPDFText_GetTextObject(textPage, Int32(i)) {
                    invisible = FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_INVISIBLE
                }
                chars.append(PDFiumChar(index: i, scalar: scalar, isGenerated: FPDFText_IsGenerated(textPage, Int32(i)) == 1,
                                        isInvisible: invisible, origin: CGPoint(x: x, y: y),
                                        box: CGRect(x: left, y: bottom, width: right - left, height: top - bottom),
                                        fontSize: FPDFText_GetFontSize(textPage, Int32(i))))
            }
            return chars
        }
    }

    /// All matches of `query` on a page: character range, rectangles in PDF page space (points, origin
    /// bottom-left — the same space PDFKit's `PDFPage` uses) and a snippet around the match.
    func matches(of query: String, onPage index: Int, matchCase: Bool, wholeWord: Bool) throws -> [PDFiumMatch] {
        try withTextPage(index) { textPage in
            let needle = Array(query.utf16) + [0]
            var flags: UInt = 0
            if matchCase { flags |= UInt(FPDF_MATCHCASE) }
            if wholeWord { flags |= UInt(FPDF_MATCHWHOLEWORD) }
            guard let search = FPDFText_FindStart(textPage, needle, UInt(flags), 0) else { return [] }
            defer { FPDFText_FindClose(search) }
            let total = Int(FPDFText_CountChars(textPage))
            var found: [PDFiumMatch] = []
            while FPDFText_FindNext(search) != 0 {
                let start = Int(FPDFText_GetSchResultIndex(search))
                let count = Int(FPDFText_GetSchCount(search))
                var rects: [CGRect] = []
                let rectCount = FPDFText_CountRects(textPage, Int32(start), Int32(count))
                for i in 0..<max(rectCount, 0) {
                    var left = 0.0, top = 0.0, right = 0.0, bottom = 0.0
                    if FPDFText_GetRect(textPage, i, &left, &top, &right, &bottom) != 0 {
                        rects.append(CGRect(x: left, y: bottom, width: right - left, height: top - bottom))
                    }
                }
                func text(_ from: Int, _ to: Int) -> String {
                    let lower = max(0, from), upper = min(total, to)
                    guard upper > lower else { return "" }
                    var buffer = [UInt16](repeating: 0, count: upper - lower + 1)
                    let written = FPDFText_GetText(textPage, Int32(lower), Int32(upper - lower), &buffer)
                    return String(decoding: buffer.prefix(max(Int(written) - 1, 0)), as: UTF16.self)
                }
                found.append(PDFiumMatch(page: index, charIndex: start, charCount: count, rects: rects,
                                         before: text(start - 24, start), match: text(start, start + count),
                                         after: text(start + count, start + count + 32)))
            }
            return found
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
        // The layer is drawn from (0, 0); move it to this page's media box origin.
        var left: Float = 0, bottom: Float = 0, right: Float = 0, top: Float = 0
        if FPDFPage_GetMediaBox(page, &left, &bottom, &right, &top) != 0, left != 0 || bottom != 0 {
            FPDFPageObj_Transform(form, 1, 0, 0, 1, Double(left), Double(bottom))
        }
        FPDFPage_InsertObject(page, form)
        guard FPDFPage_GenerateContent(page) != 0 else { throw PDFiumError.saveFailed }
    }

    /// Appends page `index` of `source` (content, resources and annotations copied as they are — nothing is
    /// redrawn), turned `quarterTurns` × 90° further clockwise.
    func appendPage(from source: PDFiumDocument, index: Int, quarterTurns: Int) throws {
        var pageIndex = Int32(index)
        guard FPDF_ImportPagesByIndex(handle, source.handle, &pageIndex, 1, Int32(pageCount)) != 0 else { throw PDFiumError.page }
        guard quarterTurns % 4 != 0 else { return }
        guard let page = FPDF_LoadPage(handle, Int32(pageCount - 1)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        FPDFPage_SetRotation(page, (FPDFPage_GetRotation(page) + Int32(quarterTurns % 4) + 4) % 4)
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

nonisolated struct PDFiumChar: Sendable, Equatable {
    let index: Int
    let scalar: Unicode.Scalar
    /// Inserted by PDFium (spaces, line breaks), not present in the file.
    let isGenerated: Bool
    /// Text render mode 3: invisible text layers (OCR, Slek PDF's own) are already in reading order.
    let isInvisible: Bool
    let origin: CGPoint
    let box: CGRect
    let fontSize: Double
}

nonisolated struct PDFiumMatch: Sendable, Equatable {
    let page: Int
    let charIndex: Int
    let charCount: Int
    let rects: [CGRect]
    let before: String
    let match: String
    let after: String
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
