import CoreGraphics

/// Window size classes from the Figma Responsive page (1:6).
/// Chrome rows are fixed; the document canvas absorbs the remaining width.
enum WindowSizeClass: CaseIterable {
    /// 1024×720 — page sidebar hidden behind a toolbar toggle.
    case compact
    /// 1280×900 — default.
    case regular
    /// 1440×900 — two pages side by side.
    case large
    /// 1920×1080 — previews at about 100%.
    case wide

    init(width: CGFloat) {
        switch width {
        case ..<1280: self = .compact
        case ..<1440: self = .regular
        case ..<1920: self = .large
        default: self = .wide
        }
    }

    /// Page sidebar width; nil when the sidebar is hidden by default.
    var sidebarWidth: CGFloat? {
        switch self {
        case .compact: nil
        case .regular: 120
        case .large: 140
        case .wide: 160
        }
    }

    var inspectorWidth: CGFloat {
        switch self {
        case .compact: 280
        case .regular: 296
        case .large: 320
        case .wide: 360
        }
    }
}

enum ChromeMetrics {
    static let titleBarHeight: CGFloat = 44
    static let toolbarHeight: CGFloat = 50
    static let workspaceTabsHeight: CGFloat = 44
    static let statusBarHeight: CGFloat = 36

    static let minimumWindowSize = CGSize(width: 1024, height: 720)
    static let defaultWindowSize = CGSize(width: 1280, height: 900)
}
