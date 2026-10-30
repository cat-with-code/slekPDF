import SwiftUI

@main
struct SlekPDFApp: App {
    @StateObject private var appState = AppState()

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appState)
                .environment(\.appLanguage, appState.language)
                .frame(
                    minWidth: ChromeMetrics.minimumWindowSize.width,
                    idealWidth: ChromeMetrics.defaultWindowSize.width,
                    minHeight: ChromeMetrics.minimumWindowSize.height,
                    idealHeight: ChromeMetrics.defaultWindowSize.height
                )
                .background(WindowConfigurator())
                .onAppear { appState.applyAppearance() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(appState: appState) }
    }
}

/// Sets the initial 1280×900 size once; `defaultSize` / `windowResizability` need macOS 13.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.minSize = ChromeMetrics.minimumWindowSize
            if !window.setFrameUsingName("SlekPDFMainWindow") {
                window.setContentSize(ChromeMetrics.defaultWindowSize)
                window.center()
            }
            window.setFrameAutosaveName("SlekPDFMainWindow")
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
