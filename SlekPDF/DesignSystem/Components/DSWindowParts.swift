import AppKit
import SwiftUI

/// Figma "Window Controls" (102:10): close / minimise / zoom in the fixed macOS system colours (deliberately not
/// themed). In-window panels can only close, so minimise and zoom are drawn but inert.
struct DSWindowControls: View {
    let onClose: () -> Void
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) { light(Color(red: 1, green: 0.373, blue: 0.341)) }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(CopyCatalog.shared.string(.menuClose, language))
            light(Color(red: 0.996, green: 0.737, blue: 0.180)).accessibilityHidden(true)
            light(Color(red: 0.157, green: 0.784, blue: 0.251)).accessibilityHidden(true)
        }
        .frame(width: 52, height: 12)
    }

    private func light(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
    }
}

/// The small macOS window the About, Developer, Release Notes, Report and Feedback panels share
/// (About Window 146:343 and its siblings): Background/Raised, Border/Subtle, Radius/Shell, Elevation/3,
/// a 40 pt title bar with window controls, 16 pt gaps and 24 pt bottom padding.
struct DSWindowPanel<Content: View>: View {
    var width: CGFloat = 520
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: DSSpace.s16) {
            HStack { DSWindowControls(onClose: onClose); Spacer() }
                .padding(.leading, DSSpace.s16)
                .frame(height: 40)
            content
        }
        .padding(.bottom, DSSpace.s24)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: DSRadius.shell).fill(DSColor.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.shell).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.shell))
        .dsElevation(.dialog)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// Figma "Key Cap" (139:6), Size=Regular: one key in help and Shortcut Rows. SF Pro (system) so ⌘ ⇧ ⌥ render
/// in both interface languages; thicker bottom border suggests a physical key.
struct DSKeyCap: View {
    enum Size { case small, regular }   // Figma: Small 20 × 18 (recorders), Regular 26 × 24

    let key: String
    var size: Size = .regular

    var body: some View {
        Text(key)
            .font(.system(size: size == .regular ? 12 : 10, weight: .medium))
            .foregroundColor(DSColor.textSecondary)
            .padding(.horizontal, size == .regular ? 6 : 4)
            .frame(minWidth: size == .regular ? 24 : 20, minHeight: size == .regular ? 24 : 18)
            .background(RoundedRectangle(cornerRadius: DSRadius.xs).fill(DSColor.backgroundSurface))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.xs).strokeBorder(DSColor.borderDefault, lineWidth: DSStroke.default))
            .overlay(alignment: .bottom) {
                // The extra 1 pt of the 2 pt bottom border.
                Rectangle().fill(DSColor.borderDefault).frame(height: 1).padding(.horizontal, DSRadius.xs)
            }
    }
}

/// Figma "Shortcut Row" (139:7): command name with its key caps, Border/Subtle underneath.
struct DSShortcutRow: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack(spacing: DSSpace.s12) {
            Text(title).dsText(.body).foregroundColor(DSColor.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DSSpace.s4) { ForEach(Array(keys.enumerated()), id: \.offset) { DSKeyCap(key: $0.element) } }
        }
        .padding(.vertical, DSSpace.s8)
        .overlay(alignment: .bottom) { DSDivider() }
        .accessibilityElement(children: .combine)
    }
}

/// Figma "Avatar" (275:94), Type=Initials, Tone=Brand: Accent/Default circle with Text/On Accent initials.
struct DSAvatar: View {
    enum Size: CGFloat { case xs = 24, sm = 32, md = 40, lg = 64, xl = 96 }

    let initials: String
    var size: Size = .xl

    var body: some View {
        Circle().fill(DSColor.accentDefault)
            .frame(width: size.rawValue, height: size.rawValue)
            .overlay(Text(initials).dsText(size == .xl ? .display : .label).foregroundColor(DSColor.textOnAccent))
            .accessibilityHidden(true)
    }
}

/// Figma "Dropdown" (94:74): label (Label Small, Text/Secondary) over a 32 pt field with the current value and a
/// chevron. Opens the native menu directly below, aligned to the field's left edge, with the current option checked.
struct DSDropdown<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @State private var anchor = DropdownAnchor.Box()
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            Text(label).dsText(.labelSmall).foregroundColor(DSColor.textSecondary)
            Button(action: openMenu) {
                HStack(spacing: DSSpace.s8) {
                    Text(options.first { $0.value == selection }?.title ?? "").dsText(.body).foregroundColor(DSColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    DSIcon.down.image(size: 16).foregroundColor(DSColor.textSecondary)
                }
                .padding(.leading, DSSpace.s12)
                .padding(.trailing, DSSpace.s8)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: DSRadius.sm).fill(DSColor.backgroundSurface))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.sm)
                    .strokeBorder(isHovered ? DSColor.borderStrong : DSColor.borderDefault, lineWidth: DSStroke.default))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .background(DropdownAnchor(box: anchor))
            .accessibilityLabel(label)
            .accessibilityValue(options.first { $0.value == selection }?.title ?? "")
        }
    }

    private func openMenu() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        for option in options {
            let item = MenuAction.item(option.title) { selection = option.value }
            item.state = option.value == selection ? .on : .off
            menu.addItem(item)
        }
        menu.minimumWidth = view.bounds.width
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}

/// Gives SwiftUI controls the NSView to pop a native menu from.
struct DropdownAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Target for a native menu item that runs a closure (kept alive as the item's `representedObject`).
final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func run() { handler() }

    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}

/// Figma "Text Field" (93:186), Type=Multiline: label, 96 pt field (radius 6) with placeholder, helper caption.
struct DSTextArea: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var helper: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            Text(label).dsText(.labelSmall).foregroundColor(DSColor.textSecondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .dsText(.body)
                    .foregroundColor(DSColor.textPrimary)
                    .focused($isFocused)
                    .padding(.horizontal, DSSpace.s8)
                    .padding(.vertical, DSSpace.s8)
                if text.isEmpty {
                    Text(placeholder).dsText(.body).foregroundColor(DSColor.textTertiary)
                        .padding(.horizontal, DSSpace.s12)
                        .padding(.vertical, DSSpace.s8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: DSRadius.sm).fill(DSColor.backgroundSurface))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.sm).strokeBorder(DSColor.borderDefault, lineWidth: DSStroke.default))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.shell)
                    .strokeBorder(DSColor.borderFocus, lineWidth: DSStroke.focus)
                    .padding(-4)
                    .opacity(isFocused ? 1 : 0)
            )
            if let helper {
                Text(helper).dsText(.caption).foregroundColor(DSColor.textTertiary)
            }
        }
    }
}
