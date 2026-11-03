import SwiftUI

/// Figma Annotate Panel (157:188): Annotate Tools, Added text properties, and the comment list.
struct AnnotateInspector: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s16) {
                HStack {
                    DSLabel(.annotate, style: .heading).foregroundColor(DSColor.textPrimary)
                    Spacer()
                    DSIconButton(.right, size: 24, iconSize: 14) { session.setInspectorVisible(false) }
                        .dsTooltip(.hideInspector, shortcut: "⌥⌘I")
                }
                AnnotateToolsView()
                DSDivider()
                TextPropertiesPanel()
                DSDivider()
                comments
            }
            .padding(DSSpace.s16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DSColor.backgroundSurface)
    }

    @ViewBuilder private var comments: some View {
        let entries = session.comments
        Text(CopyCatalog.shared.format(.fmtCommentsN, language, entries.count))
            .dsText(.heading).foregroundColor(DSColor.textPrimary)
        if let draft = session.commentDraft, draft.editing == nil {
            CommentCard(entry: nil, pageIndex: draft.pageIndex)
        }
        ForEach(entries) { entry in
            CommentCard(entry: entry, pageIndex: entry.pageIndex)
        }
    }
}

/// Figma Annotate Tools (125:135): the active tool is Primary; choosing it again returns to Edit PDF text (the default).
struct AnnotateToolsView: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s8) {
            tool(.editPDFText, icon: .edit, tool: .editText, command: .editTextTool)
            tool(.addKhmerText, icon: .addText, tool: .text, command: .addTextTool)
            tool(.highlightText, icon: .highLight, tool: .highlight, command: .highlightTool)
            tool(.addComment, icon: .comment, tool: .comment, command: .commentTool)
            if let hint {
                Text(CopyCatalog.shared.string(hint, language)).dsText(.caption).foregroundColor(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hint: CopyKey? {
        switch session.annotateTool {
        case .highlight: .selectKhmerTextOnThePageToHighlightIt
        case .comment: .clickThePageWhereTheCommentBelongs
        case .text: .clickThePageWhereTheTextBelongs
        case .editText: .clickALineOfTextOnThePageToEdit
        case .select: nil
        }
    }

    private func tool(_ title: CopyKey, icon: DSIcon, tool: AnnotateTool, command: ShortcutCommand) -> some View {
        DSButton(title, icon: icon, style: session.annotateTool == tool ? .primary : .secondary, fullWidth: true) {
            session.annotateTool = session.annotateTool == tool ? .editText : tool
            session.pdfView?.window?.makeFirstResponder(session.pdfView)  // so V/H/C/Esc reach the canvas
        }
        .dsTooltip(title, shortcut: ShortcutStore.shared.shortcut(command)?.display)
        .accessibilityAddTraits(session.annotateTool == tool ? .isSelected : [])
    }
}

/// Figma Comment Card (122:140): Default, Selected (linked to its pin), Editing (field + Cancel/Save), Resolved
/// (badge, Reopen). `entry == nil` is a new comment being written.
struct CommentCard: View {
    let entry: CommentEntry?
    let pageIndex: Int
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var replyText = ""
    @State private var isReplying = false
    @State private var moreAnchor = DropdownAnchor.Box()

    private var info: CommentInfo? { entry?.info }
    private var isEditing: Bool { session.commentDraft.map { $0.editing == entry?.id } ?? false }
    private var isSelected: Bool { entry != nil && session.selectedAnnotationID == entry?.id && !isEditing }
    private var isResolved: Bool { info?.resolved ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s8) {
            header
            if let quote = info?.quote ?? (entry == nil ? session.commentDraft?.quote : nil) {
                Text("“\(quote)”").dsText(.caption).foregroundColor(DSColor.textSecondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, DSSpace.s8)
                    .overlay(alignment: .leading) { Rectangle().fill(DSColor.annotationComment).frame(width: 2) }
            }
            if isEditing {
                editor(text: draftText, placeholder: .writeAComment, canSave: !draftText.wrappedValue.isBlank,
                       cancel: session.cancelCommentDraft, save: session.saveCommentDraft)
            } else if let info {
                Text(info.text).dsText(.body).foregroundColor(isResolved ? DSColor.textTertiary : DSColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(info.replies.enumerated()), id: \.offset) { _, reply in
                    replyRow(reply)
                }
                if isReplying {
                    editor(text: $replyText, placeholder: .reply2, canSave: !replyText.isBlank,
                           cancel: { isReplying = false; replyText = "" },
                           save: {
                               if let id = entry?.id { session.addReply(to: id, text: replyText) }
                               isReplying = false
                               replyText = ""
                           })
                } else {
                    actions
                }
            }
        }
        .padding(DSSpace.s12)
        .background(RoundedRectangle(cornerRadius: DSRadius.md).fill(isSelected ? DSColor.backgroundSelected : DSColor.backgroundSurface))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.md)
            .strokeBorder(isSelected ? DSColor.accentDefault : DSColor.borderDefault, lineWidth: isSelected ? 1.5 : DSStroke.default))
        .contentShape(Rectangle())
        .onTapGesture { if let id = entry?.id, !isEditing { session.selectAnnotation(id) } }
        .accessibilityElement(children: .contain)
    }

    // MARK: Parts

    private var header: some View {
        let name = displayName(info?.author ?? DocumentSession.currentAuthor)
        return HStack(spacing: DSSpace.s8) {
            DSAvatar(initials: initial(name), size: .xs, subtle: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).dsText(.label).foregroundColor(DSColor.textPrimary).lineLimit(1)
                Text(CopyCatalog.shared.format(.fmtPageNTime, language, pageIndex + 1, time(info?.date ?? Date())))
                    .dsText(.caption).foregroundColor(DSColor.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isResolved {
                DSBadge(label: CopyCatalog.shared.string(.resolved, language), tone: .success)
            } else if entry != nil, !isEditing {
                DSIconButton(.more, size: 24, iconSize: 14, action: showMore)
                    .background(DropdownAnchor(box: moreAnchor))
                    .dsTooltip(.moreActions)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: DSSpace.s4) {
            if let id = entry?.id {
                if isResolved {
                    DSButton(.reopen, style: .plain, size: .small) { session.setResolved(id, false) }
                } else {
                    DSButton(.reply, style: .plain, size: .small) { isReplying = true }
                    DSButton(.resolve, style: .plain, size: .small) { session.setResolved(id, true) }
                }
            }
        }
    }

    private func replyRow(_ reply: CommentInfo.Reply) -> some View {
        HStack(alignment: .top, spacing: DSSpace.s8) {
            DSAvatar(initials: initial(displayName(reply.author)), size: .xs, subtle: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(displayName(reply.author)).dsText(.labelSmall).foregroundColor(DSColor.textPrimary)
                Text(reply.text).dsText(.body).foregroundColor(isResolved ? DSColor.textTertiary : DSColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, DSSpace.s8)
    }

    private func editor(text: Binding<String>, placeholder: CopyKey, canSave: Bool,
                        cancel: @escaping () -> Void, save: @escaping () -> Void) -> some View {
        VStack(alignment: .trailing, spacing: DSSpace.s8) {
            DSTextArea(label: "", text: text, placeholder: CopyCatalog.shared.string(placeholder, language), autofocus: true)
            HStack(spacing: DSSpace.s8) {
                DSButton(.cancel, style: .plain, size: .small, action: cancel)
                    .keyboardShortcut(.cancelAction)
                DSButton(.save, style: .primary, size: .small, action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
            }
        }
    }

    // MARK: Helpers

    private var draftText: Binding<String> {
        Binding(get: { session.commentDraft?.text ?? "" }, set: { session.commentDraft?.text = $0 })
    }

    /// Avatar letter: the first base letter (a Khmer cluster such as អ្ន would show its coeng sign).
    private func initial(_ name: String) -> String {
        name.unicodeScalars.first.map { String(Character($0)) } ?? ""
    }

    /// "You" for this Mac's user.
    private func displayName(_ author: String) -> String {
        author == DocumentSession.currentAuthor ? CopyCatalog.shared.string(.you, language) : author
    }

    /// 10:24 today; otherwise the date (the interface language's digits).
    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "d/M/yyyy"
        return language.digits(formatter.string(from: date))
    }

    private func showMore() {
        guard let id = entry?.id, let view = moreAnchor.view, let menu = session.annotationMenu(for: id, language: language) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}

/// Figma Text Properties Panel (123:292): bundled font, size, line spacing, bold/italic/underline, alignment,
/// document colour and X/Y position of the box being typed in or the selected box. Nothing selected = disabled.
struct TextPropertiesPanel: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var font = 0

    var body: some View {
        let target = session.textBoxTarget
        let style = target?.style ?? TextBoxStyle()
        let position = session.textBoxPosition()
        // Figma Text Properties, Selection=PDF text line (555:842) / No PDF line selected (555:878).
        let pdfLine = session.textTargetIsPDFLine || (target == nil && session.annotateTool == .editText)
        VStack(alignment: .leading, spacing: DSSpace.s12) {
            VStack(alignment: .leading, spacing: DSSpace.s4) {
                DSLabel(pdfLine ? .pdfTextProperties : .addedTextProperties, style: .heading).foregroundColor(DSColor.textPrimary)
                DSLabel(pdfLine ? (target == nil ? .clickALineOfTextOnThePageToEdit : .appliesToTheSelectedLineOfPDFText)
                            : .appliesToTheSelectedAddedTextBox, style: .caption)
                    .foregroundColor(DSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                // Added text: only the bundled font (Khmer renders the same on every Mac). An edited PDF line keeps the
                // line's own font when this Mac has it.
                DSDropdown(label: string(.font), selection: $font, options: [(value: 0, title: fontTitle(style))])
                HStack(alignment: .top, spacing: DSSpace.s8) {
                    NumberField(label: .size, value: style.fontSize, unit: "pt", range: 6...96, decimals: 0) { value in
                        session.changeTextBoxStyle { $0.fontSize = value }
                    }
                    NumberField(label: .lineSpacing, value: style.lineSpacing, unit: nil, range: 1...3, decimals: 1) { value in
                        session.changeTextBoxStyle { $0.lineSpacing = value }
                    }
                }
                DSLabel(.format, style: .labelSmall).foregroundColor(DSColor.textSecondary)
                HStack(spacing: DSSpace.s2) {
                    DSToggleIconButton(icon: .textBold, label: .bold, isOn: style.bold) { session.changeTextBoxStyle { $0.bold.toggle() } }
                    DSToggleIconButton(icon: .textItalic, label: .italic, isOn: style.italic) { session.changeTextBoxStyle { $0.italic.toggle() } }
                    DSToggleIconButton(icon: .textUnderline, label: .underline, isOn: style.underline) {
                        session.changeTextBoxStyle { $0.underline.toggle() }
                    }
                    Rectangle().fill(DSColor.borderSubtle).frame(width: 1, height: 16)
                    alignment(.left, icon: .alignTextLeft, label: .alignLeft, current: style.alignment)
                    alignment(.center, icon: .alignTextCenter, label: .alignCenter, current: style.alignment)
                    alignment(.right, icon: .alignTextRight, label: .alignRight, current: style.alignment)
                }
                DSLabel(.colour, style: .labelSmall).foregroundColor(DSColor.textSecondary)
                HStack(spacing: DSSpace.s8) {
                    ForEach(TextBoxStyle.Swatch.allCases, id: \.self) { swatch in
                        DSColorSwatch(color: Color(.sRGB, red: swatch.rgb[0], green: swatch.rgb[1], blue: swatch.rgb[2]),
                                      name: swatch.name, isSelected: target != nil && style.swatch == swatch) {
                            session.changeTextBoxStyle { $0.color = swatch.rgb }
                        }
                    }
                }
                .padding(.leading, DSSpace.s2)
                DSDivider()
                if pdfLine {
                    // An edited line keeps its place: no Position.
                    DSButton(.restoreOriginalText, icon: .undo, fullWidth: true) { session.restoreOriginalText() }
                } else {
                    DSLabel(.position, style: .labelSmall).foregroundColor(DSColor.textSecondary)
                    HStack(alignment: .top, spacing: DSSpace.s8) {
                        NumberField(label: .x, value: position?.x ?? 0, unit: "pt", range: -10_000...10_000, decimals: 0) { session.setTextBoxPosition(x: $0) }
                        NumberField(label: .y, value: position?.y ?? 0, unit: "pt", range: -10_000...10_000, decimals: 0) { session.setTextBoxPosition(y: $0) }
                    }
                }
            }
            .disabled(target == nil)
            if !pdfLine {
                DSLabel(.saveWorkKeepsAddedTextEditable, style: .caption).foregroundColor(DSColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fontTitle(_ style: TextBoxStyle) -> String {
        guard let name = style.font else { return string(.notoSansKhmerBundled) }
        return CTFontCopyDisplayName(CTFontCreateWithName(name as CFString, 12, nil)) as String
    }

    private func string(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, language) }

    /// Alignment toggles behave as a radio group.
    private func alignment(_ value: TextBoxStyle.Alignment, icon: DSIcon, label: CopyKey, current: TextBoxStyle.Alignment) -> some View {
        DSToggleIconButton(icon: icon, label: label, isOn: current == value) { session.changeTextBoxStyle { $0.alignment = value } }
    }
}

/// A Text Field showing "14 pt" / "1.6" (Khmer or Latin digits). A valid value applies after a short pause in typing,
/// or at once with ↩, so typing "340" moves the box once (one undo), not to 3, then 34.
private struct NumberField: View {
    let label: CopyKey
    let value: CGFloat
    let unit: String?
    let range: ClosedRange<CGFloat>
    let decimals: Int
    let apply: (CGFloat) -> Void
    @State private var text = ""
    @State private var pending: Task<Void, Never>?
    @Environment(\.appLanguage) private var language

    var body: some View {
        DSTextField(label: label, text: $text, autofocus: false, onSubmit: {
            pending?.cancel()
            commit(text)
            text = formatted(value)
        })
        .onAppear { text = formatted(value) }
        .onChange(of: value) { newValue in if parsed(text) != newValue { text = formatted(newValue) } }
        .onChange(of: text) { newText in
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                commit(newText)
            }
        }
        .onDisappear { pending?.cancel() }
    }

    private func commit(_ text: String) {
        guard let number = parsed(text), range.contains(number), number != value else { return }
        apply(number)
    }

    private func formatted(_ number: CGFloat) -> String {
        let digits = String(format: "%.\(decimals)f", Double(number))
        return language.digits(digits) + (unit.map { " \($0)" } ?? "")
    }

    private func parsed(_ text: String) -> CGFloat? {
        let latin = String(text.unicodeScalars.compactMap { scalar -> Character? in
            if (0x17E0...0x17E9).contains(scalar.value) { return Character(String(scalar.value - 0x17E0)) }
            return CharacterSet(charactersIn: "0123456789.-").contains(scalar) ? Character(scalar) : nil
        })
        guard let number = Double(latin) else { return nil }
        return (CGFloat(number) * pow(10, CGFloat(decimals))).rounded() / pow(10, CGFloat(decimals))
    }
}

private extension TextBoxStyle.Swatch {
    var name: CopyKey {
        switch self {
        case .black: .black
        case .blue: .blue
        case .red: .red
        case .green: .green
        case .orange: .orange
        }
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
