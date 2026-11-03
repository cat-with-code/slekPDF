import AppKit

/// Figma Added Text Box, Editing (125:18): a native text view over the box while typing, so Khmer input methods
/// (marked text, composition) work as everywhere else in macOS. Font, size, spacing, alignment and colour match the
/// committed drawing (Noto Sans Khmer, CoreText) at the view's zoom. Typing has its own undo history; committing the
/// text is one step in the window's undo.
final class TextBoxEditor: NSTextView, NSTextViewDelegate {
    var onChange: (String) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private let typingUndo = UndoManager()
    private(set) var style = TextBoxStyle()
    private(set) var scale: CGFloat = 0

    convenience init(text: String) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isVerticallyResizable = false
        isHorizontallyResizable = false
        drawsBackground = true
        backgroundColor = DSNSColor.backgroundPage
        insertionPointColor = DSNSColor.accentDefault
        selectedTextAttributes = [.backgroundColor: DSNSColor.accentDefault.withAlphaComponent(0.18)]
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        wantsLayer = true
        layer?.borderColor = DSNSColor.accentDefault.cgColor
        layer?.borderWidth = 1.5
        delegate = self
        string = text
    }

    private(set) var insets = KhmerGlyphOutlines.textBoxInsets

    /// Applies the box's style at the PDF view's zoom (`scale` points on screen per PDF point). An edited PDF line has
    /// no insets and the page's own colour behind it (it covers the original line while typing).
    func apply(_ style: TextBoxStyle, scale: CGFloat, insets: CGSize = KhmerGlyphOutlines.textBoxInsets, background: [CGFloat]? = nil) {
        if let background {
            backgroundColor = NSColor(srgbRed: background[0], green: background[1], blue: background[2], alpha: 1)
        }
        guard style != self.style || scale != self.scale || insets != self.insets else { return }
        self.style = style
        self.scale = scale
        self.insets = insets
        let size = style.fontSize * scale
        let font = NSFont(name: style.fontName, size: size) ?? .systemFont(ofSize: size)
        let paragraph = style.paragraphStyle(scale: scale)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph,
            .foregroundColor: NSColor(srgbRed: style.color[0], green: style.color[1], blue: style.color[2], alpha: 1),
        ]
        if style.italic { attributes[.obliqueness] = 0.2 }
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        textContainerInset = NSSize(width: insets.width * scale, height: insets.height * scale)
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        typingAttributes = attributes
    }

    func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

    func textDidChange(_ notification: Notification) { onChange(string) }

    /// Esc ends editing (the text is kept).
    override func cancelOperation(_ sender: Any?) { onEnd() }
}
