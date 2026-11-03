import AppKit
import SwiftUI

/// The secondary "windows" opened from the Slek PDF and Help menus (Prototype D-27 … D-34a). Shown as in-window
/// panels over the scrim (design rule: every overlay gets a backdrop) — see docs/PROTOTYPE-GAPS.md §2.
enum AppPanel: Equatable {
    enum AboutTab: Hashable { case about, shortcuts, licenses, privacy }

    case about(AboutTab)
    case help
    case developer
    case releaseNotes
    case reportProblem
    case feedback
    case preferences(PreferencesPanel.Tab)
}

/// Contact details the Developer, Report and Feedback panels use. Not in the Figma file yet: until they are set,
/// the email opens without a recipient and the Website button stays disabled (Honest states).
enum SupportContact {
    static let email: String? = nil
    static let website: URL? = nil
}

struct AppPanelView: View {
    let panel: AppPanel

    var body: some View {
        switch panel {
        case let .about(tab): AboutPanel(tab: tab).id("about-\(tab)")
        case .help: HelpPanel()
        case .developer: DeveloperPanel()
        case .releaseNotes: ReleaseNotesPanel()
        case .reportProblem: MailFormPanel(kind: .report).id("report")
        case .feedback: MailFormPanel(kind: .feedback).id("feedback")
        case let .preferences(tab): PreferencesPanel(tab: tab).id("preferences-\(tab)")
        }
    }
}

private extension AppLanguage {
    func callAsFunction(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, self) }
}

// MARK: - D-27 About · D-28 Keyboard Shortcuts · D-29 Privacy & Licenses (About Window 146:343)

