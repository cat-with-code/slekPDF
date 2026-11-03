import AppKit
import CoreText
import Foundation
import PDFium

/// Added Khmer text boxes in saved work (docs/plans/annotate.md): a FreeText annotation whose `/Contents` is the
/// Unicode text, whose private `/SlekTextBox` key holds Slek's style, and whose appearance is the text already
/// shaped by CoreText (Noto Sans Khmer) drawn as glyph outlines — so no viewer has to shape Khmer itself.
nonisolated struct TextBoxStyle: Codable, Equatable, Sendable {
    var fontSize: CGFloat = 14
    var lineSpacing: CGFloat = 1.6
    var bold = false
    var italic = false
    var underline = false
    var alignment: Alignment = .left
    /// Document colour as 0–1 RGB.
    var color: [CGFloat] = Swatch.black.rgb

    enum Alignment: String, Codable, Sendable { case left, center, right }

    var fontName: String { bold ? "NotoSansKhmer-Bold" : "NotoSansKhmer-Regular" }

    /// Line spacing is a multiple of the font size (Figma: 14 pt text, spacing 1.6 → ≈ 24 pt lines, a 44 pt box).
    /// `scale` sizes it for the on-screen editor at the view's zoom.
    func paragraphStyle(scale: CGFloat = 1) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        let line = fontSize * lineSpacing * scale
        paragraph.minimumLineHeight = line
        paragraph.maximumLineHeight = line
        paragraph.alignment = switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        return paragraph
    }

    /// Figma Added Text Box (125:23): text 8 pt from the sides and 10 pt from the top; 44 pt tall for one line.
    static let horizontalInset: CGFloat = 8
    static let verticalInset: CGFloat = 10
    static let minimumHeight: CGFloat = 44

    /// Document colours (Figma Color Swatch 123:62 — primitives, because they are written into the PDF).
    enum Swatch: String, CaseIterable, Sendable {
        case black, blue, red, green, orange

        var rgb: [CGFloat] {
            let hex: UInt32 = switch self {
            case .black: 0x1C1C1C   // Neutral/100
            case .blue: 0x3A1EF1    // Blue/500
            case .red: 0xD4280D     // Red/600
            case .green: 0x087D17   // Green/800
            case .orange: 0xA25913  // Orange/700
            }
            return [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255]
        }
    }

    var swatch: Swatch? {
        Swatch.allCases.first { zip($0.rgb, color).allSatisfy { abs($0 - $1) < 0.01 } }
    }
}

