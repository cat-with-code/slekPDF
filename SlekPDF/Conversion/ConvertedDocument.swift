import Foundation

/// Structured, reviewed content handed to the Word/Excel writers (Setup §4: paragraphs, tables,
/// source page locations and recognition uncertainties). Built from PDFium text or reviewed OCR.
nonisolated struct ConvertedDocument: Sendable {
    var title: String
    var blocks: [Block]

    enum Block: Sendable {
        case heading(level: Int, text: String)
        case paragraph([TextRun])
        case table(Table)
    }
}

nonisolated struct TextRun: Sendable {
    var text: String
    var bold = false
    var italic = false
}

nonisolated struct Table: Sendable {
    /// Worksheet name in Excel (Excel limits: 31 characters, none of `: \ / ? * [ ]`).
    var name: String
    /// 1-based page the table came from.
    var sourcePage: Int
    var headerRows: Int = 1
    var rows: [[Cell]]
}

/// A reviewed cell value. Text stays text: leading zeros, IDs, Khmer digits and anything starting with
/// `=` are never coerced into numbers or formulas.
nonisolated enum Cell: Sendable, Equatable {
    case empty
    case text(String)
    case number(Double, format: NumberFormat = .general)
    /// Calendar date confirmed by the reviewer (not guessed from an ambiguous string).
    case date(year: Int, month: Int, day: Int)

    enum NumberFormat: Sendable, Equatable {
        case general, thousands, riel
    }

    var plainText: String {
        switch self {
        case .empty: ""
        case let .text(text): text
        case let .number(value, _): value.rounded() == value ? String(Int(value)) : String(value)
        case let .date(y, m, d): String(format: "%04d-%02d-%02d", y, m, d)
        }
    }
}
