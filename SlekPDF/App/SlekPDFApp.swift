import SwiftUI

@main
struct SlekPDFApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var recents = RecentDocuments()

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            DocumentWindow()
                .environmentObject(appState)
                .environmentObject(recents)
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