nonisolated enum KhmerGlyphOutlines {
    /// The shaped text (CoreText, Noto Sans Khmer) laid out in `rect` as filled outlines, one path per glyph and
    /// underline. The saved appearance and on-screen drawing both use this, so they cannot differ.
    static let textBoxInsets = CGSize(width: TextBoxStyle.horizontalInset, height: TextBoxStyle.verticalInset)

    /// `insets`: from the box's sides and top (text boxes: 8 and 10 pt; edited PDF lines: none). `firstBaseline`:
    /// page y of the first line's baseline (an edited line sits on the original line's baseline).
    static func outlines(text: String, in rect: CGRect, style: TextBoxStyle, insets: CGSize = textBoxInsets,
                         firstBaseline: CGFloat? = nil) -> [CGPath] {
        let font = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
        let paragraph = style.paragraphStyle()
        let framesetter = CTFramesetterCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph]))
        // Lay out in a tall column so no line is dropped, then hang it from the box's top inset.
        let column = CGSize(width: max(1, rect.width - 2 * insets.width), height: 100_000)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: column), transform: nil), nil)
        var offset = CGPoint(x: rect.minX + insets.width, y: rect.maxY - insets.height - column.height)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        if let firstBaseline, let first = origins.first { offset.y = firstBaseline - first.y }
        let shear = style.italic ? CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0) : .identity

        var paths: [CGPath] = []
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                for (glyph, position) in zip(glyphs, positions) {
                    var transform = shear.concatenating(CGAffineTransform(translationX: offset.x + origin.x + position.x,
                                                                          y: offset.y + origin.y + position.y))
                    if let path = CTFontCreatePathForGlyph(runFont, glyph, &transform), !path.isEmpty { paths.append(path) }
                }
            }
            if style.underline {
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                paths.append(CGPath(rect: CGRect(x: offset.x + origin.x, y: offset.y + origin.y - style.fontSize * 0.15,
                                                 width: width, height: max(0.6, style.fontSize * 0.06)), transform: nil))
            }
        }
        return paths
    }

    /// Height a box of `width` needs for `text` (Figma minimum 44 pt), so lines are never cut off.
    static func fittedHeight(text: String, width: CGFloat, style: TextBoxStyle, insets: CGSize = textBoxInsets,
                             minimum: CGFloat = TextBoxStyle.minimumHeight) -> CGFloat {
        let font = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
        let paragraph = style.paragraphStyle()
        let sample = text.isEmpty || text.hasSuffix("\n") ? text + "ក" : text  // an empty last line still takes a line
        let framesetter = CTFramesetterCreateWithAttributedString(
            NSAttributedString(string: sample, attributes: [.font: font, .paragraphStyle: paragraph]))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, CGSize(width: max(1, width - 2 * insets.width), height: 100_000), nil)
        return max(minimum, ceil(size.height + 2 * insets.height))
    }

    /// Height of the ink of `text` set at 1 pt (glyph outlines, top of the highest mark to the bottom of the lowest
    /// subscript). Dividing a line's drawn height by it gives the size that draws `text` as tall as the original.
    static func inkHeight(text: String, style: TextBoxStyle) -> CGFloat {
        let font = CTFontCreateWithName(style.fontName as CFString, 1, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).height
    }

    /// Width one line of `text` takes (no wrapping).
    static func lineWidth(text: String, style: TextBoxStyle) -> CGFloat {
        let font = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// A PDF content stream that fills `outlines(text:in:style:)` in the style's colour.
    static func appearanceStream(text: String, in rect: CGRect, style: TextBoxStyle) -> String {
        let colour = String(format: "%.4f %.4f %.4f rg", style.color[0], style.color[1], style.color[2])
        return ([colour] + outlines(text: text, in: rect, style: style).map { pdfOperators($0) + " f" }).joined(separator: "\n")
    }

    /// An edited PDF line: the original line covered with the page colour, then the new text on its baseline.
    static func appearanceStream(edit: TextEditInfo, in rect: CGRect) -> String {
        let c = edit.coverColor, t = edit.style.color
        let cover = String(format: "%.4f %.4f %.4f rg %.2f %.2f %.2f %.2f re f", c[0], c[1], c[2],
                           edit.cover.minX, edit.cover.minY, edit.cover.width, edit.cover.height)
        let colour = String(format: "%.4f %.4f %.4f rg", t[0], t[1], t[2])
        return ([cover, colour] + edit.outlines(in: rect).map { pdfOperators($0) + " f" }).joined(separator: "\n")
    }

    private static func pdfOperators(_ path: CGPath) -> String {
        var out: [String] = []
        var current = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let p = element.points
            switch element.type {
            case .moveToPoint:
                out.append(String(format: "%.2f %.2f m", p[0].x, p[0].y)); current = p[0]
            case .addLineToPoint:
                out.append(String(format: "%.2f %.2f l", p[0].x, p[0].y)); current = p[0]
            case .addQuadCurveToPoint:  // quadratic → cubic
                let c1 = CGPoint(x: current.x + 2 / 3 * (p[0].x - current.x), y: current.y + 2 / 3 * (p[0].y - current.y))
                let c2 = CGPoint(x: p[1].x + 2 / 3 * (p[0].x - p[1].x), y: p[1].y + 2 / 3 * (p[0].y - p[1].y))
                out.append(String(format: "%.2f %.2f %.2f %.2f %.2f %.2f c", c1.x, c1.y, c2.x, c2.y, p[1].x, p[1].y)); current = p[1]
            case .addCurveToPoint:
                out.append(String(format: "%.2f %.2f %.2f %.2f %.2f %.2f c", p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y)); current = p[2]
            case .closeSubpath:
                out.append("h")
            @unknown default:
                break
            }
        }
        return out.joined(separator: " ")
    }
}