private struct AboutPanel: View {
    @State var tab: AppPanel.AboutTab
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        DSWindowPanel(onClose: { session.panel = nil }) {
            DSSegmentedControl(selection: $tab, segments: [
                .init(value: .about, title: language(.about)),
                .init(value: .shortcuts, title: language(.shortcut)),
                .init(value: .licenses, title: language(.licenses)),
                .init(value: .privacy, title: language(.privacy)),
            ])
            VStack(spacing: DSSpace.s12) {
                switch tab {
                case .about: about
                case .shortcuts: shortcuts
                case .licenses: licenses
                case .privacy: privacy
                }
            }
            .padding(.horizontal, DSSpace.s32)
        }
    }

    private var about: some View {
        Group {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text("Slek PDF").dsText(.title).foregroundColor(DSColor.textPrimary)
            Text(language(.version10PreviewBuild093MacO)).dsText(.caption).foregroundColor(DSColor.textSecondary)
            Text(language(.aKhmerFirstPDFToolForReadingOrga)).dsText(.body).foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            DSBanner(tone: .warning, title: language(.knownLimitations), message: language(.editingOriginalPDFTextHandwritingO),
                     action: DSInlineAction(title: language(.viewFullList)) { session.panel = .releaseNotes })
            HStack(spacing: DSSpace.s8) {
                // No verified update channel exists yet (setup guide §9: do not ship an unverified updater).
                DSButton(.checkForUpdates, size: .small).disabled(true)
                DSButton(.help, size: .small) { session.panel = .help }
            }
        }
    }

    /// Keyboard Shortcuts tab: the rows in the Figma Shortcuts state (196:43768).
    private var shortcuts: some View {
        let rows: [(CopyKey, [String])] = [
            (.openAPDF, ["⌘", "O"]), (.saveWork, ["⌘", "S"]), (.saveACopy, ["⌘", "⇧", "S"]), (.findInDocument, ["⌘", "K"]),
            (.findNext, ["⌘", "G"]), (.recognizeText, ["⌘", "⌥", "R"]), (.export, ["⌘", "E"]), (.fitPage, ["⌘", "0"]),
        ]
        return VStack(spacing: 0) {
            ForEach(rows, id: \.0) { DSShortcutRow(title: language($0.0), keys: $0.1) }
        }
    }

    /// Third-party software bundled with this build. Figma's list is a placeholder for an earlier stack; this is
    /// what the app really ships. Full texts: SlekPDF/Resources/Licenses.
    private var licenses: some View {
        let rows: [(String, String)] = [
            ("PDFium", "BSD 3-Clause License"),
            ("Tesseract OCR", "Apache License 2.0"),
            ("Leptonica", "BSD 2-Clause License"),
            ("tessdata khm/eng models", "Apache License 2.0"),
            ("KhmerOCR models", "MIT License"),
            ("ONNX Runtime", "MIT License"),
            ("Noto Sans Khmer", "SIL Open Font License 1.1"),
            ("Inter", "SIL Open Font License 1.1"),
            ("IconPark icons", "Apache License 2.0"),
        ]
        return Group {
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { name, licence in
                    HStack {
                        Text(name).dsText(.body).foregroundColor(DSColor.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                        Text(licence).dsText(.caption).foregroundColor(DSColor.textSecondary)
                    }
                    .padding(.vertical, DSSpace.s8)
                    .overlay(alignment: .bottom) { DSDivider() }
                }
            }
            Text(language(.placeholderListConfirmExactVersion)).dsText(.caption).foregroundColor(DSColor.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            DSButton(.showFullNotices, size: .small) { Self.revealNotices() }
        }
    }

    private var privacy: some View {
        VStack(spacing: DSSpace.s12) {
            Text(language(.filesStayOnThisMacNothingIsUplo)).dsText(.bodyStrong).foregroundColor(DSColor.textPrimary)
            Text(language(.slekPDFLetsYouReadOrganizeAnnota)).dsText(.body).foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Shows the bundled licence texts in Finder.
    private static func revealNotices() {
        let names = ["PDFium-LICENSE", "Tesseract-LICENSE", "Leptonica-LICENSE", "tessdata-LICENSE", "KhmerOCR-LICENSE", "ONNXRuntime-LICENSE",
                     "ONNXRuntime-ThirdPartyNotices", "NotoSansKhmer-OFL.txt", "Inter-OFL.txt"]
        let files = names.compactMap { Bundle.main.url(forResource: $0, withExtension: nil) }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }
}

// MARK: - D-30 Slek PDF Help (Help Window 198:990)

private struct HelpPanel: View {
    enum Topic: CaseIterable, Hashable {
        case gettingStarted, ocr, export, addText, troubleshooting

        var title: CopyKey {
            switch self {
            case .gettingStarted: .gettingStarted
            case .ocr: .recognizeKhmerTextOCR
            case .export: .exportToWordOrExcel
            case .addText: .addKhmerTextComments
            case .troubleshooting: .troubleshooting
            }
        }

        var icon: DSIcon {
            switch self {
            case .gettingStarted: .page
            case .ocr: .textRecognition
            case .export: .download
            case .addText: .addText
            case .troubleshooting: .help
            }
        }

        /// Only Getting started has an article in Figma so far; the other topics are listed but disabled.
        var hasArticle: Bool { self == .gettingStarted }
    }

    @State private var topic: Topic = .gettingStarted
    @State private var query = ""
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DSSpace.s16) {
                DSWindowControls { session.panel = nil }
                Text(language(.slekPDFHelp)).dsText(.bodyStrong).foregroundColor(DSColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                DSSearchField(text: $query, placeholder: .searchHelp).frame(width: 240)
            }
            .padding(.leading, DSSpace.s16)
            .padding(.trailing, DSSpace.s12)
            .frame(height: 52)
            .background(DSColor.backgroundWindow)
            .overlay(alignment: .bottom) { DSDivider() }
            HStack(spacing: 0) {
                VStack(spacing: DSSpace.s2) {
                    ForEach(Topic.allCases.filter(matches), id: \.self) { topicRow($0) }
                    Spacer()
                }
                .padding(.top, DSSpace.s12)
                .padding(.horizontal, DSSpace.s8)
                .frame(width: 236)
                .background(DSColor.backgroundWindow)
                .overlay(alignment: .trailing) { DSDivider(axis: .vertical) }
                ScrollView { article.padding(DSSpace.s32) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DSColor.backgroundSurface)
            }
        }
        .frame(width: 800, height: 580)
        .background(DSColor.backgroundSurface)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.shell))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.shell).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .dsElevation(.dialog)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var articleKeys: [CopyKey] {
        [.slekPDFLetsYouReadOrganizeAnnota, .chooseOpenPDFOOrDragAPDFInto, .useTheTabsToSwitchWorkspaceRead,
         .saveWorkSKeepsYourAddedTextAnd, .switchTheInterfaceLanguageAnyTimeW]
    }

    private func matches(_ item: Topic) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        let text = ([item.title] + (item.hasArticle ? articleKeys : [])).map { language($0) }.joined(separator: " ")
        return text.localizedCaseInsensitiveContains(needle)
    }

    private func topicRow(_ item: Topic) -> some View {
        let isSelected = item == topic
        return Button { topic = item } label: {
            HStack(spacing: DSSpace.s8) {
                item.icon.image(size: 16)
                Text(language(item.title)).dsText(isSelected ? .bodyStrong : .body).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundColor(isSelected ? DSColor.textAccent : item.hasArticle ? DSColor.textPrimary : DSColor.textDisabled)
            .padding(.horizontal, DSSpace.s8)
            .padding(.vertical, DSSpace.s6)
            .background(RoundedRectangle(cornerRadius: DSRadius.sm).fill(isSelected ? DSColor.backgroundSelected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.hasArticle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var article: some View {
        VStack(alignment: .leading, spacing: DSSpace.s16) {
            Text(language(.gettingStarted)).dsText(.title).foregroundColor(DSColor.textPrimary)
            Text(language(.slekPDFLetsYouReadOrganizeAnnota)).dsText(.body).foregroundColor(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DSSpace.s12) {
                ForEach(Array([CopyKey.chooseOpenPDFOOrDragAPDFInto, .useTheTabsToSwitchWorkspaceRead, .saveWorkSKeepsYourAddedTextAnd].enumerated()),
                        id: \.offset) { index, key in
                    HStack(alignment: .top, spacing: DSSpace.s12) {
                        Text("\(index + 1)").font(.system(size: 12, weight: .bold)).foregroundColor(DSColor.textAccent)
                            .frame(width: 24, height: 24).background(Circle().fill(DSColor.accentSubtle))
                        Text(language(key)).dsText(.body).foregroundColor(DSColor.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            DSBanner(tone: .info, title: language(.switchTheInterfaceLanguageAnyTimeW))
            HStack(spacing: DSSpace.s4) {
                Text(language(.related)).dsText(.labelSmall).foregroundColor(DSColor.textTertiary)
                linkButton(.keyboardShortcuts) { session.panel = .preferences(.shortcuts) }
                linkButton(.privacy) { session.panel = .about(.privacy) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkButton(_ key: CopyKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(language(key)).dsText(.labelSmall).foregroundColor(DSColor.textAccent)
                .padding(.horizontal, DSSpace.s12).frame(height: 24).contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - D-31 Developer (Developer Window 260:62574)

private struct DeveloperPanel: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        DSWindowPanel(onClose: { session.panel = nil }) {
            VStack(spacing: DSSpace.s12) {
                DSAvatar(initials: language(.hd))
                Text(language(.hoeurnDareach)).dsText(.title).foregroundColor(DSColor.textPrimary)
                Text(language(.designerDeveloperPhnomPenhCambo)).dsText(.caption).foregroundColor(DSColor.textSecondary)
                Text(language(.iDesignAndBuildSlekPDFIndependentl)).dsText(.body).foregroundColor(DSColor.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DSSpace.s8) {
                    DSButton(.sendFeedback2, size: .small) { session.panel = .feedback }
                    DSButton(.website, size: .small) { if let url = SupportContact.website { NSWorkspace.shared.open(url) } }
                        .disabled(SupportContact.website == nil)
                }
            }
            .padding(.horizontal, DSSpace.s32)
        }
    }
}

// MARK: - D-32 Release Notes (Release Notes Window 268:508)

private struct ReleaseNotesPanel: View {
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        DSWindowPanel(onClose: { session.panel = nil }) {
            VStack(alignment: .leading, spacing: DSSpace.s12) {
                Text(language(.releaseNotes)).dsText(.title).foregroundColor(DSColor.textPrimary)
                Text(language(.version10PreviewBuild093MacO2)).dsText(.caption).foregroundColor(DSColor.textSecondary)
                list(title: .whatSNew, items: [.readSearchAndOrganizePDFsMerge, .recognizeKhmerTextOCRAndReview, .exportToWordExcelSearchablePDF,
                                               .addKhmerTextBoxesHighlightsAndC, .customizeKeyboardShortcutsInPrefer, .everythingIsProcessedOnYourMac])
                list(title: .knownLimitations2, items: [.editingOriginalPDFTextHandwriting, .documentsSetInOlderNonUnicodeKhm])
                HStack {
                    Spacer()
                    DSButton(.done, style: .primary) { session.panel = nil }.keyboardShortcut(.defaultAction)
                }
                .padding(.top, DSSpace.s8)
            }
            .padding(.horizontal, DSSpace.s32)
            .padding(.bottom, DSSpace.s24)
        }
    }

    private func list(title: CopyKey, items: [CopyKey]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(language(title)).dsText(.bodyStrong).foregroundColor(DSColor.textPrimary)
            ForEach(items, id: \.self) { item in
                Text(language(item)).dsText(.body).foregroundColor(DSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - D-33 Report a Problem (268:577) · D-34 Send Feedback (270:503) → D-33a / D-34a toast

private struct MailFormPanel: View {
    enum Kind { case report, feedback }

    let kind: Kind
    @State private var choice = 0
    @State private var message = ""
    @State private var includeSystemInfo = true
    @State private var attachPDF = false
    @EnvironmentObject private var session: DocumentSession
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.appLanguage) private var language

    var body: some View {
        DSWindowPanel(onClose: { session.panel = nil }) {
            VStack(alignment: .leading, spacing: DSSpace.s12) {
                Text(language(kind == .report ? .reportAProblem : .sendFeedback)).dsText(.title).foregroundColor(DSColor.textPrimary)
                Text(language(kind == .report ? .tellUsWhatWentWrongYourReportOpen : .haveAnIdeaOrSomethingYouLikeOrD))
                    .dsText(.body).foregroundColor(DSColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                DSDropdown(label: language(kind == .report ? .whatWereYouDoing : .topic), selection: $choice,
                           options: choices.enumerated().map { (value: $0.offset, title: language($0.element)) })
                DSTextArea(label: language(kind == .report ? .whatHappened : .yourFeedback), text: $message,
                           placeholder: language(kind == .report ? .describeWhatYouExpectedAndWhatHapp : .tellMeWhatWouldMakeSlekPDFBetter),
                           helper: kind == .report ? language(.pleaseDonTIncludePasswordsOrOther) : nil)
                DSCheckbox(label: .includeAppVersionAndMacOSDetails, isOn: $includeSystemInfo)
                if kind == .report {
                    DSCheckbox(label: .attachTheOpenPDF, isOn: $attachPDF).disabled(session.url == nil)
                }
                HStack(spacing: DSSpace.s8) {
                    Spacer()
                    DSButton(.cancel) { session.panel = nil }
                    // ⌘↩, not Return: Return must stay a new line in the message field.
                    DSButton(kind == .report ? .sendReport : .sendFeedback2, style: .primary, action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.top, DSSpace.s8)
            }
            .padding(.horizontal, DSSpace.s32)
            .padding(.bottom, DSSpace.s24)
        }
    }

    /// Figma shows one value per dropdown; until Figma defines the lists, the report offers the workspaces.
    private var choices: [CopyKey] {
        kind == .report ? [.exportingToWordOrExcel, .menuRead, .menuOrganizePages, .menuAnnotate, .menuKhmerOCR] : [.ideaForAFeature]
    }

    private func send() {
        var lines = [language(kind == .report ? .whatWereYouDoing : .topic) + " " + language(choices[choice]), "", message]
        if includeSystemInfo { lines += ["", SystemInfo.summary] }
        var items: [Any] = [lines.joined(separator: "\n")]
        // The PDF is attached only when the user opts in (Report Problem Window description).
        if kind == .report, attachPDF, let url = session.url { items.append(url) }
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) else {
            NSSound.beep()  // no email app is set up; the form stays open so nothing typed is lost
            return
        }
        service.recipients = SupportContact.email.map { [$0] } ?? []
        service.subject = "Slek PDF — " + language(kind == .report ? .reportAProblem : .sendFeedback)
        service.perform(withItems: items)
        session.panel = nil
        toasts.show(.success, language(kind == .report ? .reportOpenedInMailCheckItThenP : .feedbackOpenedInMailCheckItThen))
    }
}

enum SystemInfo {
    /// "Slek PDF 1.0 (1) · macOS 15.1.0 · arm64" for reports.
    static var summary: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "Slek PDF \(version) (\(build)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch)"
    }
}
