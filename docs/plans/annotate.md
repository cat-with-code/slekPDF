# Annotate workspace (Prototype 03) — plan

Figma: KM · 03 Annotate (164:6267). Canvas overlays: Highlight 125:26, Added Text Box 125:23, Comment Pin 122:*.
Inspector = Annotate Panel 157:188:
- Annotate Tools 125:135 (Add Khmer text T · Highlight H · Comment C; active tool Primary, Esc = none)
- Text Properties Panel 123:292 (bundled font Noto Sans Khmer, size, line spacing, B/I/U, align L/C/R as a radio group, colours Black/Blue/Red/Green/Orange as fixed document colours, X/Y in pt, honest note)
- Comment list (Comment Card 122:140: avatar, author, page · time, More; quote with an Annotation/Comment left rule; Reply / Resolve; states Selected / Editing / Resolved)

## Storage (decided by spike 01 + the editable-PDF decision)

- Source of truth: a Slek-owned model, keyed by the session's PageRef id so it follows reorder, rotate and delete.
  Undo goes through the same undo manager. `hasUnsavedChanges` includes annotations.
- **Text box** → FreeText annotation in saved work. `/Contents` holds the Unicode text. Private keys hold the properties
  (`FPDFAnnot_SetStringValue`, key `/SlekTextBox` = JSON `TextBoxStyle`). The appearance (`FPDFAnnot_SetAP`, /N) is
  CoreText-shaped Noto Sans Khmer drawn as filled glyph outlines. Never let a viewer generate the appearance from `/Contents`.
  Code: `PDFiumAnnotations.swift` (`addTextBox`, `textBoxes`, `render`).
  **Spike result (AnnotationKhmerSpikeTests):** "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ" (Bold 18) was saved and reopened.
  Rect, style and exact Unicode scalars all came back through PDFium. PDFKit reads the same `/Contents`.
  PDFium and PDFKit both draw ink matching CoreText's own drawing (≥ 98 % within 1 px at 3×), with coeng stacks correct.
  `qpdf --check` reports no errors. PDFKit draws the stored appearance; it does not regenerate it.
- **Highlight** → Highlight annotation. QuadPoints come from PDFium character boxes (rebuilt Khmer text), not PDFKit selection.
- **Comment** → Text (note) annotation with `/Contents`. The quoted source text goes in a private key.
- **Delivery copies (Export / flatten)** → spike E5/E7: outlines plus invisible Unicode text on an overlay page.
  The original page is never redrawn.
- Reopening a saved work file reads the annotations back into the model.

## On-screen drawing

Each model annotation is mirrored onto its PDFKit page as a `SlekPDFAnnotation` (Features/Annotate/AnnotationDisplay.swift).
This is a PDFAnnotation subclass whose `draw` is Slek's own: the same CoreText glyph outlines as the saved appearance,
plus highlight fills (multiply) and comment pins. So PDFKit handles position, zoom, rotation and printing,
but never lays out Khmer itself. PDFKit's own copies of saved Slek annotations are taken off the page on open
(matched by type + top-left corner, because PDFKit doesn't expose private keys). Popups PDFKit attaches to notes are removed.
Selection, dragging and text editing (steps 2–3) are Slek's own views over the PDFView.
Text editing uses a native text view (Khmer IME composition).
The single-key tools (V/T/H/C/Esc) are handled by the canvas and are inactive while a text field has focus.

## Build order (commit each)

1. ✅ Annotation model, save, reload, undo, unsaved-changes check, and the print filter updated
   (AnnotationModelTests; PageSource.open carries annotations, so Save work / Merge / Split include them).
   Test: a text box with "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ" goes through save → reopen. All properties must restore,
   PDFium must extract the exact Unicode, and an independent renderer must draw it correctly.
   If the independent render fails, stop and report.
2. Highlights and comments (inspector list, pins, Reply/Resolve).
3. Text boxes (overlay editing, Text Properties panel).

Khmer typing in text boxes can't be exercised from tests; report it as untested until it is tried by hand.
