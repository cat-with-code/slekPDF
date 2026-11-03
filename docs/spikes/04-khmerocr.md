# Spike 04 — KhmerOCR + Tesseract routing (3 Nov 2026)

Question: does KhmerOCR (github.com/seanghay/KhmerOCR, MIT; detector + Khmer recognizer trained on 3 M lines / 800+ fonts,
ONNX) improve Slek's OCR over Tesseract (spike 02), and how should the two be combined?

Data: the user's TestDocuments set (15 synthetic PDFs, 18 pages, ground-truth `.txt`), every page rendered at 300 dpi and
OCR'd (digital PDFs too, as clean “scans”). Score: NFC, CER with whitespace ignored (Tools/ocr-eval).

## Findings

1. KhmerOCR alone reads Khmer very well but is **Khmer-only** (no Latin letters, digits, spaces, `: / |`): English lines
   come out as Khmer gibberish (bilingual pages 59–78 % CER). Tesseract is far better on English, on skewed / low-res
   English scans, and on some layouts.
2. KhmerOCR's recognizer on **Tesseract's lines** helps a little (mean 17.3 → 15.4 %): Tesseract's line finding fails on
   noisy Khmer pages.
3. KhmerOCR's **detector** + per-box choice + **per-page routing** is the winner (shipped):
   - each KhmerOCR box is also read by Tesseract (English, one line);
   - a page where ≥ 80 % of boxes are confidently English (≥ 60) is read by Tesseract whole (its layout is better there);
   - otherwise each box keeps Tesseract's English reading when it is sure (≥ 75), else KhmerOCR's reading, or Tesseract
     Khmer + English for that box when KhmerOCR is unsure (< 0.9);
   - text boxes lying ≥ 80 % inside a larger one are dropped (else words are read twice).

| Document | Tesseract (before) | Routed (now) |
| --- | --- | --- |
| 01 Khmer notice | 20.7 % | 1.9 % |
| 03 Bilingual guide | 3.8 % | 2.4 % |
| 04 Khmer notes | 22.8 % | 2.8 % |
| 06 Khmer clean scan | 6.3 % | 2.6 % |
| 08 Bilingual dim photo | 2.5 % | 2.7 % |
| 09 Khmer noisy photocopy | 50.9 % (Khmer 41.3 %) | 22.9 % (Khmer 8.7 %) |
| 11 Bilingual invoice | 29.0 % | 6.2 % |
| 12 Khmer timetable | 34.8 % | 2.6 % |
| 15 Khmer price list | 29.2 % | 26.6 % |
| 02, 05, 07, 10 English; 13 English table; 14 bilingual scan | unchanged (Tesseract) | |
| **Mean, 15 documents** | **17.3 %** | **8.7 %** |

Time: 1.2–6.5 s per document on Apple Silicon (most of it Tesseract re-reading boxes for the English check).

## Packaging

- ONNX Runtime 1.31.1 (`Vendor/onnxruntime`, MIT): Microsoft ships macOS **arm64 only**. It is embedded but not linked;
  `KhmerOCREngine` opens it with `dlopen`, so the universal app runs on Intel Macs with the Tesseract path. An x86_64 slice
  (built from source) can be added with `lipo` later. +44 MB app size.
- Models `SlekPDF/Resources/khmerocr.bundle` (det 10.9 MB, rec 13.8 MB), checksums in `Vendor/khmerocr/SOURCE.md`.
- Licences in Resources/Licenses and Privacy & Licenses.

## Open

- Still weak: 13 English inventory (table reading order, 40 %), 14 bilingual scanned scores (16 %), 15 price list (27 %),
  09 noisy photocopy (23 %, mostly the English footer and digits).
- Latin digits/punctuation inside Khmer lines depend on the Tesseract fallback.
- The synthetic set uses two Khmer fonts; real scans (Khmer OS, Moul, phone photos) still need measuring.

## Khmer normalisation (khmernormalizer, 3 Nov 2026)

Problem reported: text copied from recognized images broke apart, looked like Thai, or became unreadable after pasting.
Causes and fixes:
- Out-of-order Khmer (vowel before a subscript, ្រ before another subscript, េ + ា / េ + ី, doubled marks) renders with
  dotted circles elsewhere. `KhmerNormalizer` (Swift port of the Khmer parts of github.com/seanghay/khmernormalizer, MIT,
  whose core is SIL International's khnormal, MIT) now normalises OCR output (both engines), Copy and Export text.
  Matches the reference implementation on the test vectors (KhmerNormalizerTests). Not ported: Latin accent stripping,
  quote/emoji/URL rewriting, spelling corrections, “។ល។” → ៘.
- Thai text comes from a text layer another program put in the PDF (Khmer misread as Thai). Copy on a page Slek
  recognized now uses Slek's OCR text, and “Skip pages with usable text” no longer counts a layer that is mostly another
  script (less than 80 % Khmer/Latin letters), so such pages are recognized again.
- On the TestDocuments set normalising does not change the CER (8.69 %); the routed output is already in standard order.

## Real PDFs: unreadable text layers (3 Nov 2026)

Reported: after the KhmerOCR integration, Export/Copy gave gibberish, and OCR “only recognized the first page”. Measured
on a real 116-page government PDF (not in the repo) and a one-page digital CV:
- Most pages draw Khmer in **legacy fonts** (Limon: `LimonR1`, `LimonS1`, `LmnTTFantBig`, `KhmM2`) at Latin code
  points, so the text layer reads “pøaksBaØacracr”. Slek counted it as usable English text: “Skip pages with usable
  text” skipped every page but the image-only cover, and Export/Copy used the gibberish.
- Other pages use KhmerOS with a **broken glyph-to-Unicode map** (“ង្លខកូដ” for លេខកូដ, marks with no consonant).
- A digital CV was skipped (correctly) but the toast said “No text was found on these pages”.

Fixes: `PDFiumService.textLayer` classifies each page as none / usable / unreadable. Unreadable = any legacy-font run
(≥ 5 characters), or ≥ 1 % orphan Khmer marks / subscripts with no consonant (well-made Khmer PDFs: 0; broken: 1.4–4 %),
or ≥ 3 % “ង្”. Unreadable pages are recognized even with Skip on; Export lists them under “Pages without text”; Copy
gives OCR text or asks to recognize the page. On that PDF 115 of 116 pages are now recognized (the other has only
sign codes in Arial); every TestDocuments and fixture page stays usable. OCR also drops mark-only lines (a round
seal's text, ruled lines) and attaches a box that starts with a Khmer vowel/sign to the box before it. TestDocuments
mean CER 8.69 → 8.59 % (14 bilingual scanned scores 16 → 14.7 %).

Not done: converting Limon/ABC text to Unicode directly (exact, no OCR). The known converters are LGPL
(KhmerConverter) or unlicensed; a clean-room table would be needed.
