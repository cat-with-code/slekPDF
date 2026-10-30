import AppKit
import SwiftUI
import XCTest
@testable import SlekPDF

/// Renders the main window at 1280×900 in Khmer/English × Light/Dark for side-by-side comparison
/// with the Figma prototype (KM · 01 Read, 164:6246). Runs only when SNAPSHOT_DIR is set; the app sandbox
/// confines writes to the container, so PNGs land in
///   ~/Library/Containers/com.example.SlekPDF/Data/tmp/shell-snapshots/
/// Run: Tools/render_snapshots.sh
@MainActor
final class ShellSnapshotTests: XCTestCase {
    func testRenderShellVariants() throws {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil else {
            throw XCTSkip("Set SNAPSHOT_DIR to write snapshots")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shell-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FontRegistry.registerBundledFonts()
        let size = ChromeMetrics.defaultWindowSize
        for language in AppLanguage.allCases {
            for (appearanceName, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                let state = AppState(defaults: UserDefaults(suiteName: "snapshot-\(UUID())")!)
                state.language = language
                let root = MainWindowView()
                    .environmentObject(state)
                    .environment(\.appLanguage, language)
                    .frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: root)
                host.frame = CGRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearanceName)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))

                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("shell-\(language.rawValue)-\(label).png"))
            }
        }

        // Icon contact sheet via ImageRenderer (test-only, macOS 13+). ImageRenderer does not draw
        // macOS buttons, so it cannot be used for the shell itself.
        if #available(macOS 13, *) {
            try writeRender(IconContactSheet(), to: dir.appendingPathComponent("icons.png"))
        }
    }

    @available(macOS 13, *)
    private func writeRender(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

/// Every Figma icon at 24pt, tinted with Text/Primary and Accent, to catch exports that turn into solid shapes.
private struct IconContactSheet: View {
    var body: some View {
        let columns = 10
        let icons = DSIcon.allCases
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<(icons.count + columns - 1) / columns, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(icons[(row * columns)..<min(icons.count, (row + 1) * columns)], id: \.self) { icon in
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                icon.image(size: 24).foregroundColor(DSColor.textPrimary)
                                icon.image(size: 24).foregroundColor(DSColor.accentDefault)
                            }
                            Text(icon.rawValue).font(.system(size: 8)).lineLimit(1)
                        }
                        .frame(width: 90)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white)
    }
}
