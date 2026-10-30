import PDFKit
import XCTest
@testable import SlekPDF

@MainActor
final class SearchTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: SearchTests.self).url(forResource: name, withExtension: "pdf"))
    }

    func testSearchFindsKhmerAcrossPagesAndCycles() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-multipage"))
        session.searchQuery = "សាលារៀន"
        await session.waitForSearch()
        XCTAssertEqual(session.searchResults.count, 5, "\(session.searchResults.map(\.page))")
        XCTAssertEqual(session.searchPageCount, 3)
        XCTAssertEqual(session.currentMatchIndex, 0)
        XCTAssertTrue(session.searchResults.allSatisfy { $0.match == "សាលារៀន" && !$0.rects.isEmpty })
        session.previousMatch()
        XCTAssertEqual(session.currentMatchIndex, 4, "previous from the first wraps to the last")
        session.nextMatch()
        XCTAssertEqual(session.currentMatchIndex, 0)
        XCTAssertEqual(CopyCatalog.shared.resultsSummary(results: 5, pages: 3, .en), "5 results on 3 pages")
        XCTAssertEqual(CopyCatalog.shared.resultsSummary(results: 1, pages: 1, .en), "1 result on 1 page")
        XCTAssertEqual(CopyCatalog.shared.resultsSummary(results: 5, pages: 3, .km), "លទ្ធផល ៥ នៅលើទំព័រ ៣")
    }

    func testNoResultsAndClearing() async throws {
        let session = DocumentSession()
        await session.open(try fixture("khmer-multipage"))
        session.searchQuery = "មិនមានក្នុងឯកសារ"
        await session.waitForSearch()
        XCTAssertTrue(session.searchResults.isEmpty)
        XCTAssertNil(session.currentMatchIndex)
        session.clearSearch()
        XCTAssertFalse(session.isSearchActive)
    }

    /// PDFium match rectangles are in PDF user space, which PDFKit's PDFPage also uses; rotation and an
    /// offset crop box must not change them, and they must sit inside the visible (crop) box.
    func testMatchRectanglesShareUserSpaceAcrossRotationAndCrop() async throws {
        var rects: [String: CGRect] = [:]
        for name in ["khmer-multipage", "khmer-rotated", "khmer-cropped"] {
            let session = DocumentSession()
            await session.open(try fixture(name))
            session.searchQuery = "ភូមិថ្មី"
            await session.waitForSearch()
            let first = try XCTUnwrap(session.searchResults.first { $0.page == 0 }, name)
            let rect = first.rects.dropFirst().reduce(first.rects[0]) { $0.union($1) }
            rects[name] = rect
            let page = try XCTUnwrap(session.document?.page(at: 0))
            XCTAssertTrue(page.bounds(for: .cropBox).contains(rect), "\(name): \(rect) outside \(page.bounds(for: .cropBox))")
        }
        let base = try XCTUnwrap(rects["khmer-multipage"])
        for name in ["khmer-rotated", "khmer-cropped"] {
            let other = try XCTUnwrap(rects[name])
            XCTAssertEqual(other.minX, base.minX, accuracy: 0.5, name)
            XCTAssertEqual(other.minY, base.minY, accuracy: 0.5, name)
            XCTAssertEqual(other.width, base.width, accuracy: 0.5, name)
        }
    }
}
