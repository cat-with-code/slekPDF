# Spike 03 — Word and Excel export without Office (30 Oct 2026)

Question: can the app write editable `.docx` and `.xlsx` with correct Khmer, without Microsoft Office or third-party libraries?

Run it: `PYTHON=<venv with python-docx, openpyxl> Tools/fixtures/run_office_spike.sh` → `build/spike-output/office/` (sample files + Quick Look renders).
Code: `SlekPDF/Conversion/` — `ConvertedDocument` (shared structured model: headings, paragraphs with runs, tables with typed cells and source page), `DOCXWriter`, `XLSXWriter`, `ZipWriter` (deflate via Apple's Compression framework, CRC-32, no dependencies).

## Results

Independent checks (python-docx, openpyxl): **21 / 21 pass.**

| Word (.docx) | Excel (.xlsx) |
| --- | --- |
| Heading styles (Heading 1–3, real outline levels) | One worksheet per table; Khmer sheet names; invalid characters removed, duplicates numbered, ≤ 31 chars |
| Khmer paragraphs exact (NFC), incl. subscripts and Khmer digits | "Source: page N" note above each table; header row bold and frozen |
| Bold/italic as separate editable runs | Leading-zero IDs (`007`, `0042`, `000123`) and Khmer digits stay text (format `@`) |
| Real table (4 × 6) with header row, leading zeros intact | Amounts as numbers with a riel format (`#,##0 "៛"`); decimals as numbers |
| Khmer marked as complex script (`w:cs` font, `w:bidi="km-KH"`) | Confirmed date as a real date; ambiguous `១២/១០/២០២៦` kept as text |
| | `=SUM(A1:A3)` written as text, never as a formula |

Other readers: Apple's `textutil` extracts the Word text exactly; Quick Look renders both files correctly with shaped Khmer.

Not yet checked: opening in **Microsoft Word and Excel** (installed on the dev Mac — needs a person to open the files and confirm no "repair" prompt, correct Khmer, editable cells), and on Windows Office.

## Findings and decisions to make

1. **Feasible without dependencies.** The writers are ~300 lines of Swift; no Office, no libxlsxwriter needed for this scope (paragraphs, runs, headings, simple tables, typed cells). Revisit if we need images, merged cells or charts — images are the next addition (DOCX `w:drawing` + media part).
2. **Fonts in exported files.** The files name Noto Sans Khmer and Inter. Recipients without those fonts get substitutes (Quick Look used a system Khmer font and Times). Options: (a) name fonts that ship with Windows and macOS (Khmer UI / Leelawadee UI on Windows, Khmer Sangam MN on Mac) with a fallback, (b) embed Noto Sans Khmer in the `.docx` (Word supports embedded fonts; Excel does not), (c) let the user choose. Needs a decision; recommendation: (a) by default, (b) as an option for Word.
3. **Values are only as good as the review step.** The writers never guess: text stays text unless the reviewer (or a reliable parser) confirmed a number or date. The UI must offer that review, as the setup doc requires.
4. Still to build for version 1: images in Word, simple merged headers in Excel, multi-page table joins (user-confirmed), warnings for unsupported layouts before saving.
