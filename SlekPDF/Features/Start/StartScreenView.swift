import SwiftUI

/// Prototype "11 Open a document" (164:6378) and "44 Open · drag over" (410:51293).
struct StartScreenView: View {
    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var recents: RecentDocuments

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s12) {
                FileDropZone(isTargeted: session.isDropTargeted) { session.isImporterPresented = true }
                if !recents.entries.isEmpty {
                    DSLabel(.recentDocuments, style: .labelSmall)
                        .foregroundColor(DSColor.textSecondary)
                        .padding(.top, DSSpace.s12)
                    VStack(spacing: DSSpace.s2) {
                        ForEach(recents.entries) { entry in
                            RecentFileRow(entry: entry)
                        }
                    }
                    .padding(DSSpace.s4)
                    .background(RoundedRectangle(cornerRadius: DSRadius.shell).fill(DSColor.backgroundSurface))
                }
            }
            .frame(width: 520)
            .padding(.vertical, 96)
            .frame(maxWidth: .infinity)
        }
        .background(DSColor.backgroundCanvas)
    }
}

/// Figma "File Drop Zone" (134:46), State=Default / Drag over.
struct FileDropZone: View {
    let isTargeted: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: DSSpace.s12) {
            (isTargeted ? DSIcon.download : DSIcon.folderOpen).image(size: 40)
                .foregroundColor(isTargeted ? DSColor.textAccent : DSColor.textSecondary)
            DSLabel(.openAPDF, style: .title).foregroundColor(DSColor.textPrimary)
            DSLabel(.dragAPDFHereOrChooseOneFromYour, style: .body).foregroundColor(DSColor.textSecondary)
            if !isTargeted {
                DSButton(.choosePDF, style: .primary, action: choose)
            }
            DSLabel(.filesStayOnThisMacNothingIsUplo, style: .caption).foregroundColor(DSColor.textTertiary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, DSSpace.s32)
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .background(RoundedRectangle(cornerRadius: DSRadius.lg).fill(isTargeted ? DSColor.backgroundSelected : DSColor.backgroundSurface))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.lg)
                .strokeBorder(isTargeted ? DSColor.accentDefault : DSColor.borderStrong,
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [8, 6]))
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

/// Figma "Recent File" (134:94), State=Default / Hover / Missing.
struct RecentFileRow: View {
    let entry: RecentDocuments.Entry
    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var recents: RecentDocuments
    @Environment(\.appLanguage) private var language
    @State private var isHovered = false

    var body: some View {
        let url = recents.resolve(entry)
        Button {
            if let url { Task { await session.open(url) } }
        } label: {
            HStack(spacing: DSSpace.s12) {
                DSIcon.fileTypePdf.image(size: 28).opacity(url == nil ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name)
                        .dsText(.label)
                        .foregroundColor(url == nil ? DSColor.textTertiary : DSColor.textPrimary)
                    Group {
                        if let url {
                            Text(DisplayPath.folder(of: url) + " · " + RecentDateFormatter.string(entry.lastOpened, language: language))
                                .truncationMode(.middle)
                                .foregroundColor(DSColor.textTertiary)
                        } else {
                            DSLabel(.fileWasMovedOrDeleted, style: .caption).foregroundColor(DSColor.statusWarning)
                        }
                    }
                    .dsText(.caption)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, DSSpace.s8)
            .padding(.horizontal, DSSpace.s12)
            .background(RoundedRectangle(cornerRadius: DSRadius.md).fill(isHovered && url != nil ? DSColor.backgroundHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .onHover { isHovered = $0 }
    }
}