/// Something added on a page in Annotate (docs/plans/annotate.md). Coordinates are the source page's own (unrotated)
/// PDF space, so the annotation follows its page through reorder and rotation.
nonisolated struct PageAnnotation: Identifiable, Equatable, Sendable {
    var id = UUID()
    var bounds: CGRect
    var content: Content

    enum Content: Equatable, Sendable {
        case textBox(text: String, style: TextBoxStyle)
        case highlight(HighlightInfo)
        case comment(CommentInfo)
        /// A line of the PDF's own text, changed in place (Edit PDF text). `bounds` is where the new text is laid out;
        /// it always contains the cover.
        case textEdit(TextEditInfo)
    }

    /// The same annotation ignoring identity (a reopened file gets new ids).
    func sameContent(as other: PageAnnotation) -> Bool { bounds == other.bounds && content == other.content }
}

/// Edit PDF text (Figma PDF Text Line 556:525): the original line is covered with the page colour and the new text is
/// drawn in a bundled Khmer font at the line's size and baseline. The PDF itself is not changed; Save work keeps the
/// edit editable.
nonisolated struct TextEditInfo: Codable, Equatable, Sendable {
    /// The line's text as it was (Restore original text).
    var original: String
    var text: String
    var style: TextBoxStyle
    /// The original line's rectangle (page space), painted over with `coverColor`.
    var cover: CGRect
    /// Page y of the original line's baseline.
    var baseline: CGFloat
    /// 0–1 RGB of the page around the line (white on most PDFs, paper colour on scans).
    var coverColor: [CGFloat] = [1, 1, 1]

    /// No insets: the text starts where the original line started.
    static let insets = CGSize.zero

    func outlines(in rect: CGRect) -> [CGPath] {
        KhmerGlyphOutlines.outlines(text: text, in: rect, style: style, insets: Self.insets, firstBaseline: baseline)
    }

    /// The rectangle for `text`: from the line's start, as wide as the text (at least the original line), as tall
    /// as its lines; always containing the cover.
    func layoutBounds(pageBox: CGRect) -> CGRect {
        let longest = text.components(separatedBy: "\n").map { KhmerGlyphOutlines.lineWidth(text: $0, style: style) }.max() ?? 0
        let width = min(max(cover.width, longest + 2), max(cover.width, pageBox.maxX - cover.minX))
        let height = KhmerGlyphOutlines.fittedHeight(text: text, width: width, style: style, insets: Self.insets, minimum: cover.height)
        return CGRect(x: cover.minX, y: cover.maxY - height, width: width, height: height).union(cover)
    }
}

nonisolated struct HighlightInfo: Codable, Equatable, Sendable {
    /// One rectangle per highlighted line.
    var lines: [CGRect]
    /// The highlighted text, in logical order.
    var text: String
}

nonisolated struct CommentInfo: Codable, Equatable, Sendable {
    var text: String
    var author: String
    var date: Date
    /// The page text the comment is about, if any.
    var quote: String?
    var resolved = false
    var replies: [Reply] = []

    struct Reply: Codable, Equatable, Sendable {
        var author: String
        var text: String
        var date: Date
    }
}

/// Khmer OCR (Figma 04): one recognized text line on a page. Bounds are in the source page's own (unrotated) PDF space.
nonisolated struct OCRLine: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var bounds: CGRect
    /// What Tesseract read.
    var text: String
    /// Tesseract's line confidence, 0–100: a review hint, not a correctness score.
    var confidence: Double
    /// The reviewer's correction, if any.
    var correction: String?
    var reviewed = false

    /// Lines below this confidence are listed as Uncertain regions.
    static let uncertainBelow: Double = 80

    var displayText: String { correction ?? text }
    var isUncertain: Bool { confidence < Self.uncertainBelow }
}

/// The recognized text of one page.
nonisolated struct OCRPage: Codable, Equatable, Sendable {
    var lines: [OCRLine]
    /// Tesseract languages used ("khm+eng").
    var languages: String
    var date: Date
    /// The page's turn (PageRef quarter turns) when it was recognized; Export warns if it changed (Figma 40).
    var quarterTurns: Int?

    var text: String { lines.map(\.displayText).joined(separator: "\n") }
    /// Corrections or reviews the person made (re-recognizing would replace them).
    var hasReviewWork: Bool { lines.contains { $0.reviewed || $0.correction != nil } }
}

