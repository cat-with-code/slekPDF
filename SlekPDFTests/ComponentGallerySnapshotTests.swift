import AppKit
import SwiftUI
import XCTest
@testable import SlekPDF

/// Renders design-system components the way the Figma component pages show their variants, in Khmer/English ×
/// Light/Dark, for side-by-side comparison. Runs only when SNAPSHOT_DIR is set (Tools/render_snapshots.sh);
/// PNGs land in ~/Library/Containers/com.example.SlekPDF/Data/tmp/shell-snapshots/components-*.png.
@MainActor
final class ComponentGallerySnapshotTests: XCTestCase {
    func testRenderComponentGallery() throws {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil else {
            throw XCTSkip("Set SNAPSHOT_DIR to write snapshots")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FontRegistry.registerBundledFonts()
        for language in AppLanguage.allCases {
            for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let view = FeedbackGallery()
                    .environment(\.appLanguage, language)
                try render(view, size: CGSize(width: 1100, height: 520), appearance: appearance,
                           to: dir.appendingPathComponent("components-feedback-\(language.rawValue)-\(label).png"))
                try render(PrintAccessoryView(options: PrintOptions()).environment(\.appLanguage, language).background(DSColor.backgroundWindow),
                           size: CGSize(width: 420, height: 300), appearance: appearance,
                           to: dir.appendingPathComponent("print-accessory-\(language.rawValue)-\(label).png"))
                try render(ControlsGallery().environment(\.appLanguage, language), size: CGSize(width: 900, height: 300), appearance: appearance,
                           to: dir.appendingPathComponent("components-controls-\(language.rawValue)-\(label).png"))
            }
        }
    }

    /// Prototype D-27 … D-34 (App menu & Help) as in-window panels over the start screen, 1280×900.
    func testRenderAppPanels() throws {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil else {
            throw XCTSkip("Set SNAPSHOT_DIR to write snapshots")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FontRegistry.registerBundledFonts()
        let recents = RecentDocuments(defaults: UserDefaults(suiteName: "panel-recents-\(UUID())")!)
        let panels: [(String, AppPanel)] = [("D27-about", .about(.about)), ("D28-shortcuts", .about(.shortcuts)), ("D29-licenses", .about(.licenses)),
                                            ("D29-privacy", .about(.privacy)), ("D30-help", .help), ("D31-developer", .developer),
                                            ("D32-release-notes", .releaseNotes), ("D33-report", .reportProblem), ("D34-feedback", .feedback),
                                            ("D10-preferences", .preferences(.general)), ("D10k-shortcuts", .preferences(.shortcuts))]
        for (name, panel) in panels {
            for language in AppLanguage.allCases {
                for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] where label == "light" || name == "D27-about" {
                    let state = AppState(defaults: UserDefaults(suiteName: "panel-\(UUID())")!)
                    state.language = language
                    let session = DocumentSession()
                    session.panel = panel
                    let view = MainWindowView()
                        .environmentObject(state).environmentObject(session).environmentObject(recents).environmentObject(ToastCenter())
                        .environment(\.appLanguage, language)
                    try render(view, size: ChromeMetrics.defaultWindowSize, appearance: appearance,
                               to: dir.appendingPathComponent("panel-\(name)-\(language.rawValue)-\(label).png"))
                }
            }
        }
    }

