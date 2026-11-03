import AppKit
import SwiftUI

/// Prototype D-10 Preferences and D-10k … D-10o Keyboard Shortcuts (Preferences window 164:6363, Keyboard
/// Shortcuts Panel 251:284, Add Shortcut Sheet 251:935). 656 × 711, Background/Surface, Radius/LG, 24 pt padding.
struct PreferencesPanel: View {
    enum Tab: Hashable { case general, shortcuts }

    @State var tab: Tab
    @State private var isAddingShortcut = false
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: DSSpace.s16) {
                header
                switch tab {
                case .general: GeneralPreferences()
                case .shortcuts: ShortcutPreferences(isAddingShortcut: $isAddingShortcut)
                }
            }
            .padding(DSSpace.s24)
            .frame(width: 656, height: 711, alignment: .top)
            .background(DSColor.backgroundSurface)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.lg).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
            .overlay(alignment: .topTrailing) {
                DSIconButton(.close, size: 24, iconSize: 14) { session.panel = nil }
                    .dsTooltip(.close)
                    .keyboardShortcut(isAddingShortcut ? nil : .cancelAction)
                    .disabled(isAddingShortcut)
                    .padding(DSSpace.s16)
            }
            .dsElevation(.dialog)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            if isAddingShortcut {
                // Figma 10l–10n: the sheet sits over its own scrim, above the Preferences window.
                DSColor.backgroundScrim.opacity(0.35)
                AddShortcutSheet(isPresented: $isAddingShortcut)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpace.s16) {
            VStack(alignment: .leading, spacing: DSSpace.s4) {
                Text(CopyCatalog.shared.string(.preferences, language)).dsText(.heading).foregroundColor(DSColor.textPrimary)
                Text(CopyCatalog.shared.string(.settingsApplyImmediatelyAndAreStore, language)).dsText(.caption).foregroundColor(DSColor.textSecondary)
            }
            DSSegmentedControl(selection: $tab, segments: [
                .init(value: .general, title: CopyCatalog.shared.string(.general, language)),
                .init(value: .shortcuts, title: CopyCatalog.shared.string(.keyboardShortcuts, language)),
            ])
        }
    }
}

private extension AppLanguage {
    func callAsFunction(_ key: CopyKey) -> String { CopyCatalog.shared.string(key, self) }
}

// MARK: - General (D-10)

