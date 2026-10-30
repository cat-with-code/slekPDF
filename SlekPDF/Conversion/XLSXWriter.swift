import Foundation

/// Writes tables as an Excel workbook (Office Open XML): one worksheet per table, typed cells,
/// text kept as text (inline strings with the "@" text format), a source-page note above each table.
nonisolated enum XLSXWriter {
    static let font = "Noto Sans Khmer"

    enum WriterError: Error { case noTables }

    static func data(for tables: [Table]) throws -> Data {
        guard !tables.isEmpty else { throw WriterError.noTables }
        let names = uniqueSheetNames(tables.map(\.name))
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes(sheets: tables.count))
        zip.add("_rels/.rels", rootRels)
        zip.add("xl/workbook.xml", workbook(names))
        zip.add("xl/_rels/workbook.xml.rels", workbookRels(sheets: tables.count))
        zip.add("xl/styles.xml", styles)
        for (index, table) in tables.enumerated() {
            zip.add("xl/worksheets/sheet\(index + 1).xml", sheet(table))
        }
        return zip.finish()
    }

    /// Excel: ≤ 31 characters, none of `: \ / ? * [ ]`, unique ignoring case.
    static func uniqueSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.enumerated().map { index, raw in
            var name = String(raw.unicodeScalars.filter { !":\\/?*[]".unicodeScalars.contains($0) })
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Table \(index + 1)" }
            name = String(name.prefix(31))
            var candidate = name, n = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(n))"
                candidate = String(name.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    // Style indexes in styles.xml cellXfs
    private enum Style: Int { case general = 0, text = 1, header = 2, thousands = 3, riel = 4, date = 5, note = 6 }

    private static func sheet(_ table: Table) -> String {
        let columns = max(table.rows.map(\.count).max() ?? 0, 1)
        var rows = #"<row r="1"><c r="A1" t="inlineStr" s="\#(Style.note.rawValue)"><is><t>Source: page \#(table.sourcePage)</t></is></c></row>"#
        for (rowIndex, row) in table.rows.enumerated() {
            let r = rowIndex + 3
            rows += #"<row r="\#(r)">"#
            for (column, cell) in row.enumerated() {
                let ref = columnName(column) + String(r)
                let header = rowIndex < table.headerRows
                switch cell {
                case .empty:
                    continue
                case let .text(text):
                    rows += #"<c r="\#(ref)" t="inlineStr" s="\#((header ? Style.header : .text).rawValue)"><is><t xml:space="preserve">\#(text.xmlEscaped)</t></is></c>"#
                case let .number(value, format):
                    let style: Style = switch format { case .general: .general; case .thousands: .thousands; case .riel: .riel }
                    rows += #"<c r="\#(ref)" s="\#(style.rawValue)"><v>\#(value)</v></c>"#
                case let .date(y, m, d):
                    rows += #"<c r="\#(ref)" s="\#(Style.date.rawValue)"><v>\#(excelSerial(y, m, d))</v></c>"#
                }
            }
            rows += "</row>"
        }
        let cols = (0..<columns).map { #"<col min="\#($0 + 1)" max="\#($0 + 1)" width="22" customWidth="1"/>"# }.joined()
        let freeze = table.headerRows > 0
            ? #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="\#(table.headerRows + 2)" topLeftCell="A\#(table.headerRows + 3)" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
            : ""
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\#(freeze)<cols>\#(cols)</cols><sheetData>\#(rows)</sheetData></worksheet>"#
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// Days since 1899-12-30 (Excel's 1900 date system, which skips the fictitious 29 Feb 1900).
    static func excelSerial(_ year: Int, _ month: Int, _ day: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        return calendar.dateComponents([.day], from: base, to: date).day!
    }

    // MARK: - Package parts

    private static func contentTypes(sheets: Int) -> String {
        let overrides = (1...sheets).map { #"<Override PartName="/xl/worksheets/sheet\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\#(overrides)</Types>"#
    }

    private static let rootRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#

    private static func workbook(_ names: [String]) -> String {
        let sheets = names.enumerated().map { #"<sheet name="\#($1.xmlEscaped)" sheetId="\#($0 + 1)" r:id="rId\#($0 + 1)"/>"# }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\#(sheets)</sheets></workbook>"#
    }

    private static func workbookRels(sheets: Int) -> String {
        let rels = (1...sheets).map { #"<Relationship Id="rId\#($0)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0).xml"/>"# }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(rels)<Relationship Id="rId\#(sheets + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#
    }

    /// cellXfs order matches `Style`. numFmt 49 = "@" (text); custom 164 = riel; 165 = ISO date.
    private static var styles: String {
        ##"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="2"><numFmt numFmtId="164" formatCode="#,##0 &quot;៛&quot;"/><numFmt numFmtId="165" formatCode="yyyy-mm-dd"/></numFmts><fonts count="3"><font><sz val="11"/><name val="\##(font)"/></font><font><b/><sz val="11"/><name val="\##(font)"/></font><font><i/><sz val="10"/><color rgb="FF717171"/><name val="\##(font)"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="7"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="49" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="49" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/><xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="49" fontId="2" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"##
    }
}
