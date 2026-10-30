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
                .onAppear { appState.applyAppearance() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: ChromeMetrics.defaultWindowSize.width, height: ChromeMetrics.defaultWindowSize.height)
        .commands { AppCommands(appState: appState) }
    }
}
