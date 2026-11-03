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
    var color: [CGFloat] = [0.11, 0.11, 0.11]

    enum Alignment: String, Codable, Sendable { case left, center, right }

    var fontName: String { bold ? "NotoSansKhmer-Bold" : "NotoSansKhmer-Regular" }
}

nonisolated enum KhmerGlyphOutlines {
    /// A PDF content stream that fills the shaped glyph outlines of `text` laid out in `rect` (page space).
    static func appearanceStream(text: String, in rect: CGRect, style: TextBoxStyle) -> String {
        let font = CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineSpacing
        paragraph.alignment = switch style.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        let shear = style.italic ? CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0) : .identity

        var ops = [String(format: "%.4f %.4f %.4f rg", style.color[0], style.color[1], style.color[2])]
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                for (glyph, position) in zip(glyphs, positions) {
                    var transform = shear.concatenating(CGAffineTransform(translationX: rect.minX + origin.x + position.x,
                                                                          y: rect.minY + origin.y + position.y))
                    guard let path = CTFontCreatePathForGlyph(runFont, glyph, &transform), !path.isEmpty else { continue }
                    ops.append(pdfOperators(path) + " f")
                }
            }
            if style.underline {
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                let x = rect.minX + origin.x, y = rect.minY + origin.y - style.fontSize * 0.15
                ops.append(String(format: "%.2f %.2f %.2f %.2f re f", x, y, width, max(0.6, style.fontSize * 0.06)))
            }
        }
        return ops.joined(separator: "\n")
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

/// A text box read back from saved work.
nonisolated struct StoredTextBox: Equatable, Sendable {
    let rect: CGRect
    let text: String
    let style: TextBoxStyle?
}

nonisolated extension PDFiumDocument {
    /// Adds a text box annotation to page `index` (see `TextBoxStyle`).
    func addTextBox(page index: Int, rect: CGRect, text: String, style: TextBoxStyle) throws {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        guard let annot = FPDFPage_CreateAnnot(page, FPDF_ANNOT_FREETEXT) else { throw PDFiumError.saveFailed }
        defer { FPDFPage_CloseAnnot(annot) }
        var frame = FS_RECTF(left: Float(rect.minX), top: Float(rect.maxY), right: Float(rect.maxX), bottom: Float(rect.minY))
        let styleJSON = String(decoding: try JSONEncoder().encode(style), as: UTF8.self)
        let appearance = KhmerGlyphOutlines.appearanceStream(text: text, in: rect, style: style)
        let ok = FPDFAnnot_SetRect(annot, &frame) != 0
            && Self.wide(text) { FPDFAnnot_SetStringValue(annot, "Contents", $0) } != 0
            && Self.wide(styleJSON) { FPDFAnnot_SetStringValue(annot, "SlekTextBox", $0) } != 0
            && Self.wide(appearance) { FPDFAnnot_SetAP(annot, FPDF_ANNOT_APPEARANCEMODE_NORMAL, $0) } != 0
        guard ok else { throw PDFiumError.saveFailed }
    }

    /// Text boxes (FreeText annotations) on page `index`, with Slek's style when present.
    func textBoxes(page index: Int) throws -> [StoredTextBox] {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { throw PDFiumError.page }
        defer { FPDF_ClosePage(page) }
        var boxes: [StoredTextBox] = []
        for i in 0..<FPDFPage_GetAnnotCount(page) {
            guard let annot = FPDFPage_GetAnnot(page, i) else { continue }
            defer { FPDFPage_CloseAnnot(annot) }
            guard FPDFAnnot_GetSubtype(annot) == FPDF_ANNOT_FREETEXT else { continue }
            var frame = FS_RECTF()
            _ = FPDFAnnot_GetRect(annot, &frame)
            let style = Self.string(annot, "SlekTextBox").flatMap { try? JSONDecoder().decode(TextBoxStyle.self, from: Data($0.utf8)) }
            boxes.append(StoredTextBox(rect: CGRect(x: CGFloat(frame.left), y: CGFloat(frame.bottom),
                                                    width: CGFloat(frame.right - frame.left), height: CGFloat(frame.top - frame.bottom)),
                                       text: Self.string(annot, "Contents") ?? "", style: style))
        }
        return boxes
    }

    /// Renders page `index` with annotation appearances at `scale` (BGRA, white background).
    func render(page index: Int, scale: CGFloat) -> CGImage? {
        guard let page = FPDF_LoadPage(handle, Int32(index)) else { return nil }
        defer { FPDF_ClosePage(page) }
        let width = Int32(CGFloat(FPDF_GetPageWidthF(page)) * scale), height = Int32(CGFloat(FPDF_GetPageHeightF(page)) * scale)
        guard let bitmap = FPDFBitmap_Create(width, height, 0) else { return nil }
        defer { FPDFBitmap_Destroy(bitmap) }
        _ = FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xFFFF_FFFF)
        FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, FPDF_ANNOT)
        guard let buffer = FPDFBitmap_GetBuffer(bitmap) else { return nil }
        let stride = Int(FPDFBitmap_GetStride(bitmap))
        guard let provider = CGDataProvider(data: Data(bytes: buffer, count: stride * Int(height)) as CFData) else { return nil }
        return CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
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
