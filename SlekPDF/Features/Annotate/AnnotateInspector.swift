import SwiftUI

/// Figma Annotate Panel (157:188): Annotate Tools, (Added text properties — Annotate step 3), and the comment list.
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

/// Figma Annotate Tools (125:135): the active tool is Primary; choosing it again returns to Select.
struct AnnotateToolsView: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s8) {
            tool(.addKhmerText, icon: .addText, tool: .text, command: .addTextTool)
                .disabled(true)  // Khmer text boxes: Annotate step 3
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
        case .select, .text: nil
        }
    }

    private func tool(_ title: CopyKey, icon: DSIcon, tool: AnnotateTool, command: ShortcutCommand) -> some View {
        DSButton(title, icon: icon, style: session.annotateTool == tool ? .primary : .secondary, fullWidth: true) {
            session.annotateTool = session.annotateTool == tool ? .select : tool
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

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
