import XCTest
@testable import SlekPDF

/// Spike 03: Word/Excel export without Office. Writes sample files into the app container; they are
/// checked independently by Tools/fixtures/run_office_spike.sh (python-docx, openpyxl, textutil, Quick Look).
@MainActor
final class OfficeExportSpikeTests: XCTestCase {
    private let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("office-spike")

    static let invoiceTable = Table(name: "ទំព័រ ២ · តារាង ១", sourcePage: 2, rows: [
        [.text("លេខរៀង"), .text("ឈ្មោះ"), .text("លេខសម្គាល់"), .text("តម្លៃ (៛)"), .text("កាលបរិច្ឆេទ"), .text("ចំណាំ")],
        [.text("១"), .text("សុខ ចាន់ដារា"), .text("007"), .number(12500, format: .riel), .date(year: 2026, month: 10, day: 30), .text("=SUM(A1:A3)")],
        [.text("២"), .text("Sok Dara"), .text("0042"), .number(1_250_000, format: .riel), .text("១២/១០/២០២៦"), .text("ថ្ងៃខែមិនច្បាស់ — រក្សាជាអត្ថបទ")],
        [.text("៣"), .text("ព្រះរាជាណាចក្រកម្ពុជា"), .text("000123"), .number(3.75), .empty, .text("ក្រសួង")],
    ])

    func testWriteSampleDocxAndXlsx() throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let document = ConvertedDocument(title: "របាយការណ៍សាកល្បង", blocks: [
            .heading(level: 1, text: "របាយការណ៍ប្រចាំខែ / Monthly report"),
            .paragraph([TextRun(text: "សាលារៀនបឋមសិក្សា ភូមិថ្មី។ "), TextRun(text: "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ", bold: true), TextRun(text: " — reviewed.")]),
            .heading(level: 2, text: "ស្ត្រី ក្រសួង ព្រះរាជាណាចក្រកម្ពុជា"),
            .paragraph([TextRun(text: "លេខ ០១២៣៤៥៦៧៨៩ · ថ្ងៃទី ៣០ ខែតុលា ឆ្នាំ ២០២៦ · Invoice លេខ INV-0042 តម្លៃ 12,500 ៛", italic: true)]),
            .table(Self.invoiceTable),
        ])
        try DOCXWriter.data(for: document).write(to: outDir.appendingPathComponent("sample.docx"))

        let second = Table(name: "Invoice: 2026/10 [draft]", sourcePage: 3, rows: [[.text("A")], [.number(1)]])
        let duplicate = Table(name: "ទំព័រ ២ · តារាង ១", sourcePage: 4, rows: [[.text("B")]])
        try XLSXWriter.data(for: [Self.invoiceTable, second, duplicate]).write(to: outDir.appendingPathComponent("sample.xlsx"))
    }

    func testSheetNamesAndColumnsFollowExcelRules() {
        let names = XLSXWriter.uniqueSheetNames(["ទំព័រ ២ · តារាង ១", "Invoice: 2026/10 [draft]", "ទំព័រ ២ · តារាង ១", "", String(repeating: "ក", count: 40)])
        XCTAssertEqual(names[0], "ទំព័រ ២ · តារាង ១")
        XCTAssertEqual(names[1], "Invoice 202610 draft")
        XCTAssertEqual(names[2], "ទំព័រ ២ · តារាង ១ (2)")
        XCTAssertEqual(names[3], "Table 4")
        XCTAssertEqual(names[4].count, 31)
        XCTAssertEqual(XLSXWriter.columnName(0), "A")
        XCTAssertEqual(XLSXWriter.columnName(25), "Z")
        XCTAssertEqual(XLSXWriter.columnName(26), "AA")
        XCTAssertEqual(XLSXWriter.excelSerial(2026, 10, 30), 46325)
        XCTAssertEqual(XLSXWriter.excelSerial(1900, 3, 1), 61)
    }
}
