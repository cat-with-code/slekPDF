import SwiftUI

/// Figma "Sidebar" (105:115) Side=Pages with "Page Thumbnail" (104:113).
struct PageSidebarView: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    private let thumbnailSize = CGSize(width: 64, height: 88)

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s12) {
            HStack {
                DSLabel(.pages, style: .label).foregroundColor(DSColor.textPrimary)
                Spacer()
                DSIconButton(.left, size: 24, iconSize: 14) { session.isSidebarVisible = false }
                    .help(CopyCatalog.shared.string(.hidePageSidebar, language))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: DSSpace.s12) {
                        ForEach(0..<session.pageCount, id: \.self) { index in
                            thumbnail(index).id(index)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: session.currentPageIndex) { index in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
        .padding(DSSpace.s12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DSColor.backgroundWindow)
    }

    private func thumbnail(_ index: Int) -> some View {
        let isSelected = index == session.currentPageIndex
        return Button { session.goToPage(index) } label: {
            VStack(spacing: DSSpace.s4) {
                ZStack {
                    DSColor.backgroundPage
                    if let image = session.thumbnail(for: index, size: thumbnailSize) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.xs))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.xs)
                        .strokeBorder(isSelected ? DSColor.accentDefault : DSColor.borderOnPage,
                                      lineWidth: isSelected ? DSStroke.focus : DSStroke.default)
                )
                Text(language.number(index + 1))
                    .dsText(.caption)
                    .foregroundColor(isSelected ? DSColor.textAccent : DSColor.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Figma "Sidebar" (105:115) Side=Pages, State=Collapsed: a 40 pt rail with Expand and Pages buttons.
struct CollapsedSidebarRail: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: DSSpace.s8) {
            DSIconButton(.right, size: 24, iconSize: 14) { session.isSidebarVisible = true }
                .help(CopyCatalog.shared.string(.showPageSidebar, language))
            DSIconButton(.page, size: 24, iconSize: 14) { session.isSidebarVisible = true }
                .help(CopyCatalog.shared.string(.pages, language))
            Spacer()
        }
        .padding(.top, DSSpace.s8)
        .frame(width: 40)
        .background(DSColor.backgroundWindow)
    }
}

/// Figma "Inspector Panel" (159:554) State=Collapsed: a 40 pt rail with Expand and Search buttons.
struct CollapsedInspectorRail: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: DSSpace.s8) {
            DSIconButton(.left, size: 24, iconSize: 14) { session.isInspectorVisible = true }
                .help(CopyCatalog.shared.string(.showInspector, language))
            DSIconButton(.search, size: 24, iconSize: 14) {
                session.isInspectorVisible = true
                // Focus once the expanded panel's search field exists.
                DispatchQueue.main.async { session.focusSearch() }
            }
            .help(CopyCatalog.shared.string(.search, language))
            Spacer()
        }
        .padding(.top, DSSpace.s8)
        .frame(width: 40)
        .background(DSColor.backgroundSurface)
    }
}

/// Figma "Document Canvas" (109:197): PDF pages with the floating page navigation.
struct DocumentCanvas: View {
    @EnvironmentObject private var session: DocumentSession

    var body: some View {
        // Pages fill the whole canvas; the page navigation floats over them (Figma: 12 pt from the top).
        // PDFCanvasView insets its scroll area so the first page starts below the card.
        ZStack(alignment: .top) {
            PDFCanvasView(session: session)
            HStack {
                DSLabel(.document, style: .caption).foregroundColor(DSColor.textSecondary)
                Spacer()
            }
            .padding(.horizontal, DSSpace.s24)
            .padding(.top, DSSpace.s24)
            .allowsHitTesting(false)
            PageNavigationPill().padding(.top, DSSpace.s12)
        }
        .background(DSColor.backgroundCanvas)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// Figma "Page Navigation" (107:120).
struct PageNavigationPill: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var pageText = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        HStack(spacing: DSSpace.s8) {
            DSIconButton(.left, size: 24) { session.previousPage() }
                .disabled(session.currentPageIndex == 0)
            TextField("", text: $pageText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .dsText(.body)
                .focused($isEditing)
                .onSubmit(commitPage)
                .frame(width: 36, height: 24)
                .background(RoundedRectangle(cornerRadius: DSRadius.xs).fill(DSColor.backgroundSurface))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.xs).strokeBorder(isEditing ? DSColor.borderFocus : DSColor.borderDefault, lineWidth: DSStroke.default))
            Text("/ " + language.number(session.pageCount)).dsText(.body).foregroundColor(DSColor.textSecondary)
            DSIconButton(.right, size: 24) { session.nextPage() }
                .disabled(session.currentPageIndex >= session.pageCount - 1)
            DSDivider(axis: .vertical).frame(height: 18)
            DSIconButton(.zoomOut, size: 24) { session.zoomOut() }
            Button { session.fitPage() } label: { DSLabel(.fitPage, style: .label) }
                .buttonStyle(.plain)
            DSIconButton(.zoomIn, size: 24) { session.zoomIn() }
        }
        .foregroundColor(DSColor.textPrimary)
        .padding(.horizontal, DSSpace.s12)
        .frame(height: 36)
        .background(Capsule().fill(DSColor.backgroundSurface))
        .dsElevation(.popover)
        .onAppear(perform: syncPageText)
        .onChange(of: session.currentPageIndex) { _ in syncPageText() }
        .onChange(of: language) { _ in syncPageText() }
    }

    private func syncPageText() {
        pageText = language.number(session.currentPageIndex + 1)
    }

    /// Accepts Latin or Khmer digits.
    private func commitPage() {
        let latin = String(pageText.unicodeScalars.map { scalar in
            (0x17E0...0x17E9).contains(scalar.value) ? Character(Unicode.Scalar(scalar.value - 0x17E0 + 48)!) : Character(scalar)
        })
        if let page = Int(latin.trimmingCharacters(in: .whitespaces)) { session.goToPage(page - 1) }
        syncPageText()
    }
}

