# Spike 01 — Khmer text in PDFKit (30 Oct 2026)

Question: can the app read, search and add Khmer text with Apple's PDFKit so that the results copy and search correctly **in other viewers**?

Run it: `PYTHON=<venv with pypdf, pdfminer.six, pypdfium2> Tools/fixtures/run_pdfkit_spike.sh` (needs `qpdf` on PATH for E7).
Fixtures: `Tools/fixtures/make_fixtures.sh` → `SlekPDFTests/Fixtures/khmer-coretext.pdf` (Apple Core Text) and `khmer-chrome.pdf` (Chrome/Skia), same six lines (`khmer-sample-lines.json`): clusters, coeng, pre-base vowels, Khmer numerals, mixed Khmer/English.
Independent checkers: pypdf, pdfminer.six, PDFium (Chrome's engine, via pypdfium2). Visual check rendered by PDFKit and PDFium.
Limits: synthetic fixtures only (no real-world PDFs yet); tested on macOS 27, not macOS 12; the sample Khmer was written by Claude and has not been reviewed by a fluent reader.

## Results

| # | Experiment | Result |
| --- | --- | --- |
| E1 | Extract text from existing Khmer PDFs | **Garbled in every engine**, to different degrees. Core Text PDF: characters present but pre-base vowels and ្រ come out in visual order (`េរៀន` for `រៀន`). Chrome PDF: subscripts missing (`សាកល ង`). This is a property of how those PDFs were produced. |
| E2 | Search existing Khmer PDFs | **PDFKit weak**: Core Text PDF 2 of 4 words, Chrome PDF 0 of 4. **PDFium much better**: 6 of 7 and 7 of 7 words. |
| E3 | Added text as a FreeText annotation | Contents survive save/reopen exactly; renders correctly in PDFKit and PDFium. Font reports as Helvetica after reopening (viewers substitute a font that can show Khmer). Annotation text is not page text, so other viewers don't search it. Suitable for **editable work**, not for the delivered copy. |
| E4 | Added text drawn with normal Core Text into a redrawn page | Added line extracts in visual order (not searchable). **Redrawing the original page through Core Graphics damages the original page's text** (`ឯក#រ`). |
| E5 | Added text as glyph outlines + invisible logical-order text layer (`KhmerPDFText.draw`) | **Added line copies and searches correctly in PDFKit, pypdf, pdfminer and PDFium.** Looks identical to normal text. (Still drawn into a redrawn page, so the original text is damaged as in E4.) |
| E6 | E5 layers drawn from a `PDFPage` subclass and saved by PDFKit | Added line OK, but PDFKit also redraws the page, **damaging the original text** — same as E4. |
| E7 | E5 layers on a separate page, overlaid onto the **untouched** original with `qpdf --overlay` | **Original text byte-for-byte unchanged in extraction; added line OK in all three independent engines; renders correctly.** |

## Conclusions

1. **Delivered copies with added Khmer text:** use E5 (outlines + invisible logical text) and add it **without redrawing the original page** (E7). Apple frameworks cannot append content to an existing page, so this needs a PDF library: **qpdf** (Apache-2.0, C++; page overlay as form XObjects) passed. **PDFium** (BSD-3) could also do it.
2. **Editable work:** keep added text as FreeText annotations (E3) in the working file; flatten with (1) only for the delivered copy.
3. **Reading and search of existing Khmer PDFs:** PDFKit's search misses most Khmer words in these PDFs; PDFium finds nearly all. The Read workspace's search/copy should use **PDFium for text** if we want Khmer search to work on real documents. PDFKit can still display pages.
4. Many existing Khmer PDFs have broken text layers, whatever the engine. This supports offering "Recognize text (OCR)" even on digital PDFs whose extracted Khmer looks wrong; worth a "text layer looks damaged" check in the product.
5. The searchable-PDF export (OCR text layer) should use the same E5 text-layer technique (or Tesseract's own text layer — test in spike 02).

## Decision (30 Oct 2026): PDFium added, minimum raised to macOS 13

PDFium's prebuilt binaries require macOS 13 since July 2026 (last macOS 12 build: chromium/7920, 29 Jun 2026). The user chose to raise the app's minimum to macOS 13 and use current PDFium (vendored `chromium/8086`, see `Vendor/pdfium/SOURCE.md`) rather than pin an unpatched build.

Repeated through the app's own wrapper (`SlekPDF/Document/PDFium/PDFiumDocument.swift`), inside the sandboxed app (`SlekPDFTests/Spikes/PDFiumKhmerTests.swift`):
- Search: Core Text PDF 6/7 words, Chrome PDF 7/7 (PDFKit: 2/4, 0/4).
- Overlay + incremental save: original file bytes kept unchanged as the prefix of the output (28,535 → 79,839 bytes); added line copies/searches correctly in pypdf, pdfminer and PDFium; original text extraction unchanged; renders correctly.

## Options considered

Add a native PDF library to the app:

| Option | Gives | Cost |
| --- | --- | --- |
| **PDFium** (BSD-3; prebuilt universal macOS binaries exist) | Better Khmer extraction/search **and** page editing (overlay, object insertion) in one library | Larger binary (~5–7 MB); C API wrapper; check prebuilt minimum macOS = 12 or build ourselves |
| **qpdf** (Apache-2.0) | Overlay/merge/split without damaging content (proven here) | Does not fix search; still need PDFium (or our own) for Khmer text extraction |
| PDFKit only | No dependency | Khmer search fails on many real PDFs; added text can only be annotations, not flattened safely |

Recommendation: **PDFium** for text extraction/search and for writing delivered copies; keep PDFKit for on-screen page display and annotations. Next check before committing: a PDFium build for arm64 + x86_64 with minimum macOS 12, inside the sandbox, and repeat E2/E7 through PDFium's C API.
