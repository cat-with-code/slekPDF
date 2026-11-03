# Where native macOS 13 can and can't match the prototype

Status after the shell scaffold (30 Oct 2026). "Verified" means built, tested and rendered here (macOS 27 dev machine; macOS 13 runtime not yet tested). Minimum raised from macOS 12 to 13 on 30 Oct 2026.

## Verified — matches the prototype

| Area | How |
| --- | --- |
| Colours, Light/Dark | Generated from Figma variables; dynamic `NSColor`; theme switch sets `NSApp.appearance` |
| Khmer/English live switch | Own copy catalog from Figma `Copy/*`; fonts and line heights switch with it |
| Typography | Bundled Noto Sans Khmer + Inter (OFL). Every Figma line height ≥ the font's natural height (Khmer: Body 22 vs 18, Heading 26 vs 21), so no clipping; extra space is split above/below like Figma |
| Icons | All 70 icons from the Iconography page as vector template assets; app icon from 106:189 |
| Window sizes | Min 1024×720, default 1280×900, sidebar/inspector widths per size class |
| macOS 13 + both architectures | Universal binary incl. embedded PDFium, `minos 13.0`, `LSMinimumSystemVersion 13.0` |
| Sandbox | App Sandbox, user-selected read/write, bookmarks, print — test host proves writes outside the container are blocked |

## Decisions needed

1. ~~Dialogs and the scrim~~ — **decided by the design rule "every overlay gets a backdrop"**: in-window overlays (`ModalLayer` + `DSDialog`): title bar/toolbar stay visible but inert, Background/Scrim at 35% over y 94–864, content blurred, Esc/Return wired, Open/drop disabled, `.isModal` for VoiceOver. Built for screens 13 and 35. The blur cannot be captured by the snapshot renderer (cacheDisplay); check it in the running app.
2. ~~Secondary windows~~ — same rule: About, Help, Developer, Release Notes, Report, Feedback open as in-window panels over the scrim (not separate NSWindows).
3. **Title bar.** With a hidden title bar the system traffic lights sit near the top, not vertically centred in the 44 pt bar as in Figma. Options: accept the small offset, or reposition the buttons via AppKit (works but must be re-applied on resize/full screen).
4. ~~Menu bar~~ — **built (3 Nov 2026)** as the native macOS menu. Items the app owns are SwiftUI `Commands` with titles from the `menu: …` copy keys; the menu titles and macOS-owned items (Undo, Cut/Copy/Paste, Select All, Dictation, Minimize, Zoom, tab items, Bring All to Front) are retitled by `MainMenuLocalizer`, matched by action. Services, Hide, Delete, AutoFill and Emoji & Symbols are hidden as in Figma. Remaining differences, all accepted:
   - macOS draws the menus: Figma's menu styling (accent highlight, radius, Noto Sans Khmer) can't be applied; Khmer appears in the system Khmer font.
   - The Help menu's search field is the system one, without Figma's ⌘K hint.
   - The tool keys V/T/H/C are not menu key equivalents (a bare key would fire while typing in a text field); the Annotate canvas must handle them.
   - Without Hide in the app menu, ⌘H no longer hides the app. About opens the standard macOS panel until the About window (D-27) exists.
   - "Enter Full Screen" keeps its title in full screen (no "Exit" copy in Figma).
   - System items that only appear with window tabs (Move Tab to New Window, Merge All Windows, Show All Tabs) and macOS window-tiling items have no copy and stay in the system language.
   - Live switching was tested on the development macOS only, not yet on macOS 13.
5. **System panels.** Open, Save, Print and font panels are drawn by macOS in the system language (English for most users), not Khmer. Unavoidable with native panels.
6. **Word / Excel icons.** The prototype uses the official Microsoft Word and Excel marks. They are Microsoft trademarks; check Microsoft's brand-use rules (or switch to the IconPark `file-word` / `file-excel` icons already in the set) before shipping.
7. **Bundle identifier and signing team.** Placeholder `com.example.SlekPDF`; needs the real reverse-domain ID and Apple Developer team.

## App menu & Help screens (D-27 … D-34a) — built 3 Nov 2026, open items

- **Contact details missing in Figma.** No support email or website URL exists in the file: Report/Feedback open the email without a recipient and Developer ▸ Website and Help ▸ Online Documentation are disabled. Set `SupportContact` in `AppPanels.swift`.
- **Dropdown lists.** Figma shows one value each ("Exporting to Word or Excel", "Idea for a feature"); the report offers the workspace names as other activities until Figma defines the lists.
- **Help articles.** Only "Getting started" has an article; the other four topics are listed but disabled.
- **Licences.** Figma's list is a placeholder for an earlier stack (PDF.js, pdf-lib, Tesseract.js); the app lists what it really bundles (PDFium, Tesseract, Leptonica, tessdata, Noto Sans Khmer, Inter, IconPark). Licence texts now ship in the app (`SlekPDF/Resources/Licenses`); PDFium's own dependency notices (`Vendor/pdfium/licenses`) still need adding before release.
- **Preferences (D-10 … D-10o) — built.** Default OCR language, export folder, recovery copies and OCR hints are stored now and take effect when OCR, export and recovery are built. Figma's sample "Custom" shortcuts (Export to Word, Recognize Current Page) are for commands that don't exist yet; the Custom group lists what the user adds. Tool keys V/T/H/C and ↩ (Mark reviewed) are shown but not editable (canvas keys, not ⌘ shortcuts).
- **Copy corrections to make in Figma.** The two version lines say "macOS 12 or later"; the app requires macOS 13, so `copy.json` says 13. "Check for updates…" is disabled (no verified update channel). The About/Release Notes version text ("1.0, Preview build 0.9.3") is placeholder copy: the build is `MARKETING_VERSION` 0.1.0 (1), which Report/Feedback system info uses.

## Not started (feasible, needs building)

- PDFKit canvas, thumbnails, search, page operations; two-up view for Large/Wide.
- Tooltip style: SwiftUI `.help()` shows the system tooltip, not the Figma Tooltip 91:30; a custom tooltip is needed for an exact match.
- Remaining ~1,035 `Copy/*` strings (import procedure in README).
- Exact component measurements via `get_design_context` per component.
- Prototype click-through links (hotspots/flows) not yet extracted; read them with `use_figma` when wiring navigation.
- Runtime test on real macOS 13 Intel and Apple Silicon Macs.
