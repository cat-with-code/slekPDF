import AppKit
import XCTest
@testable import SlekPDF

@MainActor
final class DesignSystemTests: XCTestCase {
    override func setUp() {
        FontRegistry.registerBundledFonts()
    }

    private func hex(_ color: NSColor, appearance: NSAppearance.Name) -> String {
        var resolved = color
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)!
        }
        let r = Int((resolved.redComponent * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    func testSemanticColorsResolveFigmaAliasesPerAppearance() {
        // Values checked against the Figma Color collection (Light/Dark).
        let window = NSColor(name: "Background/Window", light: 0xEDEDEDFF, dark: 0x252528FF)
        XCTAssertEqual(hex(window, appearance: .aqua), "#ededed")
        XCTAssertEqual(hex(window, appearance: .darkAqua), "#252528")
        XCTAssertEqual(hex(NSColor(DSColor.accentDefault), appearance: .aqua), "#3a1ef1")
        XCTAssertEqual(hex(NSColor(DSColor.textPrimary), appearance: .darkAqua), "#ededed")
    }

    func testBundledFontsAreRegistered() {
        for name in FontRegistry.bundledPostScriptNames {
            XCTAssertNotNil(NSFont(name: name, size: 13), "\(name) not available")
        }
    }

    func testEveryFigmaIconIsInTheAssetCatalog() {
        let bundle = Bundle(for: AppState.self)
        for icon in DSIcon.allCases {
            XCTAssertNotNil(bundle.image(forResource: "Icons/\(icon.rawValue)"), "Missing asset for \(icon.rawValue)")
        }
    }

    func testEveryTextStyleResolvesInBothLanguages() {
        for style in DSTextStyle.allCases {
            for language in AppLanguage.allCases {
                let spec = style.spec(for: language)
                XCTAssertNotNil(NSFont(name: spec.postScriptName, size: spec.size), "\(style) \(language)")
            }
        }
    }

    /// Records how far each Figma line height is from the font's natural height.
    /// Negative values mean SwiftUI keeps the taller natural height (no Khmer clipping) and the row grows.
    func testLineHeightGapIsSmall() {
        var report: [String] = []
        for style in DSTextStyle.allCases {
            for language in AppLanguage.allCases {
                let spec = style.spec(for: language)
                report.append("\(style)/\(language): figma \(spec.lineHeight) natural \(spec.naturalLineHeight) extra \(spec.extraLeading)")
                XCTAssertGreaterThan(spec.extraLeading, -6, "\(style)/\(language) natural line is much taller than Figma")
            }
        }
        add(XCTAttachment(string: report.joined(separator: "\n")))
        print(report.joined(separator: "\n"))
    }
}

@MainActor
final class CopyCatalogTests: XCTestCase {
    func testEveryKeyHasKhmerAndEnglish() {
        let catalog = CopyCatalog(bundle: Bundle(for: AppState.self))
        for key in CopyKey.allCases {
            let km = catalog.string(key, .km)
            let en = catalog.string(key, .en)
            XCTAssertFalse(km.isEmpty, key.rawValue)
            XCTAssertFalse(en.isEmpty, key.rawValue)
            XCTAssertNil(en.range(of: "[\\u1780-\\u17FF]", options: .regularExpression), "Khmer glyphs in English value of \(key.rawValue)")
        }
    }

    func testCatalogHasNoUnusedKeysWithoutEnumCase() {
        let catalog = CopyCatalog(bundle: Bundle(for: AppState.self))
        XCTAssertEqual(Set(catalog.keys), Set(CopyKey.allCases.map(\.rawValue)), "Run Tools/generate_tokens.py after editing copy.json")
    }
}
