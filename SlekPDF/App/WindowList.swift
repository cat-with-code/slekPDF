import AppKit

/// Open document windows for Window ▸ (window list), kept current as windows open, close and change focus.
@MainActor
final class WindowList: ObservableObject {
    struct Item: Identifiable {
        let id: ObjectIdentifier
        let title: String
        let isKey: Bool
        let window: NSWindow
    }

    @Published private(set) var items: [Item] = []
    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didUpdateNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        let fresh = NSApp.windows
            .filter { $0.isVisible && $0.canBecomeMain && !$0.title.isEmpty }
            .map { Item(id: ObjectIdentifier($0), title: $0.title, isKey: $0.isKeyWindow, window: $0) }
        if fresh.map(\.id) != items.map(\.id) || fresh.map(\.title) != items.map(\.title) || fresh.map(\.isKey) != items.map(\.isKey) {
            items = fresh
        }
    }
}