private struct GeneralPreferences: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: DocumentSession
    @Environment(\.appLanguage) private var language

    /// Export folder choices: Documents, the folder picked before, and "Choose folder…".
    private enum Folder: Hashable { case documents, chosen, choose }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s16) {
            DSDropdown(label: language(.interfaceLanguage), selection: $appState.language,
                       options: [(value: AppLanguage.km, title: "ខ្មែរ (Khmer)"), (value: .en, title: "English")])
            DSDropdown(label: language(.appearance), selection: $appState.appearance,
                       options: [(value: AppearancePreference.light, title: language(.menuLight)), (value: .dark, title: language(.menuDark)),
                                 (value: .system, title: language(.useSystemSetting))])
            DSDropdown(label: language(.defaultOCRLanguage), selection: $appState.ocrLanguage,
                       options: [(value: OCRLanguage.khmer, title: "ខ្មែរ"), (value: .khmerEnglish, title: language(.khmerEnglish)),
                                 (value: .english, title: "English")])
            DSDropdown(label: language(.defaultExportFolder), selection: folderSelection, options: folderOptions)
            VStack(spacing: 0) {
                DSSettingRow(title: language(.keepRecoveryCopiesOnThisMac), description: language(.unsavedWorkCanBeRecoveredAfterACr),
                             isOn: $appState.keepRecoveryCopies)
                DSSettingRow(title: language(.showOCRConfidenceHints), description: language(.markUncertainRegionsOnTheSourcePag),
                             isOn: $appState.showOCRConfidenceHints)
            }
            DSDivider()
            VStack(alignment: .leading, spacing: DSSpace.s4) {
                Text(language(.privacyHelpLicenses)).dsText(.heading).foregroundColor(DSColor.textPrimary)
                Text(language(.localDocumentProcessingBundledOCR)).dsText(.caption).foregroundColor(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DSSpace.s8) {
                DSButton(.aboutLicenses) { session.panel = .about(.licenses) }
                Spacer()
                DSButton(.backToDocument, style: .primary) { session.panel = nil }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var folderOptions: [(value: Folder, title: String)] {
        var options: [(value: Folder, title: String)] = [(value: .documents, title: language(.documents))]
        if let folder = appState.exportFolder { options.append((value: .chosen, title: folder.lastPathComponent)) }
        options.append((value: .choose, title: language(.chooseFolder)))
        return options
    }

    private var folderSelection: Binding<Folder> {
        Binding(get: { appState.exportFolder == nil ? .documents : .chosen }, set: { value in
            switch value {
            case .documents: appState.setExportFolder(nil)
            case .chosen: break
            case .choose:
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url { appState.setExportFolder(url) }
            }
        })
    }
}

/// Figma "Setting Row" (140:37): title and description on the left, a Switch on the right, Border/Subtle below.
struct DSSettingRow: View {
    let title: String
    var description: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: DSSpace.s16) {
            VStack(alignment: .leading, spacing: DSSpace.s2) {
                Text(title).dsText(.body).foregroundColor(DSColor.textPrimary)
                if let description { Text(description).dsText(.caption).foregroundColor(DSColor.textSecondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DSSwitch(label: "", isOn: $isOn).accessibilityLabel(title)
        }
        .padding(.vertical, DSSpace.s12)
        .overlay(alignment: .bottom) { DSDivider() }
    }
}

// MARK: - Keyboard Shortcuts (D-10k)

private struct ShortcutPreferences: View {
    struct Conflict {
        let command: ShortcutCommand
        let shortcut: KeyShortcut
        let other: ShortcutCommand
    }

    @Binding var isAddingShortcut: Bool
    @ObservedObject private var store = ShortcutStore.shared
    @State private var query = ""
    @State private var recording: ShortcutCommand?
    @State private var conflict: Conflict?
    @Environment(\.appLanguage) private var language

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.s12) {
                HStack(spacing: DSSpace.s12) {
                    DSSearchField(text: $query, placeholder: .searchCommandsOrKeys, showsShortcutHint: false)
                    DSButton(.addCustomShortcut, icon: .plus, style: .primary) {
                        recording = nil
                        isAddingShortcut = true
                    }
                }
                Text(language(.clickAShortcutToChangeItThenPres)).dsText(.caption).foregroundColor(DSColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ShortcutCommand.Group.allCases, id: \.self) { group in
                    let rows = commands(in: group)
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(language(group.title)).dsText(.labelSmall).foregroundColor(DSColor.textSecondary)
                                .padding(.top, DSSpace.s12)
                                .padding(.bottom, DSSpace.s4)
                            ForEach(rows, id: \.self) { row($0, isCustom: group == .custom) }
                        }
                    }
                }
                HStack {
                    Spacer()
                    DSButton(.restoreDefaults, size: .small) { store.restoreDefaults() }.disabled(store.overrides.isEmpty)
                }
                .padding(.top, DSSpace.s8)
            }
            .padding(.trailing, DSSpace.s4)
        }
    }

    /// Rows per group, filtered by the search (command name or keys, e.g. "⌘S").
    private func commands(in group: ShortcutCommand.Group) -> [ShortcutCommand] {
        let base: [ShortcutCommand] = group == .custom
            ? store.customCommands
            : ShortcutCommand.allCases.filter { $0.group == group && $0.defaultShortcut != nil }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return base }
        return base.filter { command in
            language(command.title).localizedCaseInsensitiveContains(needle)
                || (store.shortcut(command)?.display.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    private func row(_ command: ShortcutCommand, isCustom: Bool) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.s4) {
            HStack(spacing: DSSpace.s8) {
                Text(language(command.title)).dsText(.body).foregroundColor(DSColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isCustom { DSBadge(label: language(.custom), tone: .accent, showsDot: false) }
                DSShortcutRecorder(shortcut: store.shortcut(command), isEditable: command.isEditable,
                                   isRecording: recording == command, isConflict: conflict?.command == command,
                                   onStart: { conflict = nil; recording = command },
                                   onRecord: { record($0, for: command) },
                                   onCancel: { recording = nil },
                                   onClear: { store.set(nil, for: command) })
                if isCustom {
                    DSIconButton(.delete, size: 24, iconSize: 16) { store.set(nil, for: command) }
                        .dsTooltip(text: language(.restoreDefaults))
                }
            }
            if let conflict, conflict.command == command {
                HStack(spacing: DSSpace.s8) {
                    Text(CopyCatalog.shared.format(.fmtShortcutIsAlreadyUsedByCommand, language, conflict.shortcut.display,
                                                   language(conflict.other.title)))
                        .dsText(.caption).foregroundColor(DSColor.statusDanger).fixedSize(horizontal: false, vertical: true)
                    DSButton(.replace, style: .plain, size: .small) {
                        store.replace(conflict.shortcut, for: conflict.command)
                        self.conflict = nil
                    }
                }
            }
        }
        .padding(.vertical, DSSpace.s8)
        .overlay(alignment: .bottom) { DSDivider() }
    }

    private func record(_ shortcut: KeyShortcut, for command: ShortcutCommand) {
        recording = nil
        if let other = store.conflict(for: shortcut, excluding: command) {
            conflict = Conflict(command: command, shortcut: shortcut, other: other)
        } else {
            conflict = nil
            store.set(shortcut, for: command)
        }
    }
}

