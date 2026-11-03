import AppKit
import PDFKit

/// Shows one of Slek's annotations on a PDFKit page, on screen and in print. `DocumentSession.annotations` is the
/// source of truth: these objects are rebuilt from it, and saved work is written from the model by PDFium, never by PDFKit.
/// Drawing is Slek's own (CoreText outlines for Khmer), so PDFKit never lays out Khmer text itself.
/// Nonisolated: PDFKit draws pages on background threads.
nonisolated final class SlekPDFAnnotation: PDFAnnotation {
    /// Document colours (the same in light and dark, so fixed here; DSNSColor is main-actor):
    /// Annotation/Highlight, Annotation/Comment, Accent/Default, Background/Pressed (light) and Text/Primary (light).
    static let highlightColor = CGColor(srgbRed: 0xE3 / 255, green: 0xF6 / 255, blue: 0x6B / 255, alpha: 1)
    static let commentColor = CGColor(srgbRed: 0xEE / 255, green: 0xB0 / 255, blue: 0x74 / 255, alpha: 1)
    static let accentColor = CGColor(srgbRed: 0x3A / 255, green: 0x1E / 255, blue: 0xF1 / 255, alpha: 1)
    static let resolvedColor = CGColor(srgbRed: 0xC6 / 255, green: 0xC6 / 255, blue: 0xC6 / 255, alpha: 1)
    static let iconColor = CGColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1C / 255, alpha: 1)
    /// Comment Pin (Figma 122:20) is 28 px with a 16 px icon; on the page it is 24 pt, scaled with the page.
    static let pinSize: CGFloat = 24
    private static let commentIcon = NSImage(named: "Icons/comment")?.cgImage(forProposedRect: nil, context: nil, hints: nil)

    let model: PageAnnotation
    let isSelected: Bool
    /// Text box glyph outlines, computed once (the same paths the saved appearance uses).
    private let outlines: [CGPath]

    init(_ model: PageAnnotation, selected: Bool = false) {
        self.model = model
        isSelected = selected
        let type: PDFAnnotationSubtype
        switch model.content {
        case let .textBox(text, style):
            type = .freeText
            outlines = KhmerGlyphOutlines.outlines(text: text, in: model.bounds, style: style)
        case .highlight:
            type = .highlight
            outlines = []
        case .comment:
            type = .text
            outlines = []
        case let .textEdit(info):
            type = .freeText
            outlines = info.outlines(in: model.bounds)
        }
        // Room around the content for the selection outline and handles.
        super.init(bounds: model.bounds.insetBy(dx: -Self.handleSize, dy: -Self.handleSize), forType: type, withProperties: nil)
        isReadOnly = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var isComment: Bool { if case .comment = model.content { true } else { false } }
    var isTextEdit: Bool { if case .textEdit = model.content { true } else { false } }

    /// Whether a click at `point` (page space) lands on this annotation (a selected text box includes its handles).
    func contains(_ point: CGPoint) -> Bool {
        switch model.content {
        case let .highlight(info): info.lines.contains { $0.insetBy(dx: -1, dy: -1).contains(point) }
        case .textBox: model.bounds.insetBy(dx: isSelected ? -Self.handleSize : 0, dy: isSelected ? -Self.handleSize : 0).contains(point)
        case .comment: model.bounds.contains(point)
        case .textEdit: model.bounds.insetBy(dx: -1, dy: -1).contains(point)
        }
    }

    /// Figma Added Text Box handles: 7 pt squares centred on the corners and edge midpoints.
    static let handleSize: CGFloat = 7

    enum Handle: CaseIterable { case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight }

    static func handleCenter(_ handle: Handle, of rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .top: CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .bottom: CGPoint(x: rect.midX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
        }
    }

    /// The handle of a selected text box under `point`, if any.
    func handle(at point: CGPoint) -> Handle? {
        guard isSelected, case .textBox = model.content else { return nil }
        return Handle.allCases.first { handle in
            let center = Self.handleCenter(handle, of: model.bounds)
            return CGRect(x: center.x - Self.handleSize, y: center.y - Self.handleSize, width: 2 * Self.handleSize, height: 2 * Self.handleSize)
                .contains(point)
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard shouldDisplay else { return }
        context.saveGState()
        defer { context.restoreGState() }
        switch model.content {
        case let .textBox(_, style):
            context.setFillColor(CGColor(srgbRed: style.color[0], green: style.color[1], blue: style.color[2], alpha: 1))
            // One fill per glyph, as in the saved appearance: overlapping Khmer subscripts must not cancel out.
            for path in outlines {
                context.addPath(path)
                context.fillPath()
            }
            if isSelected { drawSelection(in: context) }
        case let .highlight(info):
            // Figma Highlight (125:26): Annotation/Highlight at 55 %, radius 2, one rectangle per line;
            // multiply keeps the text under it crisp. Selected = accent outline.
            context.saveGState()
            context.setBlendMode(.multiply)
            context.setAlpha(0.55)
            context.setFillColor(Self.highlightColor)
            for line in info.lines {
                context.addPath(CGPath(roundedRect: line, cornerWidth: 2, cornerHeight: 2, transform: nil))
                context.fillPath()
            }
            context.restoreGState()
            if isSelected {
                context.setStrokeColor(Self.accentColor)
                context.setLineWidth(1.5)
                for line in info.lines { context.stroke(line.insetBy(dx: -1, dy: -1)) }
            }
        case let .comment(info):
            drawPin(in: context, resolved: info.resolved)
        case let .textEdit(info):
            // Figma PDF Text Line, Edited: the original line covered with the page colour, the new text on its baseline.
            context.setFillColor(CGColor(srgbRed: info.coverColor[0], green: info.coverColor[1], blue: info.coverColor[2], alpha: 1))
            context.fill(info.cover)
            context.setFillColor(CGColor(srgbRed: info.style.color[0], green: info.style.color[1], blue: info.style.color[2], alpha: 1))
            for path in outlines {
                context.addPath(path)
                context.fillPath()
            }
            if isSelected {  // Selected: accent outline, no handles (an edited line keeps its place)
                context.setStrokeColor(Self.accentColor)
                context.setLineWidth(1.5)
                context.stroke(model.bounds.insetBy(dx: -1, dy: -1))
            }
        }
    }

    /// Figma Comment Pin (122:20): speech bubble, round except the bottom-left corner (the anchor), Elevation/2 shadow,
    /// comment icon. Default = Annotation/Comment; Selected adds a 2 px accent border; Resolved = grey.
    private func drawPin(in context: CGContext, resolved: Bool) {
        let rect = CGRect(origin: model.bounds.origin, size: CGSize(width: Self.pinSize, height: Self.pinSize))
        let unit = rect.width / 28
        let bubble = Self.bubble(rect, round: 14 * unit, anchor: 3 * unit)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4 * unit), blur: 12 * unit, color: CGColor(gray: 0, alpha: 0.12))
        context.addPath(bubble)
        context.setFillColor(resolved ? Self.resolvedColor : Self.commentColor)
        context.fillPath()
        context.restoreGState()
        if isSelected && !resolved {
            context.addPath(Self.bubble(rect.insetBy(dx: unit, dy: unit), round: 13 * unit, anchor: 2 * unit))
            context.setStrokeColor(Self.accentColor)
            context.setLineWidth(2 * unit)
            context.strokePath()
        }
        if let icon = Self.commentIcon {
            let side = 16 * unit
            let iconRect = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            // Tint the template icon: draw it, then paint the colour only where it drew.
            context.beginTransparencyLayer(in: iconRect, auxiliaryInfo: nil)
            context.draw(icon, in: iconRect)
            context.setBlendMode(.sourceIn)
            context.setFillColor(Self.iconColor)
            context.fill(iconRect)
            context.endTransparencyLayer()
        }
    }

    /// Figma Added Text Box, Selected: 1.5 pt accent outline and eight Background/Page handles with accent borders.
    private func drawSelection(in context: CGContext) {
        context.setStrokeColor(Self.accentColor)
        context.setLineWidth(1.5)
        context.stroke(model.bounds)
        for handle in Handle.allCases {
            let center = Self.handleCenter(handle, of: model.bounds)
            let square = CGRect(x: center.x - Self.handleSize / 2, y: center.y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(square)
            context.stroke(square.insetBy(dx: 0.75, dy: 0.75))
        }
    }

    /// Rounded rectangle with a sharp bottom-left corner (page space, y up).
    private static func bubble(_ rect: CGRect, round: CGFloat, anchor: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + anchor, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - round, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: round)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: round)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: round)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: anchor)
        path.closeSubpath()
        return path
    }
}
