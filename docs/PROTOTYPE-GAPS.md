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
4. **Menu bar.** It is the real macOS menu (SwiftUI `Commands`). Custom items can follow the live Khmer switch; standard items supplied by macOS (Window menu entries, Services, some Edit items) appear in the system language because macOS has no Khmer localisation. The App menu can be reduced to About · Developer · Preferences · Quit as designed. Needs a short spike.
5. **System panels.** Open, Save, Print and font panels are drawn by macOS in the system language (English for most users), not Khmer. Unavoidable with native panels.
6. **Word / Excel icons.** The prototype uses the official Microsoft Word and Excel marks. They are Microsoft trademarks; check Microsoft's brand-use rules (or switch to the IconPark `file-word` / `file-excel` icons already in the set) before shipping.
7. **Bundle identifier and signing team.** Placeholder `com.example.SlekPDF`; needs the real reverse-domain ID and Apple Developer team.

## Not started (feasible, needs building)

- PDFKit canvas, thumbnails, search, page operations; two-up view for Large/Wide.
- Tooltip style: SwiftUI `.help()` shows the system tooltip, not the Figma Tooltip 91:30; a custom tooltip is needed for an exact match.
- Remaining ~1,035 `Copy/*` strings (import procedure in README).
- Exact component measurements via `get_design_context` per component.
- Prototype click-through links (hotspots/flows) not yet extracted; read them with `use_figma` when wiring navigation.
- Runtime test on real macOS 13 Intel and Apple Silicon Macs.
