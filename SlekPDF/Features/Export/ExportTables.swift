import CoreGraphics
import Foundation

/// A table found (or marked with Select table region) on a page; cells are editable in the Excel preview.
struct ExportTable: Identifiable, Equatable {
    let id = UUID()
    /// The page it sits on (PageRef, so it follows page edits).
    let pageID: DocumentSession.PageRef.ID
    /// Where it is on the page (page space); its lines are left out of the Word text and replaced by the table.
    let region: CGRect
    var rows: [[String]]
    var included = true

    /// Excel/Word table with reviewed values: text stays text (IDs, leading zeros, Khmer digits, “=…”); only plain
    /// Latin numbers become numbers (spike 03 rule — no guessing of dates).
    func converted(name: String, page: Int) -> Table {
        Table(name: name, sourcePage: page, headerRows: 1, rows: rows.map { $0.map(Self.cell) })
    }

    static func cell(_ text: String) -> Cell {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return .empty }
        let plain = value.replacingOccurrences(of: ",", with: "")
        let isNumber = plain.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$"#, options: .regularExpression) != nil
        guard isNumber, let number = Double(plain) else { return .text(value) }
        return .number(number, format: value.contains(",") ? .thousands : .general)
    }
}

/// Finds tables in text laid out in columns (no ruling lines needed): consecutive lines that split into cells at wide
/// gaps whose left edges line up.
nonisolated enum TableDetector {
    typealias Segment = KhmerTextRebuilder.Segment

    static func detect(_ lines: [[Segment]]) -> [(region: CGRect, rows: [[String]])] {
        var tables: [(CGRect, [[String]])] = []
        var run: [[Segment]] = []
        func close() {
            defer { run = [] }
            guard run.count >= 3, let table = build(run, minimumShare: 0.5) else { return }
            tables.append(table)
        }
        for line in lines {
            if line.count >= 2, let last = run.last, let lastBox = union(last), let box = union(line),
               lastBox.minY - box.maxY > max(lastBox.height, box.height) * 2.5 {
                close()
            }
            if line.count >= 2 { run.append(line) } else { close() }
        }
        close()
        return tables
    }

    /// Select table region: every line inside `rect` is a row; columns from the cells' left edges.
    static func table(in rect: CGRect, _ lines: [[Segment]]) -> (region: CGRect, rows: [[String]])? {
        let inside = lines.map { $0.filter { rect.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) } }.filter { !$0.isEmpty }
        guard !inside.isEmpty else { return nil }
        return build(inside, minimumShare: 0)
    }

    private static func union(_ segments: [Segment]) -> CGRect? {
        guard let first = segments.first?.box else { return nil }
        return segments.dropFirst().reduce(first) { $0.union($1.box) }
    }

    /// Columns = clusters of segment left edges used by at least `minimumShare` of the rows.
    private static func build(_ rows: [[Segment]], minimumShare: Double) -> (region: CGRect, rows: [[String]])? {
        let edges = rows.flatMap { $0.map(\.box.minX) }.sorted()
        var clusters: [[CGFloat]] = []
        for edge in edges {
            if let last = clusters.last?.last, edge - last <= 8 { clusters[clusters.count - 1].append(edge) } else { clusters.append([edge]) }
        }
        let needed = max(1, Int((Double(rows.count) * minimumShare).rounded(.up)))
        let anchors = clusters.filter { $0.count >= needed }.map { $0.reduce(0, +) / CGFloat($0.count) }
        guard anchors.count >= 2 || (minimumShare == 0 && !anchors.isEmpty) else { return nil }
        var table: [[String]] = []
        for row in rows {
            var cells = [String](repeating: "", count: anchors.count)
            for segment in row {
                let column = anchors.indices.min { abs(anchors[$0] - segment.box.minX) < abs(anchors[$1] - segment.box.minX) } ?? 0
                // A segment starting between two anchors belongs to the one on its left.
                let index = anchors[column] > segment.box.minX + 8 && column > 0 ? column - 1 : column
                cells[index] = cells[index].isEmpty ? segment.text : cells[index] + " " + segment.text
            }
            table.append(cells)
        }
        let filled = table.filter { $0.filter { !$0.isEmpty }.count >= 2 }.count
        guard minimumShare == 0 || Double(filled) >= Double(table.count) * 0.6 else { return nil }
        guard let region = rows.compactMap(union).reduce(nil, { (result: CGRect?, box) in result?.union(box) ?? box }) else { return nil }
        return (region, table)
    }
}

extension DocumentSession {
    /// Finds tables on the export pages (PDF text only; recognized scans need Select table region — OCR keeps lines,
    /// not columns). Tables marked by hand on other pages are kept.
    func detectExportTables() async {
        guard let id = pdfiumID, let indices = exportPageIndices else { return }
        var found: [ExportTable] = []
        for index in indices where pages.indices.contains(index) {
            let ref = pages[index]
            guard ocrResults[ref.id]?.lines.isEmpty ?? true else { continue }
            let lines = await PDFiumService.shared.textSegments(documentID(for: ref) ?? id, page: ref.source)
            found += TableDetector.detect(lines).map { ExportTable(pageID: ref.id, region: $0.region, rows: $0.rows) }
        }
        // Keep edits to a table that is found again in the same place.
        exportTables = found.map { table in
            exportTables.first { $0.pageID == table.pageID && $0.region == table.region } ?? table
        }
        exportTablesDetected = true
    }

    /// Select table region: the lines inside `rect` (page space) on page `index` become a table.
    @discardableResult
    func addExportTable(in rect: CGRect, onPageAt index: Int) async -> Bool {
        guard let id = pdfiumID, pages.indices.contains(index) else { return false }
        let lines = await PDFiumService.shared.textSegments(documentID(for: pages[index]) ?? id, page: pages[index].source)
        guard let table = TableDetector.table(in: rect, lines) else { return false }
        exportTables.removeAll { $0.pageID == pages[index].id && $0.region.intersects(table.region) }
        exportTables.append(ExportTable(pageID: pages[index].id, region: table.region, rows: table.rows))
        exportTables.sort { (pageNumber(of: $0) ?? 0, -$0.region.maxY) < (pageNumber(of: $1) ?? 0, -$1.region.maxY) }
        return true
    }

    /// 1-based page number of a table in the edited document.
    func pageNumber(of table: ExportTable) -> Int? {
        pages.firstIndex { $0.id == table.pageID }.map { $0 + 1 }
    }

    /// Included tables on the export pages, in page order.
    var includedExportTables: [ExportTable] {
        let scope = Set((exportPageIndices ?? []).filter { pages.indices.contains($0) }.map { pages[$0].id })
        return exportTables.filter { $0.included && scope.contains($0.pageID) }
    }

    /// Tables as written to Excel (“Table 1 — page 1”).
    func convertedExportTables(_ language: AppLanguage) -> [Table] {
        includedExportTables.enumerated().map { number, table in
            let page = pageNumber(of: table) ?? 1
            return table.converted(name: CopyCatalog.shared.format(.fmtTableNPageM2, language, number + 1, page), page: page)
        }
    }
}
