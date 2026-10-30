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
