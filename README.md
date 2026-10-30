# Slek PDF — macOS app

Native Swift app (SwiftUI + AppKit, PDFKit for display, PDFium for Khmer text/search and delivered copies), minimum macOS 13.0, Apple Silicon and Intel.
Product spec: `../../Assets/Khmer-PDF-App-Setup.md` and `Khmer-PDF-App-Release-Checklist.md`.
Visual reference: Figma file `GrvVYMZQvBs11vwtYNfYvH` (KhmerPDF), Prototype page — see `docs/PROTOTYPE-MAP.md`.

## Requirements

- Xcode 27.1 or later that still supports a macOS 13.0 deployment target.
- Vendored PDFium binary in `Vendor/pdfium` (see `Vendor/pdfium/SOURCE.md`); it is linked and embedded by the project, nothing to install. Unit tests need macOS 14+ (XCTest); the app itself runs on 13+.
- No package manager or code generators. The project uses Xcode synchronized folders, so new files in `SlekPDF/` or `SlekPDFTests/` are picked up automatically.

## Commands

| Task | Command |
| --- | --- |
| Build | `xcodebuild build -scheme SlekPDF -destination 'platform=macOS' -derivedDataPath build/DerivedData` |
| Test | `xcodebuild test -scheme SlekPDF -destination 'platform=macOS' -derivedDataPath build/DerivedData` |
| Universal release build | `xcodebuild build -scheme SlekPDF -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` |
| Render shell snapshots (KM/EN × Light/Dark, 1280×900) | `Tools/render_snapshots.sh` → `build/snapshots/` |
| Regenerate tokens + copy keys | `python3 Tools/generate_tokens.py` |
| Regenerate icons + app icon | `python3 Tools/import_icons.py` |

Verify a release binary: `lipo -info …/SlekPDF.app/Contents/MacOS/SlekPDF` (x86_64 arm64) and `otool -l … | grep minos` (13.0) — check `Contents/Frameworks/libpdfium.dylib` too.

## Figma → code pipeline

Nothing visual is hand-typed; it is exported from Figma and generated.

| Figma | Export in repo | Generated Swift |
| --- | --- | --- |
| Variables: Color (Light/Dark), primitives, Spacing, Typography (Khmer/English); text + effect styles | `Design/figma-variables.json` | `DesignSystem/Generated/DSColors.swift`, `DSSpacing.swift`, `DSTypography.swift`, `DSElevation.swift` |
| `Copy/*` string variables (Khmer + English) | `SlekPDF/Resources/Copy/copy.json` | `DesignSystem/Generated/CopyKey.swift` |
| Iconography page (30:1316): 67 IconPark icons + Word/Excel/PDF marks, app icon 106:189 | `Design/icons/*.svg`, `Design/appicon/AppIcon-1024.png` | `Resources/Assets.xcassets`, `DesignSystem/Generated/DSIcon.swift` |

Rules carried over from the design system:

- Use `DSColor.*` (semantic), never `DSPrimitive.*` or literal colours, in views.
- Use `DSLabel(.key, style:)` / `.dsText(style)` for all text; the font, size and line height follow the interface language (Noto Sans Khmer for Khmer, Inter for English).
- Use `DSIcon.*` for all icons (Figma IconPark set). IconPark icons are template images tinted with `foregroundColor`; Word/Excel/PDF marks keep their colours.
- Text buttons are pills (`DSButton`); icon-only buttons are rounded squares (`DSIconButton`).
- Spacing/radius/stroke come from `DSSpace`, `DSRadius`, `DSStroke`.
- Interface language switches live (status bar, View ▸ Interface Language) and is independent of the system language.
- No macOS 14+ API without `if #available` (no `@Observable`/Observation, `onChange(of:initial:)` two-parameter form, `ContentUnavailableView`). macOS 13 APIs (`NavigationSplitView`, `Grid`, `ViewThatFits`, `defaultSize`) are fine.
- PDF text: use `PDFiumDocument` for Khmer text extraction, search and writing delivered copies; never redraw an original page to add content (it damages Khmer text — docs/spikes/01-pdfkit-khmer.md). PDFKit is for display and annotations.

### Adding copy

Only the strings used by the shell are in `copy.json` so far (25 of ~1,060 Figma `Copy/*` variables; part of the rest is website copy).
Export more from the Figma Typography collection (Khmer + English values) in chunks of about 100 per `use_figma` call (48 KB return limit), merge into `copy.json` (`{"<Figma name without Copy/>": {"km": …, "en": …}}`), then run `python3 Tools/generate_tokens.py`. The generator rejects missing values and Khmer glyphs in English values.

## Layout

```text
SlekPDF/App/              App entry, AppState (language, appearance, workspace), menu commands
SlekPDF/DesignSystem/     Token support, typography, fonts, components; Generated/ is tool output
SlekPDF/Features/Shell/   Main window: title bar, toolbar, workspace tabs, sidebar, canvas, inspector, status bar
SlekPDF/Localization/     Copy catalog (km/en) and language environment
SlekPDF/Resources/        Fonts (OFL), copy.json, Assets.xcassets
SlekPDFTests/             Token, copy, font, icon tests; shell snapshot renderer
Config/                   Info.plist additions, entitlements (sandbox, user-selected files, print)
Design/                   Figma exports (source of generated code)
Licenses/                 Third-party licences to ship with the app (PDFium's are in Vendor/pdfium/LICENSE + licenses/)
Vendor/                   Vendored native libraries (PDFium)
Tools/                    Generators and snapshot script
docs/                     Prototype map and prototype-vs-native gaps
```

## Placeholders to replace before release

- Bundle identifier `com.example.SlekPDF` and ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`); needs the real identifier and a Developer ID team.
- Not yet run on a Mac with macOS 13: building with a 13.0 target only shows that the APIs it uses exist on macOS 13.
