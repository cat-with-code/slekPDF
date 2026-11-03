import AppKit
import SwiftUI

/// Figma "Spinner" (100:11): indeterminate activity. Ring 11% of the size on Background/Pressed, an Accent arc
/// from 12 o'clock over 55% of the turn, rotating linearly once every 0.9 s (static with Reduce Motion).
struct DSSpinner: View {
    enum Size: CGFloat { case small = 16, regular = 24, large = 40 }

    var size: Size = .small
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTurning = false

    var body: some View {
        let width = size.rawValue * 0.11
        ZStack {
            Circle().stroke(DSColor.backgroundPressed, lineWidth: width)
            Circle()
                .trim(from: 0, to: 0.55)
                .stroke(DSColor.accentDefault, lineWidth: width)
                .rotationEffect(.degrees(-90))
        }
        .padding(width / 2)
        .frame(width: size.rawValue, height: size.rawValue)
        .rotationEffect(.degrees(isTurning ? 360 : 0))
        .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: isTurning)
        .onAppear { isTurning = true }
        .accessibilityElement()
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Figma "Progress Bar" (100:74): label + Cancel, a 6 pt track, and a detail line that says what is happening
/// (or, on error, what was kept). Indeterminate shows a 96 pt sliding segment.
struct DSProgressBar: View {
    enum State: Equatable {
        case inProgress(Double)
        case indeterminate
        case paused(Double)
        case complete
        case error(Double)
    }

    let label: String
    var detail: String?
    let state: State
    var onCancel: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var slide = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s6) {
            HStack(spacing: DSSpace.s8) {
                Text(label).dsText(.label).foregroundColor(DSColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onCancel {
                    DSIconButton(.close, size: 24, iconSize: 14, action: onCancel)
                }
            }
            track
            if let detail {
                Text(detail).dsText(.caption).foregroundColor(detailColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .indeterminate ? "" : "\(Int((fraction * 100).rounded())) %")
    }

    private var track: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DSColor.backgroundPressed)
                if state == .indeterminate {
                    Capsule().fill(DSColor.accentDefault)
                        .frame(width: 96)
                        .offset(x: slide ? proxy.size.width : -96)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: false), value: slide)
                        .onAppear { slide = true }
                } else {
                    Capsule().fill(fillColor).frame(width: proxy.size.width * fraction)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 6)
    }

    private var fraction: CGFloat {
        switch state {
        case let .inProgress(value), let .paused(value), let .error(value): CGFloat(min(max(value, 0), 1))
        case .complete: 1
        case .indeterminate: 0
        }
    }

    private var fillColor: Color {
        switch state {
        case .inProgress, .indeterminate: DSColor.accentDefault
        case .paused: DSColor.textTertiary
        case .complete: DSColor.statusSuccess
        case .error: DSColor.statusDanger
        }
    }

    private var detailColor: Color {
        switch state {
        case .complete: DSColor.statusSuccess
        case .error: DSColor.statusDanger
        default: DSColor.textSecondary
        }
    }
}

/// A text action inside a Toast or Banner (title already in the interface language).
struct DSInlineAction {
    let title: String
    let action: () -> Void
}

/// Figma "Toast" (143:68): a one-line pill (Background/Raised, Border/Subtle, Elevation/2) with an optional
/// accent text action and close. Presented by `ToastCenter`, bottom-centre, 24 pt above the status bar.
struct DSToast: View {
    enum Tone { case `default`, success, error, progress }

    let tone: Tone
    let message: String
    var action: DSInlineAction?
    var onClose: (() -> Void)?
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(spacing: DSSpace.s8) {
            switch tone {
            case .success: DSIcon.checkOne.image(size: 16).foregroundColor(DSColor.statusSuccess)
            case .error: DSIcon.attention.image(size: 16).foregroundColor(DSColor.statusDanger)
            case .progress: DSSpinner(size: .small)
            case .default: EmptyView()
            }
            Text(message).dsText(.body).foregroundColor(DSColor.textPrimary).lineLimit(1)
            if let action {
                Button(action: action.action) {
                    Text(action.title).dsText(.labelSmall).foregroundColor(DSColor.textAccent)
                        .padding(.horizontal, DSSpace.s12)
                        .frame(height: 24)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if let onClose {
                DSIconButton(.close, size: 24, iconSize: 14, action: onClose)
                    .dsTooltip(.menuClose)
            }
        }
        .padding(.leading, DSSpace.s16)
        .padding(.trailing, DSSpace.s6)
        .padding(.vertical, DSSpace.s6)
        .background(Capsule().fill(DSColor.backgroundRaised))
        .overlay(Capsule().strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .dsElevation(.popover)
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}

/// One window's toast. Auto-dismisses after about 5 s, but never while hovered, while Progress runs, or for an
/// Error (which stays until closed); every toast is announced to VoiceOver.
@MainActor
final class ToastCenter: ObservableObject {
    struct Toast: Identifiable {
        let id = UUID()
        let tone: DSToast.Tone
        let message: String
        var action: DSInlineAction?
    }

    @Published private(set) var current: Toast?
    var isHovered = false { didSet { if !isHovered { scheduleDismiss() } } }
    private var dismissTask: Task<Void, Never>?

    func show(_ tone: DSToast.Tone, _ message: String, action: DSInlineAction? = nil) {
        current = Toast(tone: tone, message: message, action: action)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        scheduleDismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        guard let toast = current, toast.tone == .default || toast.tone == .success else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, !self.isHovered, self.current?.id == toast.id else { return }
            self.current = nil
        }
    }
}

/// Figma "Banner" (141:101): persistent inline state — a 3 pt coloured left rule on a tinted fill (never colour
/// alone: every tone has its icon), title, optional message, Small secondary action and close.
struct DSBanner: View {
    enum Tone { case info, success, warning, error, neutral }

    let tone: Tone
    let title: String
    var message: String?
    var action: DSInlineAction?
    var onClose: (() -> Void)?
    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.s8) {
            icon.image(size: 18).foregroundColor(rule)
            VStack(alignment: .leading, spacing: DSSpace.s4) {
                Text(title).dsText(.bodyStrong).foregroundColor(DSColor.textPrimary)
                if let message {
                    Text(message).dsText(.caption).foregroundColor(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let action {
                    DSButton(text: action.title, size: .small, action: action.action)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onClose {
                DSIconButton(.close, size: 24, iconSize: 14, action: onClose)
                    .dsTooltip(.menuClose)
            }
        }
        .padding(.leading, DSSpace.s12)
        .padding(.trailing, DSSpace.s8)
        .padding(.vertical, DSSpace.s12)
        .background(fill)
        .overlay(alignment: .leading) { Rectangle().fill(rule).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.md))
        .accessibilityElement(children: .contain)
    }

    private var icon: DSIcon {
        switch tone {
        case .info: .info
        case .success: .checkOne
        case .warning, .error: .attention
        case .neutral: .lock
        }
    }

    private var rule: Color {
        switch tone {
        case .info: DSColor.textAccent
        case .success: DSColor.statusSuccess
        case .warning: DSColor.statusWarning
        case .error: DSColor.statusDanger
        case .neutral: DSColor.textSecondary
        }
    }

    private var fill: Color {
        switch tone {
        case .info: DSColor.accentSubtle
        case .success: DSColor.statusSuccessSubtle
        case .warning: DSColor.statusWarningSubtle
        case .error: DSColor.statusDangerSubtle
        case .neutral: DSColor.backgroundHover
        }
    }
}
