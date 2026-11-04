import AppKit
import SwiftUI

/// Asks 16 Save changes before closing? when a window with unsaved page changes is closed. SwiftUI owns the
/// window's delegate, so this installs a proxy that answers `windowShouldClose` and forwards everything else.
struct WindowCloseGuard: NSViewRepresentable {
    let session: DocumentSession

    func makeNSView(context: Context) -> GuardView { GuardView(session: session) }
    func updateNSView(_ view: GuardView, context: Context) {}

    final class GuardView: NSView {
        private let session: DocumentSession
        private var proxy: CloseGuardDelegate?

        init(session: DocumentSession) {
            self.session = session
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, proxy == nil else { return }
            session.window = window
            let proxy = CloseGuardDelegate(session: session, original: window.delegate)
            window.delegate = proxy
            self.proxy = proxy
            // Full screen hides the window controls; the title bar drops their space.
            session.isFullScreen = window.styleMask.contains(.fullScreen)
            for (name, value) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false)] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak session] _ in
                    MainActor.assumeIsolated { session?.isFullScreen = value }
                }
            }
        }
    }
}

final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    private weak var session: DocumentSession?
    /// Read from the Objective-C forwarding machinery (nonisolated); only set once, on the main thread.
    nonisolated(unsafe) private weak var original: NSWindowDelegate?

    init(session: DocumentSession, original: NSWindowDelegate?) {
        self.session = session
        self.original = original
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let session, session.hasUnsavedChanges, !session.discardChanges {
            if session.organizeDialog == nil, session.panel == nil, session.openError == nil {
                session.organizeDialog = .closeConfirm
            }
            return false
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }
}
