import AppKit
import PDFKit

/// Shows one of Slek's annotations on a PDFKit page, on screen and in print. `DocumentSession.annotations` is the
/// source of truth: these objects are rebuilt from it, and saved work is written from the model by PDFium, never by PDFKit.
/// Drawing is Slek's own (CoreText outlines for Khmer), so PDFKit never lays out Khmer text itself.
/// Nonisolated: PDFKit draws pages on background threads.
nonisolated final class SlekPDFAnnotation: PDFAnnotation {
    /// Annotation/Highlight and Annotation/Comment — fixed document colours (same in light and dark; DSNSColor is main-actor).
    static let highlightColor = CGColor(srgbRed: 0xE3 / 255, green: 0xF6 / 255, blue: 0x6B / 255, alpha: 1)
    static let commentColor = CGColor(srgbRed: 0xEE / 255, green: 0xB0 / 255, blue: 0x74 / 255, alpha: 1)

    let model: PageAnnotation
    /// Text box glyph outlines, computed once (the same paths the saved appearance uses).
    private let outlines: [CGPath]

    init(_ model: PageAnnotation) {
        self.model = model
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
        }
        super.init(bounds: model.bounds, forType: type, withProperties: nil)
        isReadOnly = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var isComment: Bool { if case .comment = model.content { true } else { false } }

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
        case let .highlight(info):
            context.setBlendMode(.multiply)
            context.setFillColor(Self.highlightColor)
            for line in info.lines { context.fill(line) }
        case let .comment(info):
            // Placeholder pin until Comment Pin (Figma 122:*) is built in Annotate step 2.
            context.setAlpha(info.resolved ? 0.5 : 1)
            context.setFillColor(Self.commentColor)
            context.fillEllipse(in: model.bounds.insetBy(dx: 1, dy: 1))
        }
    }
}