/// Private keys marking annotations Slek owns; other annotations in a PDF are left exactly as they are.
nonisolated private enum SlekKey {
    static let textBox = "SlekTextBox", highlight = "SlekHighlight", comment = "SlekComment", ocr = "SlekOCR"
    static let textEdit = "SlekTextEdit"
    static let all = [textBox, highlight, comment, ocr, textEdit]
}

nonisolated extension PDFiumDocument {
    /// Writes `annotation` onto page `index`.
    func add(_ annotation: PageAnnotation, page index: Int) throws {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        let rect = annotation.bounds
        let subtype: Int32 = switch annotation.content {
        case .textBox, .textEdit: FPDF_ANNOT_FREETEXT
        case .highlight: FPDF_ANNOT_HIGHLIGHT
        case .comment: FPDF_ANNOT_TEXT
        }
        guard let annot = FPDFPage_CreateAnnot(page, subtype) else { throw PDFiumError.saveFailed }
        defer { FPDFPage_CloseAnnot(annot) }
        var frame = FS_RECTF(left: Float(rect.minX), top: Float(rect.maxY), right: Float(rect.maxX), bottom: Float(rect.minY))
        var ok = FPDFAnnot_SetRect(annot, &frame) != 0
        func set(_ key: String, _ value: String) { ok = ok && Self.wide(value) { FPDFAnnot_SetStringValue(annot, key, $0) } != 0 }
        func json(_ value: some Encodable) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }

        switch annotation.content {
        case let .textBox(text, style):
            set("Contents", text)
            set(SlekKey.textBox, try json(style))
            let appearance = KhmerGlyphOutlines.appearanceStream(text: text, in: rect, style: style)
            ok = ok && Self.wide(appearance) { FPDFAnnot_SetAP(annot, FPDF_ANNOT_APPEARANCEMODE_NORMAL, $0) } != 0
        case let .textEdit(info):
            set("Contents", info.text)
            set(SlekKey.textEdit, try json(info))
            let appearance = KhmerGlyphOutlines.appearanceStream(edit: info, in: rect)
            ok = ok && Self.wide(appearance) { FPDFAnnot_SetAP(annot, FPDF_ANNOT_APPEARANCEMODE_NORMAL, $0) } != 0
        case let .highlight(info):
            for line in info.lines {
                var quad = FS_QUADPOINTSF(x1: Float(line.minX), y1: Float(line.maxY), x2: Float(line.maxX), y2: Float(line.maxY),
                                          x3: Float(line.minX), y3: Float(line.minY), x4: Float(line.maxX), y4: Float(line.minY))
                ok = ok && FPDFAnnot_AppendAttachmentPoints(annot, &quad) != 0
            }
            // Annotation/Highlight (#E3F66B) at 55 % (Figma Highlight 125:26).
            ok = ok && FPDFAnnot_SetColor(annot, FPDFANNOT_COLORTYPE_Color, 0xE3, 0xF6, 0x6B, 140) != 0
            set("Contents", info.text)
            set(SlekKey.highlight, try json(info))
        case let .comment(info):
            // Annotation/Comment (#EEB074).
            ok = ok && FPDFAnnot_SetColor(annot, FPDFANNOT_COLORTYPE_Color, 0xEE, 0xB0, 0x74, 255) != 0
            set("Contents", info.text)
            set("T", info.author)
            set(SlekKey.comment, try json(info))
        }
        guard ok else { throw PDFiumError.saveFailed }
    }

    /// Slek's annotations on page `index` (other annotations are not part of the model).
    func slekAnnotations(page index: Int) throws -> [PageAnnotation] {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        var result: [PageAnnotation] = []
        for i in 0..<FPDFPage_GetAnnotCount(page) {
            guard let annot = FPDFPage_GetAnnot(page, i) else { continue }
            defer { FPDFPage_CloseAnnot(annot) }
            var frame = FS_RECTF()
            _ = FPDFAnnot_GetRect(annot, &frame)
            let bounds = CGRect(x: CGFloat(frame.left), y: CGFloat(frame.bottom),
                                width: CGFloat(frame.right - frame.left), height: CGFloat(frame.top - frame.bottom))
            func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
                Self.string(annot, key).flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
            }
            if let style = decode(TextBoxStyle.self, SlekKey.textBox) {
                result.append(PageAnnotation(bounds: bounds, content: .textBox(text: Self.string(annot, "Contents") ?? "", style: style)))
            } else if let info = decode(TextEditInfo.self, SlekKey.textEdit) {
                result.append(PageAnnotation(bounds: bounds, content: .textEdit(info)))
            } else if let info = decode(HighlightInfo.self, SlekKey.highlight) {
                result.append(PageAnnotation(bounds: bounds, content: .highlight(info)))
            } else if let info = decode(CommentInfo.self, SlekKey.comment) {
                result.append(PageAnnotation(bounds: bounds, content: .comment(info)))
            }
        }
        return result
    }

    /// Stores a page's OCR result in saved work: a hidden note at the page origin whose `/SlekOCR` holds the lines and
    /// whose `/Contents` is the plain text.
    func addOCR(_ ocr: OCRPage, page index: Int) throws {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        guard let annot = FPDFPage_CreateAnnot(page, FPDF_ANNOT_TEXT) else { throw PDFiumError.saveFailed }
        defer { FPDFPage_CloseAnnot(annot) }
        var frame = FS_RECTF(left: 0, top: 0, right: 0, bottom: 0)
        let json = String(decoding: try JSONEncoder().encode(ocr), as: UTF8.self)
        let ok = FPDFAnnot_SetRect(annot, &frame) != 0
            && FPDFAnnot_SetFlags(annot, Int32(FPDF_ANNOT_FLAG_HIDDEN)) != 0
            && Self.wide(ocr.text) { FPDFAnnot_SetStringValue(annot, "Contents", $0) } != 0
            && Self.wide(json) { FPDFAnnot_SetStringValue(annot, SlekKey.ocr, $0) } != 0
        guard ok else { throw PDFiumError.saveFailed }
    }

    /// The OCR result stored on page `index`, if any.
    func slekOCR(page index: Int) throws -> OCRPage? {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        for i in 0..<FPDFPage_GetAnnotCount(page) {
            guard let annot = FPDFPage_GetAnnot(page, i) else { continue }
            defer { FPDFPage_CloseAnnot(annot) }
            if let json = Self.string(annot, SlekKey.ocr) { return try? JSONDecoder().decode(OCRPage.self, from: Data(json.utf8)) }
        }
        return nil
    }

    /// Renders page `index` for OCR: `quarterTurns` × 90° clockwise on top of the page's own rotation, white background.
    /// Returns the image and its pixel size (for `pageRect`).
    func renderForOCR(page index: Int, quarterTurns: Int, ppi: CGFloat) -> CGImage? {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { return nil }
        defer { FPDF_ClosePage(page) }
        let size = Self.deviceSize(page, quarterTurns: quarterTurns, ppi: ppi)
        return Self.renderBitmap(page, size: size, rotate: Int32(quarterTurns % 4))
    }

    /// Maps rectangles in a `renderForOCR` image (pixels, origin top-left) back to the page's PDF space.
    func pageRects(_ rects: [CGRect], page index: Int, quarterTurns: Int, ppi: CGFloat) -> [CGRect] {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { return [] }
        defer { FPDF_ClosePage(page) }
        let size = Self.deviceSize(page, quarterTurns: quarterTurns, ppi: ppi)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            var px: Double = 0, py: Double = 0
            _ = FPDF_DeviceToPage(page, 0, 0, Int32(size.width), Int32(size.height), Int32(quarterTurns % 4), Int32(x), Int32(y), &px, &py)
            return CGPoint(x: px, y: py)
        }
        return rects.map { rect in
            let a = point(rect.minX, rect.minY), b = point(rect.maxX, rect.maxY)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
    }

    private static func deviceSize(_ page: FPDF_PAGE, quarterTurns: Int, ppi: CGFloat) -> (width: Int, height: Int) {
        let scale = ppi / 72
        let width = Int(CGFloat(FPDF_GetPageWidthF(page)) * scale), height = Int(CGFloat(FPDF_GetPageHeightF(page)) * scale)
        return quarterTurns % 2 == 0 ? (width, height) : (height, width)
    }

    private static func renderBitmap(_ page: FPDF_PAGE, size: (width: Int, height: Int), rotate: Int32) -> CGImage? {
        let width = Int32(size.width), height = Int32(size.height)
        guard let bitmap = FPDFBitmap_Create(width, height, 0) else { return nil }
        defer { FPDFBitmap_Destroy(bitmap) }
        _ = FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFF_FFFF)
        FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, rotate, FPDF_ANNOT)
        guard let buffer = FPDFBitmap_GetBuffer(bitmap) else { return nil }
        let stride = Int(FPDFBitmap_GetStride(bitmap))
        guard let provider = CGDataProvider(data: Data(bytes: buffer, count: stride * Int(height)) as CFData) else { return nil }
        return CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The page's colour around `rect` (page space): the median of a ring of pixels just outside it, rendered at
    /// 2 px per point. White on most PDFs; the paper colour on scans (an edited line's cover).
    func colorAround(_ rect: CGRect, page index: Int) -> [CGFloat] {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { return [1, 1, 1] }
        defer { FPDF_ClosePage(page) }
        let size = Self.deviceSize(page, quarterTurns: 0, ppi: 144)
        guard let image = Self.renderBitmap(page, size: size, rotate: 0), let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return [1, 1, 1] }
        func device(_ x: CGFloat, _ y: CGFloat) -> (Int, Int) {
            var dx: Int32 = 0, dy: Int32 = 0
            _ = FPDF_PageToDevice(page, 0, 0, Int32(size.width), Int32(size.height), 0, Double(x), Double(y), &dx, &dy)
            return (Int(dx), Int(dy))
        }
        let ring = rect.insetBy(dx: -3, dy: -3)
        var samples: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []
        let steps = 24
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            for point in [CGPoint(x: ring.minX + t * ring.width, y: ring.minY), CGPoint(x: ring.minX + t * ring.width, y: ring.maxY),
                          CGPoint(x: ring.minX, y: ring.minY + t * ring.height), CGPoint(x: ring.maxX, y: ring.minY + t * ring.height)] {
                let (x, y) = device(point.x, point.y)
                guard x >= 0, y >= 0, x < image.width, y < image.height else { continue }
                let offset = y * image.bytesPerRow + x * 4  // BGRA
                samples.append((CGFloat(bytes[offset + 2]) / 255, CGFloat(bytes[offset + 1]) / 255, CGFloat(bytes[offset]) / 255))
            }
        }
        guard !samples.isEmpty else { return [1, 1, 1] }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        return [median(samples.map(\.r)), median(samples.map(\.g)), median(samples.map(\.b))]
    }

    /// Removes Slek's annotations from page `index` (before writing the model's current ones).
    func removeSlekAnnotations(page index: Int) throws {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        for i in (0..<FPDFPage_GetAnnotCount(page)).reversed() {
            guard let annot = FPDFPage_GetAnnot(page, i) else { continue }
            let owned = SlekKey.all.contains { FPDFAnnot_HasKey(annot, $0) != 0 }
            FPDFPage_CloseAnnot(annot)
            if owned { _ = FPDFPage_RemoveAnnot(page, i) }
        }
    }

    /// Renders page `index` with annotation appearances at `scale` (BGRA, white background).
    func render(page index: Int, scale: CGFloat) -> CGImage? {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { return nil }
        defer { FPDF_ClosePage(page) }
        return Self.renderBitmap(page, size: Self.deviceSize(page, quarterTurns: 0, ppi: scale * 72), rotate: 0)
    }

    private static func wide<T>(_ string: String, _ body: (UnsafePointer<UInt16>) -> T) -> T {
        let units = Array(string.utf16) + [0]
        return units.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    private static func string(_ annot: FPDF_ANNOTATION, _ key: String) -> String? {
        let length = FPDFAnnot_GetStringValue(annot, key, nil, 0)
        guard length > 2 else { return nil }
        var buffer = [UInt16](repeating: 0, count: Int(length) / 2)
        _ = FPDFAnnot_GetStringValue(annot, key, &buffer, length)
        return String(decoding: buffer.dropLast(), as: UTF16.self)
    }
}
