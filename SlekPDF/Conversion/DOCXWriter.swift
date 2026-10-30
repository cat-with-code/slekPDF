import Foundation

/// Writes `ConvertedDocument` as an editable Word document (Office Open XML).
/// Khmer is a complex script in Word: it is rendered with the `w:cs` font and `w:szCs` size,
/// and tagged `w:bidi="km-KH"` (Word's attribute for the complex-script language).
nonisolated enum DOCXWriter {
    static let khmerFont = "Noto Sans Khmer"
    static let latinFont = "Inter"

    static func data(for document: ConvertedDocument) -> Data {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", rootRels)
        zip.add("word/_rels/document.xml.rels", documentRels)
        zip.add("word/styles.xml", styles)
        zip.add("docProps/core.xml", core(title: document.title))
        zip.add("word/document.xml", body(document))
        return zip.finish()
    }

    // MARK: - Body

    private static func body(_ document: ConvertedDocument) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#
        for block in document.blocks {
            switch block {
            case let .heading(level, text):
                xml += #"<w:p><w:pPr><w:pStyle w:val="Heading\#(min(max(level, 1), 3))"/></w:pPr>\#(run(TextRun(text: text)))</w:p>"#
            case let .paragraph(runs):
                xml += "<w:p>" + runs.map(run).joined() + "</w:p>"
            case let .table(table):
                xml += self.table(table)
            }
        }
        xml += #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>"#
        return xml
    }

    private static func run(_ run: TextRun) -> String {
        var props = ""
        if run.bold { props += "<w:b/><w:bCs/>" }
        if run.italic { props += "<w:i/><w:iCs/>" }
        return "<w:r>" + (props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>") + #"<w:t xml:space="preserve">\#(run.text.xmlEscaped)</w:t></w:r>"#
    }

    private static func table(_ table: Table) -> String {
        let columns = table.rows.map(\.count).max() ?? 0
        guard columns > 0 else { return "" }
        let width = 9026 / columns
        var xml = #"<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/><w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr><w:tblGrid>"#
        xml += String(repeating: #"<w:gridCol w:w="\#(width)"/>"#, count: columns) + "</w:tblGrid>"
        for (index, row) in table.rows.enumerated() {
            let header = index < table.headerRows
            xml += "<w:tr>" + (header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
            for column in 0..<columns {
                let text = column < row.count ? row[column].plainText : ""
                xml += #"<w:tc><w:tcPr><w:tcW w:w="\#(width)" w:type="dxa"/></w:tcPr><w:p>\#(run(TextRun(text: text, bold: header)))</w:p></w:tc>"#
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl><w:p/>"
    }

    // MARK: - Package parts

    private static let contentTypes = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>"#

    private static let rootRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>"#

    private static let documentRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#

    private static func core(title: String) -> String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\#(title.xmlEscaped)</dc:title><dc:creator>Slek PDF</dc:creator></cp:coreProperties>"#
    }

    private static var styles: String {
        let fonts = #"<w:rFonts w:ascii="\#(latinFont)" w:hAnsi="\#(latinFont)" w:eastAsia="\#(latinFont)" w:cs="\#(khmerFont)"/>"#
        func heading(_ level: Int, size: Int) -> String {
            #"<w:style w:type="paragraph" w:styleId="Heading\#(level)"><w:name w:val="heading \#(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="\#(level - 1)"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="\#(size)"/><w:szCs w:val="\#(size)"/></w:rPr></w:style>"#
        }
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr>\#(fonts)<w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:bidi="km-KH"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\#(heading(1, size: 32))\#(heading(2, size: 28))\#(heading(3, size: 24))<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders></w:tblPr></w:style></w:styles>"#
    }
}
