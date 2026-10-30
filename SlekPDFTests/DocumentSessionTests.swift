import SwiftUI
import AppKit
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
        XCTAssertEqual(recents.url(for: recents.entries[0])?.lastPathComponent, "khmer-coretext.pdf")
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

@MainActor
final class PasswordFlowTests: XCTestCase {
    func testWrongThenRightPasswordOpensInPDFKitAndPDFium() async throws {
        let url = try XCTUnwrap(Bundle(for: PasswordFlowTests.self).url(forResource: "khmer-encrypted", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        XCTAssertTrue(session.isModalPresented)
        await session.unlock(with: "wrong")
        XCTAssertTrue(session.passwordRejected)
        XCTAssertNil(session.document)
        await session.unlock(with: "user")
        XCTAssertFalse(session.isModalPresented)
        XCTAssertEqual(session.pageCount, 3)
        XCTAssertNotNil(session.pdfiumID)
    }

    func testCancelClearsPendingFile() async throws {
        let url = try XCTUnwrap(Bundle(for: PasswordFlowTests.self).url(forResource: "khmer-encrypted", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        session.dismissOpenError()
        XCTAssertFalse(session.isModalPresented)
        await session.unlock(with: "user")
        XCTAssertNil(session.document, "unlock after cancel must not open anything")
    }
}

@MainActor
final class ExternalOpenTests: XCTestCase {
    func testFinderOpenIsQueuedOnceForTheFirstWindow() throws {
        let pdf = try XCTUnwrap(Bundle(for: ExternalOpenTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        AppDelegate().application(NSApplication.shared, open: [pdf, URL(fileURLWithPath: "/tmp/notes.txt")])
        XCTAssertEqual(ExternalOpenRequests.shared.pending, [pdf], "only PDFs are queued")
        XCTAssertEqual(ExternalOpenRequests.shared.take(), pdf)
        XCTAssertNil(ExternalOpenRequests.shared.take(), "a second window must not open it again")
    }
}

@MainActor
final class ZoomStabilityTests: XCTestCase {
    /// A zoom made inside the PDF view (pinch, ⌘+) leaves Fit page, and toggling panels keeps that zoom.
    func testUserZoomSurvivesPanelToggles() async throws {
        let url = try XCTUnwrap(Bundle(for: ZoomStabilityTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        let session = DocumentSession()
        await session.open(url)
        let canvas = PDFCanvasView(session: session)
        let host = NSHostingView(rootView: canvas.frame(width: 800, height: 700))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500000000)
        let view = try XCTUnwrap(session.pdfView)
        XCTAssertTrue(session.isFitPage)

        view.scaleFactor = 2.0   // as a pinch would
        try await Task.sleep(nanoseconds: 200000000)
        XCTAssertFalse(session.isFitPage)

        // A panel toggle resizes the PDF view but not the window.
        view.setFrameSize(NSSize(width: view.frame.width - 120, height: view.frame.height))
        try await Task.sleep(nanoseconds: 200000000)
        view.setFrameSize(NSSize(width: view.frame.width + 120, height: view.frame.height))
        try await Task.sleep(nanoseconds: 200000000)
        XCTAssertEqual(view.scaleFactor, 2.0, accuracy: 0.001)

        session.fitPage()
        XCTAssertTrue(session.isFitPage)
    }
}
