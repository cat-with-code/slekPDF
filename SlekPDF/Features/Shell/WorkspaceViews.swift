import SwiftUI

/// Figma "Sidebar" (105:115) Side=Pages with "Page Thumbnail" (104:113). Placeholder thumbnails until PDFKit is wired in.
struct PageSidebarView: View {
    @State private var selectedPage = 1

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s12) {
            HStack {
                DSLabel(.pages, style: .label).foregroundColor(DSColor.textPrimary)
                Spacer()
                DSIcon.left.image(size: 12).foregroundColor(DSColor.textSecondary)
            }
            ScrollView {
                VStack(spacing: DSSpace.s12) {
                    ForEach(1...3, id: \.self) { page in
                        VStack(spacing: DSSpace.s4) {
                            RoundedRectangle(cornerRadius: DSRadius.xs)
                                .fill(DSColor.backgroundPage)
                                .frame(width: 64, height: 88)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DSRadius.xs)
                                        .strokeBorder(page == selectedPage ? DSColor.accentDefault : DSColor.borderOnPage,
                                                      lineWidth: page == selectedPage ? DSStroke.focus : DSStroke.default)
                                )
                            Text("\(page)")
                                .dsText(.caption)
                                .foregroundColor(page == selectedPage ? DSColor.textAccent : DSColor.textSecondary)
                        }
                        .onTapGesture { selectedPage = page }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(DSSpace.s12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DSColor.backgroundWindow)
    }
}

/// Figma "Document Canvas" (109:197). PDFKit's PDFView replaces the page placeholder in the next step.
struct DocumentCanvasPlaceholder: View {
    var body: some View {
        ZStack(alignment: .top) {
            DSColor.backgroundCanvas
            HStack {
                DSLabel(.document, style: .caption).foregroundColor(DSColor.textSecondary)
                Spacer()
            }
            .padding(DSSpace.s24)
            PageNavigationPill().padding(.top, DSSpace.s12)
            Rectangle()
                .fill(DSColor.backgroundPage)
                .frame(width: 360, height: 508)
                .dsElevation(.raised)
                .padding(.top, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// Figma "Page Navigation" (107:120).
struct PageNavigationPill: View {
    var body: some View {
        HStack(spacing: DSSpace.s8) {
            DSIcon.left.image(size: 12).foregroundColor(DSColor.textDisabled)
            Text("1")
                .dsText(.body)
                .frame(width: 36, height: 24)
                .background(RoundedRectangle(cornerRadius: DSRadius.xs).fill(DSColor.backgroundSurface))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.xs).strokeBorder(DSColor.borderDefault, lineWidth: DSStroke.default))
            Text("/ 3").dsText(.body).foregroundColor(DSColor.textSecondary)
            DSIcon.right.image(size: 12).foregroundColor(DSColor.textPrimary)
            DSDivider(axis: .vertical).frame(height: 18)
            DSIcon.zoomOut.image(size: 14)
            DSLabel(.fitPage, style: .label)
            DSIcon.zoomIn.image(size: 14)
        }
        .foregroundColor(DSColor.textPrimary)
        .padding(.horizontal, DSSpace.s12)
        .frame(height: 36)
        .background(Capsule().fill(DSColor.backgroundSurface))
        .dsElevation(.popover)
    }
}

/// Figma "Inspector Panel" (159:554) for the Read workspace.
struct ReadInspectorView: View {
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s16) {
                HStack {
                    DSLabel(.readSearch, style: .heading).foregroundColor(DSColor.textPrimary)
                    Spacer()
                    DSIconButton(.right, size: 24)
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