/// Figma "Shortcut Recorder" (251:241), 148 × 28: Key Caps (Default), clear × on hover, Recording = accent field
/// "Type shortcut…" (a modifier ⌘ ⌥ ⌃ plus a key; Esc cancels, ⌫ removes), Conflict = red field.
struct DSShortcutRecorder: View {
    let shortcut: KeyShortcut?
    var isEditable = true
    let isRecording: Bool
    var isConflict = false
    var width: CGFloat = 148
    let onStart: () -> Void
    let onRecord: (KeyShortcut) -> Void
    let onCancel: () -> Void
    var onClear: (() -> Void)?
    @State private var isHovered = false
    @State private var monitor: Any?
    @Environment(\.appLanguage) private var language

    var body: some View {
        Button(action: { if isEditable { onStart() } }) {
            HStack(spacing: DSSpace.s2) {
                if isRecording {
                    Text(CopyCatalog.shared.string(.typeShortcut, language)).dsText(.caption).foregroundColor(DSColor.textAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                    if let shortcut {
                        ForEach(Array(shortcut.keyCaps.enumerated()), id: \.offset) { DSKeyCap(key: $0.element, size: .small) }
                    }
                    if isEditable, let onClear, shortcut != nil, isHovered || isConflict {
                        Button(action: onClear) { DSIcon.close.image(size: 12).foregroundColor(DSColor.textSecondary) }
                            .buttonStyle(.plain)
                            .padding(.leading, DSSpace.s2)
                    }
                }
            }
            .padding(.leading, DSSpace.s8)
            .padding(.trailing, DSSpace.s6)
            .frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: DSRadius.sm).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.sm).strokeBorder(border, lineWidth: isRecording || isConflict ? 1.5 : DSStroke.default))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .opacity(isEditable ? 1 : 0.6)
        .onChange(of: isRecording) { recording in recording ? startMonitor() : stopMonitor() }
        .onAppear { if isRecording { startMonitor() } }
        .onDisappear(perform: stopMonitor)
        .accessibilityLabel(shortcut?.display ?? CopyCatalog.shared.string(.typeShortcut, language))
    }

    private var fill: Color {
        if isRecording { return DSColor.backgroundSelected }
        if isConflict { return DSColor.statusDangerSubtle }
        return DSColor.backgroundSurface
    }

    private var border: Color {
        if isRecording { return DSColor.accentDefault }
        if isConflict { return DSColor.statusDanger }
        return isHovered && isEditable ? DSColor.borderStrong : DSColor.borderDefault
    }

    /// Takes key presses before the menus do while recording, so ⌘S is recorded rather than run.
    private func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { onCancel(); return nil }  // Esc cancels
            if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                onClear?()  // ⌫ removes
                onCancel()
                return nil
            }
            guard let shortcut = KeyShortcut(event: event), shortcut.isValidCustom else {
                NSSound.beep()
                return nil
            }
            onRecord(shortcut)
            return nil
        }
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - D-10l … D-10o Add custom shortcut (Add Shortcut Sheet 251:935)

