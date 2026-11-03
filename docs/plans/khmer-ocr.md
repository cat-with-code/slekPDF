# Khmer OCR workspace (Prototype 04, 12, 39, 41) — plan

Figma (Prototype page): KM · 04 Khmer OCR review (164:6281), KM · 12 Recognizing text… (164:6391),
KM · 39 Recognize these pages again? (408:48719), KM · 41 OCR · invalid page range (410:50805).
Components: Recognition Settings 129:231 (Ready / Running), OCR Review Panel 129:111 (Reviewing / All reviewed),
Uncertain Region 129:14 (Default dashed #A25913 on #F3C498 / Active #3A1EF1 on #C0B7FB / Reviewed #087D17 on #9FF9A7).

## Model and storage

- `OCRLine` (bounds in the source page's own PDF space, recognized text, confidence 0–100, correction, reviewed) and
  `OCRPage` live in `PDFiumAnnotations.swift`; `DocumentSession.ocrResults[PageRef.ID]` (follows reorder / rotate /
  delete), undoable via `setOCR`, counted in `hasUnsavedChanges`.
- Saved work: a hidden Text annotation at the page origin with `/SlekOCR` (JSON) and `/Contents` (plain text);
  stripped and rewritten on every save like the other Slek annotations; read back on open, PDFKit's copy removed.
- Engines: KhmerOCR (detector + Khmer recognizer) routed with Tesseract per page and per box — docs/spikes/04-khmerocr.md
  (mean CER on TestDocuments 17.3 % → 8.7 %).
- Recognition: PDFium renders the page at 300 ppi with the PageRef's turn → `OCRWorker` (Tesseract best, Sauvola,
  own serial queue, engine kept per language, 60 s per page, cancel flag) → line boxes mapped back with
  `FPDF_DeviceToPage`. Lines below 80 confidence are “Uncertain regions” (a hint, not a correctness score).

## Build order (commit each)

1. ✅ Recognition (OCRWorkspaceTests; snapshots 04-ocr-settings, 12-recognizing, 39-recognize-again, 41-invalid-range):
   Recognition settings inspector (language, page scope, custom range + 41 error, skip pages with usable text,
   Recognize text / Running progress with Cancel, Review export options → Export), 12 dialog (Run in background /
   Cancel; finished pages are kept), 39 when reviewed corrections would be replaced, Tools ▸ Recognize Text… /
   Review OCR open the workspace. Open points:
   - “Correct orientation / deskew” is shown disabled: needs Tesseract's `osd` model (not bundled).
   - Disabled primary button is faded accent, Figma shows grey (DSButton behaviour, all screens).
   - Recognized text is not yet used by Search / Copy / Export (Export step), and no status-bar spinner yet.
   - Draft Khmer: All text, Reviewed, All N items reviewed, time-left variants, deskew note, finish/stop/no-text toasts.
2. ✅ Review (OCRWorkspaceTests review cases; snapshots 04-ocr-review, 04-ocr-all-reviewed): side-by-side canvas (Source page with numbered Uncertain Regions | Recognized text with the OCR Review
   Panel): Review text filter (Uncertain regions / All text), Item n of N with Previous / Next, confidence badge,
   Correct selected text, Skip / Mark reviewed, All reviewed state with Review export options.
   Items run across the document in page order (Next moves to the item's page); Mark reviewed (↩, Keyboard
   Shortcuts) keeps the text as a correction only when it changed, then goes to the next unreviewed item; Skip wraps;
   clicking a region selects it; all reviewed = every region green. Open points:
   - Region fills are 45 % translucent (Figma shows them solid over placeholder bars) so the real text stays readable.
   - The canvas shows one page fitted to the column; the page pill's zoom buttons do nothing here yet.
   - Draft Khmer: “No uncertain regions on the recognized pages.”

## Backlog (parked 3 Nov 2026, in this order)

1. Small-box fixes: lone ។ / ៖ / ) boxes are read as digits by the English check (9, 3, ២) — keep KhmerOCR's reading
   for 1–2 character boxes in Khmer lines; re-read unsure boxes at another scale or margin; drop text boxes inside the
   detector's figure regions (pictures).
2. Limon / ABC → Unicode converter (own table; existing converters are LGPL or unlicensed): exact text for legacy-font
   PDFs without OCR.
3. Fine-tune KhmerOCR on fonts it misreads (Muol titles, Roman numerals in Khmer lines); measure real PDFs first.
4. Spelling hints in Review (needs a licence-compatible Khmer word list and a Figma design).