/// Figma "Inspector Panel" (159:554) for the Read workspace; while searching it becomes the
/// "Search Results Panel" (142:87, prototype 24 Read · search results).
struct ReadInspectorView: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: session.isSearchActive ? DSSpace.s12 : DSSpace.s16) {
                HStack {
                    DSLabel(.readSearch, style: .heading).foregroundColor(DSColor.textPrimary)
                    Spacer()
                    DSIconButton(.right, size: 24, iconSize: 14) { session.isInspectorVisible = false }
                        .help(CopyCatalog.shared.string(.hideInspector, language))
                }
                DSSearchField(text: $session.searchQuery,
                              matchLabel: matchLabel,
                              noResults: session.isSearchActive && !session.isSearching && session.searchResults.isEmpty,
                              focusRequest: session.searchFocusRequest,
                              onPrevious: session.previousMatch, onNext: session.nextMatch, onSubmit: session.nextMatch)
                if session.isSearchActive {
                    searchResults
                } else {
                    readTools
                }
            }
            .padding(DSSpace.s16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DSColor.backgroundSurface)
    }

    private var matchLabel: String? {
        guard let current = session.currentMatchIndex else { return nil }
        return CopyCatalog.shared.format(.fmtNOfM, language, current + 1, session.searchResults.count)
    }

    @ViewBuilder private var searchResults: some View {
        HStack(spacing: DSSpace.s16) {
            DSCheckbox(label: .matchCase, isOn: $session.matchCase)
            DSCheckbox(label: .wholeWord, isOn: $session.wholeWord)
        }
        if session.isSearching {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else if session.searchResults.isEmpty {
            NoSearchResults(query: session.searchQuery)
        } else {
            Text(CopyCatalog.shared.resultsSummary(results: session.searchResults.count, pages: session.searchPageCount, language))
                .dsText(.labelSmall)
                .foregroundColor(DSColor.textSecondary)
            LazyVStack(spacing: DSSpace.s2) {
                ForEach(Array(session.searchResults.enumerated()), id: \.offset) { index, match in
                    SearchResultRow(match: match, isSelected: index == session.currentMatchIndex) { session.selectMatch(index) }
                }
            }
        }
    }

    @ViewBuilder private var readTools: some View {
        HStack(spacing: DSSpace.s8) {
            DSButton(.previousResult, fullWidth: true).disabled(true)
            DSButton(.nextResult, fullWidth: true).disabled(true)
        }
        DSLabel(.searchResultsAppearHere, style: .caption).foregroundColor(DSColor.textSecondary)
        DSDivider()
        DSButton(.selectCopyText, icon: .copy, fullWidth: true)
        DSButton(.rotateView, icon: .rotate, fullWidth: true)
        DSDivider()
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            DSLabel(.scannedPages, style: .heading).foregroundColor(DSColor.textPrimary)
            DSLabel(.recognizeTextToEnableSearchingAndC, style: .caption).foregroundColor(DSColor.textSecondary)
        }
        DSButton(.openKhmerOCR, icon: .textRecognition, style: .primary, fullWidth: true)
    }
}

/// Figma "Search Result" (142:86): page location + snippet with the match in the accent colour.
struct SearchResultRow: View {
    let match: PDFiumMatch
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.appLanguage) private var language
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DSSpace.s2) {
                Text(CopyCatalog.shared.format(.fmtPageN, language, match.page + 1))
                    .dsText(.caption)
                    .foregroundColor(isSelected ? DSColor.textAccent : DSColor.textTertiary)
                snippet.lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DSSpace.s8)
            .padding(.horizontal, DSSpace.s12)
            .background(RoundedRectangle(cornerRadius: DSRadius.sm)
                .fill(isSelected ? DSColor.backgroundSelected : isHovered ? DSColor.backgroundHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var snippet: Text {
        func clean(_ text: String) -> String { text.components(separatedBy: .newlines).joined(separator: " ") }
        // Short lead-in so the match is always visible (Figma: "…ឈ្មោះ សាលារៀន បឋមសិក្សា…").
        let before = String(clean(match.before).suffix(10))
        let body = DSTextStyle.body.spec(for: language), strong = DSTextStyle.bodyStrong.spec(for: language)
        return Text("…" + before).font(.custom(body.postScriptName, fixedSize: body.size)).foregroundColor(DSColor.textPrimary)
            + Text(clean(match.match)).font(.custom(strong.postScriptName, fixedSize: strong.size)).foregroundColor(DSColor.textAccent)
            + Text(clean(match.after) + "…").font(.custom(body.postScriptName, fixedSize: body.size)).foregroundColor(DSColor.textPrimary)
    }
}

/// Figma "Empty State" (144:74), Type=No search results.
struct NoSearchResults: View {
    let query: String
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: DSSpace.s8) {
            DSIcon.search.image(size: 24)
                .foregroundColor(DSColor.textSecondary)
                .frame(width: 48, height: 48)
                .background(Circle().fill(DSColor.backgroundHover))
                .padding(.bottom, DSSpace.s4)
            Text(CopyCatalog.shared.format(.fmtNoMatchesForQuery, language, query))
                .dsText(.heading).foregroundColor(DSColor.textPrimary)
            DSLabel(.checkTheSpellingTryFewerWords, style: .body).foregroundColor(DSColor.textSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpace.s24)
        .padding(.horizontal, DSSpace.s16)
    }
}
