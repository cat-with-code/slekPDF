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
                DSIconButton(.left, size: 20) { session.isSidebarVisible = false }
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

/// Figma "Document Canvas" (109:197): PDF pages with the floating page navigation.
struct DocumentCanvas: View {
    @EnvironmentObject private var session: DocumentSession

    var body: some View {
        // The page navigation sits in a band above the pages (Figma: pill 12 pt from the top, page from ~80 pt),
        // so pages never scroll underneath it.
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    DSLabel(.document, style: .caption).foregroundColor(DSColor.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, DSSpace.s24)
                PageNavigationPill()
            }
            .frame(height: 60)
            PDFCanvasView(session: session)
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

/// Figma "Inspector Panel" (159:554) for the Read workspace. Search is wired to PDFium in slice 4.
struct ReadInspectorView: View {
    @EnvironmentObject private var session: DocumentSession
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s16) {
                HStack {
                    DSLabel(.readSearch, style: .heading).foregroundColor(DSColor.textPrimary)
                    Spacer()
                    DSIconButton(.right, size: 24) { session.isInspectorVisible = false }
                }
                DSSearchField(text: $query)
                HStack(spacing: DSSpace.s8) {
                    DSButton(.previousResult, fullWidth: true)
                    DSButton(.nextResult, fullWidth: true)
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
            .padding(DSSpace.s16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DSColor.backgroundSurface)
    }
}