private struct AddShortcutSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var store = ShortcutStore.shared
    @EnvironmentObject private var toasts: ToastCenter
    @State private var command: ShortcutCommand = ShortcutCommand.allCases.first { $0.defaultShortcut == nil } ?? .fitWidth
    @State private var shortcut: KeyShortcut?
    @State private var isRecording = true
    @Environment(\.appLanguage) private var language

    private var conflict: ShortcutCommand? { shortcut.flatMap { store.conflict(for: $0, excluding: command) } }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s12) {
            Text(language(.addCustomShortcut)).dsText(.title).foregroundColor(DSColor.textPrimary)
            Text(language(.chooseAnyCommandFromTheMenusThen)).dsText(.body).foregroundColor(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DSDropdown(label: language(.command), selection: $command, options: ShortcutCommand.allCases.filter(\.isEditable).map {
                (value: $0, title: language($0.menuTitle) + " ▸ " + language($0.title))
            })
            Text(language(.shortcut)).dsText(.labelSmall).foregroundColor(DSColor.textSecondary)
            DSShortcutRecorder(shortcut: shortcut, isRecording: isRecording, isConflict: conflict != nil, width: 200,
                               onStart: { isRecording = true },
                               onRecord: { shortcut = $0; isRecording = false },
                               onCancel: { isRecording = false },
                               onClear: { shortcut = nil; isRecording = true })
            status
            HStack(spacing: DSSpace.s8) {
                if conflict != nil {
                    DSButton(.replace, style: .plain) { add(replacing: true) }
                }
                Spacer()
                DSButton(.cancel) { isPresented = false }
                DSButton(.addShortcut, style: .primary) { add(replacing: false) }
                    .disabled(shortcut == nil || conflict != nil || isRecording)
            }
        }
        .padding(DSSpace.s24)
        .frame(width: 448)
        .background(RoundedRectangle(cornerRadius: DSRadius.lg).fill(DSColor.backgroundRaised))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.lg).strokeBorder(DSColor.borderSubtle, lineWidth: DSStroke.default))
        .dsElevation(.dialog)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// Recording hint, "free — ready to add" (Status/Success) or the conflict (Status/Danger).
    @ViewBuilder private var status: some View {
        if let shortcut, let conflict {
            Text(CopyCatalog.shared.format(.fmtShortcutIsAlreadyUsedByCommand, language, shortcut.display, language(conflict.title)))
                .dsText(.caption).foregroundColor(DSColor.statusDanger).fixedSize(horizontal: false, vertical: true)
        } else if let shortcut, !isRecording {
            Text(CopyCatalog.shared.format(.fmtShortcutIsFree, language, shortcut.display)).dsText(.caption).foregroundColor(DSColor.statusSuccess)
        } else {
            Text(language(.pressAModifierAndAKeyEsc)).dsText(.caption).foregroundColor(DSColor.textTertiary)
        }
    }

    private func add(replacing: Bool) {
        guard let shortcut else { return }
        if replacing { store.replace(shortcut, for: command) } else { store.set(shortcut, for: command) }
        isPresented = false
        // D-10o: "Shortcut added · Export to Word ⌃⌘W".
        toasts.show(.default, CopyCatalog.shared.format(.fmtShortcutAddedCommandKeys, language, shortcut.display, language(command.title)))
    }
}