    /// Prototype 02 Organize pages, 20 Delete pages? and 42 Save work with a real 3-page PDF, 1280×900.
    func testRenderOrganize() async throws {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil else {
            throw XCTSkip("Set SNAPSHOT_DIR to write snapshots")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FontRegistry.registerBundledFonts()
        let url = try XCTUnwrap(Bundle(for: ComponentGallerySnapshotTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        for (name, dialog) in [("02-organize", nil), ("20-delete", DocumentSession.OrganizeDialog.deletePages), ("42-save-work", .saveWork),
                               ("19-merge", .merge), ("21-split", .split), ("16-close", .closeConfirm)] {
            for language in AppLanguage.allCases {
                let session = DocumentSession()
                await session.open(url)
                session.workspace = .organizePages
                if dialog == .deletePages { session.selectedPageIDs = Set(session.pages.dropFirst().map(\.id)) }
                session.organizeDialog = dialog
                let state = AppState(defaults: UserDefaults(suiteName: "organize-\(UUID())")!)
                state.language = language
                let view = MainWindowView()
                    .environmentObject(state).environmentObject(session)
                    .environmentObject(RecentDocuments(defaults: UserDefaults(suiteName: "organize-recents-\(UUID())")!))
                    .environmentObject(session.toasts)
                    .environment(\.appLanguage, language)
                try render(view, size: ChromeMetrics.defaultWindowSize, appearance: .aqua,
                           to: dir.appendingPathComponent("\(name)-\(language.rawValue)-light.png"))
                await session.close()
            }
        }
    }

    /// Prototype 03 Annotate: a highlight, comments (selected, default, resolved with a reply) and a new comment
    /// being written, in Khmer and English.
    func testRenderAnnotate() async throws {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil else {
            throw XCTSkip("Set SNAPSHOT_DIR to write snapshots")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FontRegistry.registerBundledFonts()
        let url = try XCTUnwrap(Bundle(for: ComponentGallerySnapshotTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        for (name, mode) in [("03-annotate", 0), ("03-annotate-new-comment", 1), ("03-annotate-text-box", 2)] {
            for language in AppLanguage.allCases {
                let session = DocumentSession()
                await session.open(url)
                session.workspace = .annotate
                let page = try XCTUnwrap(session.document?.page(at: 0))
                let box = page.bounds(for: .mediaBox)
                let line = try XCTUnwrap(page.selection(for: CGRect(x: box.minX, y: box.maxY - 160, width: box.width, height: 60)))
                await session.highlight(line)
                let highlight = try XCTUnwrap(session.annotations[session.pages[0].id]?.first)
                session.beginComment(onHighlight: highlight.id)
                session.commentDraft?.text = "សូមពិនិត្យអក្ខរាវិរុទ្ធនៃឈ្មោះខ្មែរនេះ។"
                session.saveCommentDraft()
                let first = try XCTUnwrap(session.selectedAnnotationID)
                session.beginComment(onPageAt: 1, at: CGPoint(x: 80, y: 400))
                session.commentDraft?.text = "Check the spelling of this Khmer name."
                session.saveCommentDraft()
                let second = try XCTUnwrap(session.selectedAnnotationID)
                session.addReply(to: second, text: "បាទ កែរួចហើយ។")
                session.setResolved(second, true)
                session.selectAnnotation(first)
                if mode == 1 {
                    session.annotateTool = .comment
                    session.beginComment(onPageAt: 0, at: CGPoint(x: 300, y: 300))
                }
                if mode == 2 {
                    session.beginTextBox(onPageAt: 0, at: CGPoint(x: box.minX + 72, y: box.maxY - 340))
                    session.typeInTextBox("ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ")
                    session.changeTextBoxStyle { $0.bold = true }
                    session.commitTextEditing()
                }
                let state = AppState(defaults: UserDefaults(suiteName: "annotate-\(UUID())")!)
                state.language = language
                let view = MainWindowView()
                    .environmentObject(state).environmentObject(session)
                    .environmentObject(RecentDocuments(defaults: UserDefaults(suiteName: "annotate-recents-\(UUID())")!))
                    .environmentObject(session.toasts)
                    .environment(\.appLanguage, language)
                try render(view, size: ChromeMetrics.defaultWindowSize, appearance: .aqua,
                           to: dir.appendingPathComponent("\(name)-\(language.rawValue)-light.png"))
                await session.close()
            }
        }
    }

    /// Prototype 04 settings, 12 Recognizing text…, 39 Recognize these pages again?, 41 invalid page range.
    func testRenderOCR() async throws {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil else {
            throw XCTSkip("Set SNAPSHOT_DIR to write snapshots")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FontRegistry.registerBundledFonts()
        let url = try XCTUnwrap(Bundle(for: ComponentGallerySnapshotTests.self).url(forResource: "khmer-multipage", withExtension: "pdf"))
        for name in ["05-export-word", "08-export-pdf", "09-export-text",
                     "04-ocr-review", "04-ocr-all-reviewed", "04-ocr-settings", "12-recognizing", "39-recognize-again", "41-invalid-range"] {
            for language in AppLanguage.allCases {
                let session = DocumentSession()
                await session.open(url)
                session.workspace = .khmerOCR
                session.ocrSettings.scope = .custom
                session.ocrSettings.customRange = name == "41-invalid-range" ? "1–9" : "1–3"
                switch name {
                case "05-export-word", "08-export-pdf", "09-export-text":
                    session.workspace = .export
                    session.exportSettings.format = name == "05-export-word" ? .word : name == "08-export-pdf" ? .searchablePDF : .plainText
                    session.exportSettings.fileName = session.defaultExportFileName(for: session.exportSettings.format)
                case "12-recognizing":
                    session.ocrJob = OCRJob(pages: [0, 1, 2], finished: 1, currentNumber: 2)
                    session.organizeDialog = .recognizing
                case "04-ocr-review", "04-ocr-all-reviewed":
                    let box = try XCTUnwrap(session.document?.page(at: 0)?.bounds(for: .mediaBox))
                    let lines = [("សាលារៀនបឋមសិក្សា ភូមិថ្មី", 52.0), ("ឯកសារនេះត្រូវបានពិនិត្យ", 70.0), ("Khmer / English", 95.0), ("ថ្ងៃទី ៣ ខែវិច្ឆិកា", 61.0)]
                    session.setOCR(OCRPage(lines: lines.enumerated().map { index, item in
                        OCRLine(bounds: CGRect(x: box.minX + 60, y: box.maxY - 90 - CGFloat(index) * 40, width: 320, height: 22),
                                text: item.0, confidence: item.1)
                    }, languages: "khm+eng", date: Date()), for: session.pages[0].id)
                    if name == "04-ocr-all-reviewed" {
                        while let item = session.currentOCRItem, !session.allOCRItemsReviewed {
                            session.markOCRItemReviewed(item, text: session.ocrLine(item)?.text ?? "")
                        }
                    } else if let first = session.currentOCRItem {
                        session.markOCRItemReviewed(first, text: "សាលារៀនបឋមសិក្សា ភូមិថ្មី")
                        session.selectOCRItem(first)
                    }
                case "39-recognize-again":
                    session.setOCR(OCRPage(lines: [OCRLine(bounds: .zero, text: "ក", confidence: 50, reviewed: true)], languages: "khm", date: Date()),
                                   for: session.pages[1].id)
                    session.requestRecognition(language)
                default: break
                }
                let state = AppState(defaults: UserDefaults(suiteName: "ocr-\(UUID())")!)
                state.language = language
                let view = MainWindowView()
                    .environmentObject(state).environmentObject(session)
                    .environmentObject(RecentDocuments(defaults: UserDefaults(suiteName: "ocr-recents-\(UUID())")!))
                    .environmentObject(session.toasts)
                    .environment(\.appLanguage, language)
                try render(view, size: ChromeMetrics.defaultWindowSize, appearance: .aqua,
                           to: dir.appendingPathComponent("\(name)-\(language.rawValue)-light.png"))
                session.ocrJob = nil
                await session.close()
            }
        }
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// Figma Toast 143:68, Banner 141:101, Progress Bar 100:74 and Spinner 100:11 with their sample text.
private struct FeedbackGallery: View {
    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 26) {
                DSToast(tone: .default, message: "2 pages deleted", action: DSInlineAction(title: "Undo") {}, onClose: {})
                DSToast(tone: .success, message: "Export finished · Document.docx", action: DSInlineAction(title: "Show in Finder") {}, onClose: {})
                DSToast(tone: .error, message: "Couldn’t save — disk is full", action: DSInlineAction(title: "Details") {}, onClose: {})
                DSToast(tone: .progress, message: "Exporting · 40%", action: DSInlineAction(title: "Cancel") {}, onClose: {})
                HStack(spacing: 48) {
                    DSSpinner(size: .small)
                    DSSpinner(size: .regular)
                    DSSpinner(size: .large)
                }
            }
            .frame(width: 400, alignment: .leading)
            VStack(alignment: .leading, spacing: 16) {
                DSBanner(tone: .info, title: "This page is scanned", message: "Recognize text to search, select and copy it.",
                         action: DSInlineAction(title: "Recognize text") {}, onClose: {})
                DSBanner(tone: .warning, title: "Preview build", message: "Excel export has not passed validation yet. Check results before sharing.",
                         action: DSInlineAction(title: "Learn more") {}, onClose: {})
                DSBanner(tone: .neutral, title: "Flattened copy", message: "Added text in this file can no longer be edited. Open the saved work to edit.",
                         action: DSInlineAction(title: "Open saved work") {}, onClose: {})
            }
            .frame(width: 320)
            VStack(alignment: .leading, spacing: 24) {
                DSProgressBar(label: "Recognizing page 2 of 5", detail: "40% · about 1 minute left", state: .inProgress(0.4), onCancel: {})
                DSProgressBar(label: "Recognizing page 2 of 5", detail: "40% · about 1 minute left", state: .paused(0.4), onCancel: {})
                DSProgressBar(label: "Recognizing page 2 of 5", detail: "40% · about 1 minute left", state: .complete, onCancel: {})
                DSProgressBar(label: "Recognizing page 2 of 5", detail: "40% · about 1 minute left", state: .error(0.4), onCancel: {})
            }
            .frame(width: 280)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DSColor.backgroundWindow)
    }
}

/// Figma Switch 140:36, Badge 89:32, Tab 98:64 (Segmented) and Tooltip 91:30.
private struct ControlsGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 48) {
                DSSwitch(label: "Switch label", isOn: .constant(false))
                DSSwitch(label: "Switch label", isOn: .constant(true))
                DSSwitch(label: "Switch label", isOn: .constant(false)).disabled(true)
                DSSwitch(label: "Switch label", isOn: .constant(true)).disabled(true)
            }
            HStack(spacing: 16) {
                ForEach([DSBadge.Tone.neutral, .accent, .success, .warning, .danger], id: \.self) { DSBadge(label: "Badge", tone: $0) }
                ForEach([DSBadge.Tone.neutral, .accent, .success, .warning, .danger], id: \.self) { DSBadge(label: "Badge", tone: $0, style: .solid) }
            }
            HStack(spacing: 32) {
                DSSegmentedControl(selection: .constant(0), segments: [.init(value: 0, title: "Word preview"), .init(value: 1, title: "Excel preview")])
                DSTooltipBubble(text: "Open PDF", shortcut: "⌘O", language: .en)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DSColor.backgroundWindow)
    }
}
