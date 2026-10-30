import CoreText
import Foundation

/// Registers the bundled, OFL-licensed fonts (Noto Sans Khmer, Inter) for this process,
/// so the app never depends on fonts installed on the user's Mac.
enum FontRegistry {
    static let bundledPostScriptNames = [
        "NotoSansKhmer-Regular", "NotoSansKhmer-Medium", "NotoSansKhmer-SemiBold", "NotoSansKhmer-Bold",
        "Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold",
    ]

    private static var didRegister = false

    static func registerBundledFonts(bundle: Bundle = .main) {
        guard !didRegister else { return }
        didRegister = true
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already-registered is harmless (e.g. tests hosted in the app); anything else is a packaging bug.
                let cfError = error?.takeRetainedValue()
                let code = cfError.map { CFErrorGetCode($0) } ?? 0
                assert(code == CTFontManagerError.alreadyRegistered.rawValue, "Failed to register \(url.lastPathComponent): \(String(describing: cfError))")
            }
        }
    }
}
