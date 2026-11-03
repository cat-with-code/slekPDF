import PDFKit
import SwiftUI

/// Review text filter (OCR Review Panel 129:111).
enum OCRReviewFilter: Hashable { case uncertain, all }

/// One line to review: its page (PageRef, so it follows page edits) and line.
struct OCRItemRef: Hashable {
    let pageID: DocumentSession.PageRef.ID
    let lineID: OCRLine.ID
}

extension DocumentSession {
    /// Lines to review in reading order (pages in order, lines as Tesseract read them).
    var ocrReviewItems: [OCRItemRef] {
        pages.flatMap { ref in
            (ocrResults[ref.id]?.lines ?? [])
                .filter { ocrReviewFilter == .all || $0.isUncertain }
                .map { OCRItemRef(pageID: ref.id, lineID: $0.id) }
        }
    }

    func ocrLine(_ item: OCRItemRef) -> OCRLine? {
        ocrResults[item.pageID]?.lines.first { $0.id == item.lineID }
    }

    /// The item shown in the panel: the chosen one if it is still listed, else the first unreviewed (else the last).
    var currentOCRItem: OCRItemRef? {
        let items = ocrReviewItems
        if let item = ocrReviewItem, items.contains(item) { return item }
        return items.first { ocrLine($0)?.reviewed == false } ?? items.last
    }

    var allOCRItemsReviewed: Bool {
        let items = ocrReviewItems
        return !items.isEmpty && items.allSatisfy { ocrLine($0)?.reviewed == true }
    }

    /// Shows `item` in the panel and its page in the canvas.
    func selectOCRItem(_ item: OCRItemRef) {
        ocrReviewItem = item
        if let index = pages.firstIndex(where: { $0.id == item.pageID }), index != currentPageIndex { goToPage(index) }
    }

    func moveOCRItem(by offset: Int) {
        let items = ocrReviewItems
        guard let current = currentOCRItem, let index = items.firstIndex(of: current) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        selectOCRItem(items[target])
    }

