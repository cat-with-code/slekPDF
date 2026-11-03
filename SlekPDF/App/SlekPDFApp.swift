import SwiftUI

@main
struct SlekPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
                .onAppear {
                    appState.applyAppearance()
                    MainMenuLocalizer.shared.start(appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: ChromeMetrics.defaultWindowSize.width, height: ChromeMetrics.defaultWindowSize.height)
        .commands { AppCommands(appState: appState, recents: recents) }
    }
}

/// Receives files opened from Finder; windows pick them up from `ExternalOpenRequests`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpenRequests.shared.add(urls.filter { $0.pathExtension.lowercased() == "pdf" })
    }
}

@MainActor
final class ExternalOpenRequests: ObservableObject {
    static let shared = ExternalOpenRequests()
    @Published private(set) var pending: [URL] = []

    func add(_ urls: [URL]) { pending += urls }

    /// The next file to open; the first window that takes it opens it.
    func take() -> URL? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}
