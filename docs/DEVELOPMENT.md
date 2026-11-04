# Developing Slek PDF

How the project is built, tested and kept in step with the Figma design. For what the app does, see the
[README](../README.md).

## Requirements

- macOS with Xcode 27.1 or later (still supporting a macOS 13.0 deployment target).
- Native libraries are vendored and embedded by the project — nothing to install:
  PDFium (`Vendor/pdfium`), Tesseract + Leptonica (`Vendor/tesseract`), ONNX Runtime (`Vendor/onnxruntime`, Apple Silicon
  only) and the KhmerOCR models (`SlekPDF/Resources/khmerocr.bundle`). Each `Vendor/*/SOURCE.md` records where it came from.
- No package manager and no code generators run at build time. Xcode synchronized folders pick up new files in
  `SlekPDF/` and `SlekPDFTests/` automatically.
- The app runs on macOS 13+; the unit tests need macOS 14+ (XCTest).

## Commands

| Task | Command |
| --- | --- |
| Build | `xcodebuild build -scheme SlekPDF -destination 'platform=macOS'` |
| Test | `xcodebuild test -scheme SlekPDF -destination 'platform=macOS'` |
| One test class | `xcodebuild test -scheme SlekPDF -destination 'platform=macOS' -only-testing:SlekPDFTests/EditPDFTextTests` |
| Universal release build | `xcodebuild build -scheme SlekPDF -configuration Release -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` |
| Snapshots (Khmer/English × light/dark) | `TEST_RUNNER_SNAPSHOT_DIR=1 xcodebuild test … -only-testing:SlekPDFTests/ShellSnapshotTests` → the test host's `tmp/shell-snapshots/` |
| OCR benchmark | see [`Tools/ocr-eval/README.md`](../Tools/ocr-eval/README.md) (`TEST_RUNNER_OCR_BENCH=1`) |
| Regenerate tokens and copy keys | `python3 Tools/generate_tokens.py` |
| Regenerate icons and the app icon | `python3 Tools/import_icons.py` |
| Rebuild Tesseract / Leptonica | `Tools/build_tesseract.sh <source dir>` (needs `brew install cmake`) |

Verify a release binary with `lipo -info …/SlekPDF.app/Contents/MacOS/SlekPDF` (x86_64 arm64) and
`otool -l … | grep minos` (13.0); check the libraries in `Contents/Frameworks` too.

If a test build fails with a code-signing error about `SlekPDFTests.xctest`, or with missing symbols after a change of
initializers, clean the build folder (Xcode: Product ▸ Clean Build Folder, ⇧⌘K) and build again.

## Figma → code

The Figma file (`GrvVYMZQvBs11vwtYNfYvH`, Prototype page) is the source of truth. Nothing visual is typed by hand; it is
exported from Figma and generated.

| Figma | Export in the repo | Generated Swift |
| --- | --- | --- |
| Variables: Color (light/dark), primitives, Spacing, Typography (Khmer/English); text and effect styles | `Design/figma-variables.json` | `DesignSystem/Generated/DSColors.swift`, `DSSpacing.swift`, `DSTypography.swift`, `DSElevation.swift` |
| `Copy/*` string variables (Khmer + English) | `SlekPDF/Resources/Copy/copy.json` | `DesignSystem/Generated/CopyKey.swift` |
| Iconography page (30:1316): IconPark outline icons, Word/Excel/PDF marks; app icon (106:189) | `Design/icons/*.svg`, `Design/appicon/AppIcon-1024.png` | `Resources/Assets.xcassets`, `DesignSystem/Generated/DSIcon.swift` |

Screens map to Figma frames in [`docs/PROTOTYPE-MAP.md`](PROTOTYPE-MAP.md); known differences are in
[`docs/PROTOTYPE-GAPS.md`](PROTOTYPE-GAPS.md).

### Design-system rules

- Colours: `DSColor.*` (semantic) only — never `DSPrimitive.*` or literal colours in views (document colours that are
  written into a PDF are the exception).
- Text: `DSLabel(.key, style:)` or `.dsText(style)`. Font, size and line height follow the interface language
  (Noto Sans Khmer for Khmer, Inter for English).
- Icons: `DSIcon.*`. IconPark icons are template images tinted with `foregroundColor`; Word/Excel/PDF marks keep their colours.
- Buttons: text buttons are pills (`DSButton`), icon-only buttons are rounded squares (`DSIconButton`).
- Spacing, radius and stroke come from `DSSpace`, `DSRadius` and `DSStroke`.
- The interface language switches live (status bar, View ▸ Interface Language), independently of the system language.
- macOS 13: no macOS 14+ API without `if #available` (no Observation/`@Observable`, no two-parameter
  `onChange(of:initial:)`, no `ContentUnavailableView`).
- PDF text: use PDFium (`PDFiumDocument`, `PDFiumService`) for Khmer text, search and writing new files. Never redraw an
  original page to add content — it damages Khmer text ([spike 01](spikes/01-pdfkit-khmer.md)). PDFKit is for display.
- The source PDF is never changed: Save work and every export write a new file.

### Adding copy

Add the string to Figma as a `Copy/<name>` variable (Khmer and English values), add the same key to
`SlekPDF/Resources/Copy/copy.json` (`{"<name>": {"km": …, "en": …}}`), then run `python3 Tools/generate_tokens.py`.
The generator rejects missing values and Khmer letters in English values. New Khmer strings are drafts until a native
speaker has reviewed them (they carry a `note`).

## Project layout

```text
SlekPDF/App/            App entry, app state (language, appearance), menus, keyboard shortcuts
SlekPDF/Document/       DocumentSession (one open PDF), PDFium wrappers, annotations, Khmer text rebuilder and normaliser
SlekPDF/Features/       One folder per workspace and panel: Read, Organize, Annotate, OCR, Export, Print, Preferences, …
SlekPDF/OCR/            KhmerOCR (ONNX), Tesseract, routing between them, text over pictures, curved seal text
SlekPDF/Conversion/     Word and Excel writers
SlekPDF/DesignSystem/   Tokens, typography, components; Generated/ is tool output
SlekPDF/Resources/      Fonts (OFL), copy.json, KhmerOCR models, asset catalog, third-party licences
SlekPDFTests/           Unit, interaction and snapshot tests (Fixtures/ holds small sample PDFs)
Config/                 Info.plist additions and entitlements (sandbox, user-selected files, print)
Design/                 Figma exports — the source of generated code
Vendor/                 Vendored native libraries and their sources
Tools/                  Generators, snapshot and OCR evaluation scripts
docs/                   Plans, spikes (measurements behind decisions), prototype map
```

## Branches

| Branch | Use |
| --- | --- |
| `main` | Released state |
| `menu-bar-and-preferences` | Current development |
| `feature/annotation` | Annotate and Edit PDF text work |
| `feature/ocr-training` | OCR accuracy work |

Real test documents (scans, private PDFs) are kept outside the repository and never committed.