    /// Mark reviewed: keeps `text` as the correction when it differs from what was read, then moves to the next
    /// unreviewed item (undoable).
    func markOCRItemReviewed(_ item: OCRItemRef, text: String) {
        guard var page = ocrResults[item.pageID], let index = page.lines.firstIndex(where: { $0.id == item.lineID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        page.lines[index].correction = trimmed == page.lines[index].text || trimmed.isEmpty ? nil : trimmed
        page.lines[index].reviewed = true
        setOCR(page, for: item.pageID)
        skipOCRItem(item)
    }

    /// Skip: the next unreviewed item after `item` (wrapping), without marking it.
    func skipOCRItem(_ item: OCRItemRef) {
        let items = ocrReviewItems
        guard let index = items.firstIndex(of: item) else { return }
        let after = items[(index + 1)...] + items[..<index]
        if let next = after.first(where: { ocrLine($0)?.reviewed == false }) {
            selectOCRItem(next)
        } else {
            ocrReviewItem = item  // all reviewed: the panel shows the All reviewed state
        }
    }
}

// MARK: - Canvas (Figma 04: Source page | Recognized text)

/// Figma 04 Document Canvas · Side by side: the page with Uncertain Regions next to the OCR Review Panel.
struct OCRCanvas: View {
    @EnvironmentObject private var session: DocumentSession

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DSSpace.s16) {
                DSLabel(.sourceTextReview, style: .caption).foregroundColor(DSColor.textSecondary)
                    .padding(.top, DSSpace.s24)
                HStack(alignment: .top, spacing: DSSpace.s24) {
                    VStack(alignment: .leading, spacing: DSSpace.s8) {
                        DSLabel(.sourcePage, style: .caption).foregroundColor(DSColor.textSecondary)
                        OCRSourcePage()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    VStack(alignment: .leading, spacing: DSSpace.s8) {
                        DSLabel(.recognizedText, style: .caption).foregroundColor(DSColor.textSecondary)
                        OCRReviewPanel()
                    }
                    .frame(width: 396)
                }
                .padding(.top, DSSpace.s16)
            }
            .padding(.horizontal, DSSpace.s24)
            .padding(.bottom, DSSpace.s24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            PageNavigationPill().padding(.top, DSSpace.s12)
        }
        .background(DSColor.backgroundCanvas)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// The current page as an image with its review items marked (Figma Uncertain Region 129:14).
struct OCRSourcePage: View {
    /// Export shows the page alone.
    var showsRegions = true
    /// Export: tables on this page (page space), outlined.
    var tableRegions: [CGRect] = []
    /// Export Select table region: called with the dragged rectangle in page space.
    var onRegionSelected: ((CGRect) -> Void)?
    @EnvironmentObject private var session: DocumentSession
    @State private var drag: CGRect?
    @Environment(\.appLanguage) private var language

    var body: some View {
        GeometryReader { geometry in
            if let page = session.document?.page(at: session.currentPageIndex) {
                let box = page.bounds(for: .mediaBox)
                let turned = page.rotation % 180 != 0
                let pageSize = turned ? CGSize(width: box.height, height: box.width) : box.size
                let scale = min(geometry.size.width / pageSize.width, geometry.size.height / pageSize.height)
                let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox))
                        .resizable()
                        .frame(width: size.width, height: size.height)
                    ForEach(Array(tableRegions.enumerated()), id: \.offset) { _, region in
                        let frame = Self.rect(region, rotation: page.rotation, box: box, size: size)
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(DSPrimitive.blue500, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .allowsHitTesting(false)
                    }
                    if let drag {
                        Rectangle().fill(DSPrimitive.blue100.opacity(0.4)).overlay(Rectangle().strokeBorder(DSPrimitive.blue500, lineWidth: 1.5))
                            .frame(width: drag.width, height: drag.height)
                            .offset(x: drag.minX, y: drag.minY)
                            .allowsHitTesting(false)
                    }
                    ForEach(regions, id: \.item) { region in
                        let frame = Self.rect(region.line.bounds, rotation: page.rotation, box: box, size: size)
                        UncertainRegion(number: region.number, state: region.state)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .onTapGesture { session.selectOCRItem(region.item) }
                            .accessibilityLabel(CopyCatalog.shared.format(.fmtItemNOfM, language, region.number, session.ocrReviewItems.count))
                    }
                }
                .frame(width: size.width, height: size.height)
                .background(DSColor.backgroundPage)
                .dsElevation(.raised)
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .local)
                    .onChanged { value in
                        guard onRegionSelected != nil else { return }
                        drag = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                      width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
                    }
                    .onEnded { _ in
                        guard let selected = drag, let onRegionSelected else { return }
                        drag = nil
                        onRegionSelected(Self.pageRect(selected, rotation: page.rotation, box: box, size: size))
                    },
                    including: onRegionSelected == nil ? .subviews : .all)
            }
        }
    }

    private struct Region {
        let item: OCRItemRef
        let line: OCRLine
        let number: Int
        let state: UncertainRegion.State
    }

    /// Items on the current page, numbered as in “Item n of N”.
    private var regions: [Region] {
        guard showsRegions, session.pages.indices.contains(session.currentPageIndex) else { return [] }
        let pageID = session.pages[session.currentPageIndex].id
        // Once everything is reviewed, no item is “being corrected”: all show as Reviewed.
        let current = session.allOCRItemsReviewed ? nil : session.currentOCRItem
        return session.ocrReviewItems.enumerated().compactMap { index, item in
            guard item.pageID == pageID, let line = session.ocrLine(item) else { return nil }
            let state: UncertainRegion.State = item == current ? .active : line.reviewed ? .reviewed : .default
            return Region(item: item, line: line, number: index + 1, state: state)
        }
    }

    /// Displayed (turned) image rectangle → page space (inverse of `rect`).
    static func pageRect(_ rect: CGRect, rotation: Int, box: CGRect, size: CGSize) -> CGRect {
        func point(_ p: CGPoint) -> CGPoint {
            let tx = p.x / size.width, ty = p.y / size.height
            let (a, b): (CGFloat, CGFloat) = switch (rotation % 360 + 360) % 360 {
            case 90: (ty, 1 - tx)
            case 180: (1 - tx, 1 - ty)
            case 270: (1 - ty, tx)
            default: (tx, ty)
            }
            return CGPoint(x: box.minX + a * box.width, y: box.minY + (1 - b) * box.height)
        }
        let p1 = point(CGPoint(x: rect.minX, y: rect.minY)), p2 = point(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }

    /// Page-space rectangle → top-left points in the displayed (turned) page image of `size`.
    static func rect(_ bounds: CGRect, rotation: Int, box: CGRect, size: CGSize) -> CGRect {
        func point(_ p: CGPoint) -> CGPoint {
            let a = (p.x - box.minX) / box.width, b = 1 - (p.y - box.minY) / box.height  // unturned, top-left, 0–1
            let turned: CGPoint = switch (rotation % 360 + 360) % 360 {
            case 90: CGPoint(x: 1 - b, y: a)
            case 180: CGPoint(x: 1 - a, y: 1 - b)
            case 270: CGPoint(x: b, y: 1 - a)
            default: CGPoint(x: a, y: b)
            }
            return CGPoint(x: turned.x * size.width, y: turned.y * size.height)
        }
        let p1 = point(CGPoint(x: bounds.minX, y: bounds.minY)), p2 = point(CGPoint(x: bounds.maxX, y: bounds.maxY))
        return CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y)).insetBy(dx: -2, dy: -2)
    }
}

