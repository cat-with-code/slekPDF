import AppKit
import SwiftUI

/// Figma "Tooltip" (91:30) bubble: Background/Raised, Border/Subtle, radius 6, Elevation/2; Caption text with
/// the shortcut in Text/Tertiary.
struct DSTooltipBubble: View {
    let text: String
    var shortcut: String?
    let language: AppLanguage

    var body: some View {
        HStack(spacing: DSSpace.s8) {
            Text(text).foregroundColor(DSColor.textPrimary)
            if let shortcut { Text(shortcut).foregroundColor(DSColor.textTertiary) }
        }
        .dsText(.caption)
        .environment(\.appLanguage, language)
        .lineLimit(1)
        .padding(.horizontal, DSSpace.s8)
        .padding(.vertical, DSSpace.s4)
        .background(RoundedRectangle(cornerRadius: DSRadius.sm).fill(DSColor.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.sm).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .dsElevation(.popover)
        .padding(16)  // room for the shadow inside the panel
        .fixedSize()
    }
}

extension View {
    /// Names a control and its shortcut on hover, as the Figma Tooltip (91:30), below the control after 0.6 s
    /// (Icon Button 86:511). Required for every icon button. Replaces `.help()`, whose system tooltip does not
    /// match the design; the text is also the control's accessibility label (icon buttons have no other).
    func dsTooltip(_ key: CopyKey, shortcut: String? = nil) -> some View {
        modifier(DSTooltipModifier(label: .key(key), shortcut: shortcut))
    }

    func dsTooltip(text: String, shortcut: String? = nil) -> some View {
        modifier(DSTooltipModifier(label: .text(text), shortcut: shortcut))
    }
}

private struct DSTooltipModifier: ViewModifier {
    enum Label {
        case key(CopyKey)
        case text(String)
    }

    let label: Label
    let shortcut: String?
    @Environment(\.appLanguage) private var language

    func body(content: Content) -> some View {
        let text: String = switch label {
        case let .key(key): CopyCatalog.shared.string(key, language)
        case let .text(text): text
        }
        content
            .background(TooltipAnchor(text: text, shortcut: shortcut, language: language))
            .accessibilityLabel(text)
    }
}

/// An invisible AppKit view that tracks the pointer over the control and shows the bubble in a borderless
/// child panel, so it is never clipped by or hidden under neighbouring SwiftUI views.
private struct TooltipAnchor: NSViewRepresentable {
    let text: String
    let shortcut: String?
    let language: AppLanguage

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.bubble = DSTooltipBubble(text: text, shortcut: shortcut, language: language)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.hide() }

    final class AnchorView: NSView {
        var bubble: DSTooltipBubble?
        private var timer: Timer?
        private var panel: NSPanel?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.show() }
            }
        }

        override func mouseExited(with event: NSEvent) { hide() }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { hide() }
            super.viewWillMove(toWindow: newWindow)
        }

        func hide() {
            timer?.invalidate()
            timer = nil
            if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
            panel = nil
        }

        private func show() {
            guard let window, let bubble, panel == nil else { return }
            let host = NSHostingView(rootView: bubble)
            host.frame.size = host.fittingSize
            let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.appearance = window.effectiveAppearance
            panel.contentView = host
            // Bottom placement, centred under the control, 4 pt gap (16 pt is the shadow margin in the bubble).
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            var origin = CGPoint(x: anchor.midX - host.frame.width / 2, y: anchor.minY - 4 - host.frame.height + 16)
            if let screen = window.screen?.visibleFrame {
                origin.x = min(max(origin.x, screen.minX), screen.maxX - host.frame.width)
            }
            panel.setFrameOrigin(origin)
            window.addChildWindow(panel, ordered: .above)
            self.panel = panel
        }
    }
}
