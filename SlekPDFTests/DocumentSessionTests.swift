import XCTest
@testable import SlekPDF

@MainActor
final class DocumentSessionTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: DocumentSessionTests.self).url(forResource: name, withExtension: "pdf"))
    }

    func testOpensMultipagePDFInPDFKitAndPDFium() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-multipage"))
        XCTAssertNil(session.openError)
        XCTAssertEqual(session.pageCount, 3)
        XCTAssertNotNil(session.pdfiumID)
        XCTAssertEqual(session.fileName, "khmer-multipage.pdf")
        await session.close()
        XCTAssertNil(session.document)
        XCTAssertNil(session.pdfiumID)
    }

    func testDamagedFileReportsUnreadable() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-truncated"))
        XCTAssertEqual(session.openError, .unreadable(fileName: "khmer-truncated.pdf"))
        XCTAssertNil(session.document)
    }

    func testEncryptedFileAsksForPassword() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-encrypted"))
        XCTAssertEqual(session.openError, .needsPassword(fileName: "khmer-encrypted.pdf"))
        XCTAssertNil(session.document)
    }

    func testFailedOpenKeepsCurrentDocument() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-multipage"))
        await session.open(try fixture("khmer-truncated"))
        XCTAssertEqual(session.fileName, "khmer-multipage.pdf")
        XCTAssertNotNil(session.openError)
    }

    func testKhmerDigitsAndTemplates() {
        XCTAssertEqual(AppLanguage.km.number(1250), "១២៥០")
        XCTAssertEqual(AppLanguage.en.number(1250), "1250")
        XCTAssertEqual(CopyCatalog(bundle: Bundle(for: AppState.self)).format(.fmtPageNOfMStatus, .km, 2, 3),
                       "ទំព័រ ២ នៃ ៣ · ឯកសារដើមត្រូវបានរក្សា · ដំណើរការនៅលើម៉ាស៊ីន")
    }
}

@MainActor
final class RecentDocumentsTests: XCTestCase {
    func testAddsMostRecentFirstWithoutDuplicatesAndResolves() throws {
        let bundle = Bundle(for: RecentDocumentsTests.self)
        let recents = RecentDocuments(defaults: UserDefaults(suiteName: "recents-\(UUID())")!)
        let a = try XCTUnwrap(bundle.url(forResource: "khmer-coretext", withExtension: "pdf"))
        let b = try XCTUnwrap(bundle.url(forResource: "khmer-multipage", withExtension: "pdf"))
        recents.add(a); recents.add(b); recents.add(a)
        XCTAssertEqual(recents.entries.map(\.name), ["khmer-coretext.pdf", "khmer-multipage.pdf"])
        XCTAssertEqual(recents.resolve(recents.entries[0])?.lastPathComponent, "khmer-coretext.pdf")
    }

    func testRecentDateFormatsMatchPrototype() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 16, minute: 40))!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        let older = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
        XCTAssertEqual(RecentDateFormatter.string(yesterday, language: .km, now: now, calendar: calendar), "ម្សិលមិញ ១៦:៤០")
        XCTAssertEqual(RecentDateFormatter.string(yesterday, language: .en, now: now, calendar: calendar), "Yesterday 16:40")
        XCTAssertEqual(RecentDateFormatter.string(monday, language: .km, now: now, calendar: calendar), "ថ្ងៃច័ន្ទ")
        XCTAssertEqual(RecentDateFormatter.string(monday, language: .en, now: now, calendar: calendar), "Monday")
        XCTAssertEqual(RecentDateFormatter.string(older, language: .km, now: now, calendar: calendar), "១២ តុលា")
        XCTAssertEqual(RecentDateFormatter.string(older, language: .en, now: now, calendar: calendar), "12 Oct")
    }
}
