import SwiftUI

/// Native menu bar. The Figma "Desktop Menu Bar" (296:1555) is the reference for items and order;
/// only the language/appearance items exist so far. See docs/PROTOTYPE-GAPS.md (menu bar).
struct AppCommands: Commands {
    @ObservedObject var appState: AppState
    @FocusedObject private var session: DocumentSession?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(CopyCatalog.shared.string(.openPDF, appState.language) + "…") { session?.isImporterPresented = true }
                .keyboardShortcut("o")
                .disabled(session == nil)
        }
        CommandGroup(after: .toolbar) {
            Picker("Interface Language", selection: $appState.language) {
                Text("ខ្មែរ").tag(AppLanguage.km)
                Text("English").tag(AppLanguage.en)
            }
            Picker("Appearance", selection: $appState.appearance) {
                Text("System").tag(AppearancePreference.system)
                Text("Light").tag(AppearancePreference.light)
                Text("Dark").tag(AppearancePreference.dark)
            }
        }
    }
}