/// Figma Uncertain Region (129:14): Default = dashed warning outline, Active = accent (being corrected),
/// Reviewed = green with ✓. Fixed primitives: the page is always white. Fills are translucent so the text stays readable.
struct UncertainRegion: View {
    enum State { case `default`, active, reviewed }

    let number: Int
    let state: State
    @Environment(\.appLanguage) private var language

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(fill.opacity(0.45))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(stroke, style: strokeStyle))
            .overlay(alignment: .topLeading) {
                Text(state == .reviewed ? "✓ \(language.number(number))" : language.number(number))
                    .dsText(.labelSmall)
                    .foregroundColor(.white)
                    .padding(.horizontal, DSSpace.s8)
                    .padding(.vertical, DSSpace.s2)
                    .background(Capsule().fill(stroke))
                    .fixedSize()
                    .offset(x: -8, y: -12)
            }
            .contentShape(Rectangle())
    }

    private var fill: Color {
        switch state {
        case .default: DSPrimitive.orange200
        case .active: DSPrimitive.blue100
        case .reviewed: DSPrimitive.green100
        }
    }

    private var stroke: Color {
        switch state {
        case .default: DSPrimitive.orange700
        case .active: DSPrimitive.blue500
        case .reviewed: DSPrimitive.green800
        }
    }

    private var strokeStyle: StrokeStyle {
        switch state {
        case .default: StrokeStyle(lineWidth: 1, dash: [5, 3])
        case .active: StrokeStyle(lineWidth: 2)
        case .reviewed: StrokeStyle(lineWidth: 1)
        }
    }
}

// MARK: - OCR Review Panel (129:111)

struct OCRReviewPanel: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language
    @State private var correction = ""
    @State private var editingItem: OCRItemRef?

    var body: some View {
        let items = session.ocrReviewItems
        let current = session.currentOCRItem
        let line = current.flatMap(session.ocrLine)
        VStack(alignment: .leading, spacing: DSSpace.s12) {
            DSDropdown(label: string(.reviewText), selection: $session.ocrReviewFilter, options: [
                (value: OCRReviewFilter.uncertain, title: string(.uncertainRegions)),
                (value: .all, title: string(.allText)),
            ])
            if session.ocrResults.isEmpty {
                DSLabel(.recognizeTextToReviewItHere, style: .body).foregroundColor(DSColor.textSecondary)
            } else if items.isEmpty {
                DSLabel(.noUncertainRegionsOnRecognizedPages, style: .body).foregroundColor(DSColor.textSecondary)
            } else if let current, let line {
                navigation(items: items, current: current)
                badge(line)
                VStack(alignment: .leading, spacing: DSSpace.s4) {
                    DSTextArea(label: string(.correctSelectedText), text: $correction)
                    DSLabel(.correctionsUpdateExtractedTextTheS, style: .caption).foregroundColor(DSColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions(current)
            }
        }
        .padding(DSSpace.s16)
        .background(RoundedRectangle(cornerRadius: DSRadius.md).fill(DSColor.backgroundSurface))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.md).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .onAppear { load(current) }
        .onChange(of: current) { load($0) }
    }

    private func navigation(items: [OCRItemRef], current: OCRItemRef) -> some View {
        let index = items.firstIndex(of: current) ?? 0
        return HStack(spacing: DSSpace.s8) {
            Text(session.allOCRItemsReviewed
                 ? CopyCatalog.shared.count(.fmtAllNItemsReviewed, language, items.count)
                 : CopyCatalog.shared.format(.fmtItemNOfM, language, index + 1, items.count))
                .dsText(.label).foregroundColor(DSColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            DSButton(.previous, size: .small) { session.moveOCRItem(by: -1) }.disabled(index == 0)
            DSButton(.next, size: .small) { session.moveOCRItem(by: 1) }.disabled(index == items.count - 1)
        }
    }

    @ViewBuilder private func badge(_ line: OCRLine) -> some View {
        if line.reviewed {
            DSBadge(label: string(.reviewed), tone: .success)
        } else if line.isUncertain {
            DSBadge(label: string(.lowConfidenceCheckSpelling), tone: .warning)
        }
    }

    @ViewBuilder private func actions(_ item: OCRItemRef) -> some View {
        HStack(spacing: DSSpace.s8) {
            if session.allOCRItemsReviewed {
                DSButton(.reviewExportOptions, icon: .download, style: .primary, fullWidth: true) { session.workspace = .export }
            } else {
                DSButton(.skip, style: .plain) { session.skipOCRItem(item) }
                DSButton(.markReviewed, style: .primary, fullWidth: true) { session.markOCRItemReviewed(item, text: correction) }
                    .shortcut(.markReviewed)
            }
        }
    }

    /// The text area starts from the line's current text (its correction, or what was read).
    private func load(_ item: OCRItemRef?) {
        guard item != editingItem else { return }
        editingItem = item
        correction = item.flatMap(session.ocrLine)?.displayText ?? ""
    }

    private func string(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, language) }
}
