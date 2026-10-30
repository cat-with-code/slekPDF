# Spike 02 — Khmer OCR with Tesseract (30 Oct 2026)

Question: can Tesseract run offline inside the sandboxed macOS 13+ app on both architectures, and how well does it read Khmer?

Run it: `Tools/fixtures/run_ocr_spike.sh` (report and rendered scans land in `build/spike-output/ocr/`).
Build: `Tools/build_tesseract.sh <dir with tesseract-5.5.3/ and leptonica-1.87.0/>` → `Vendor/tesseract` (static, universal, macOS 13.0; sources and hashes in `Vendor/tesseract/SOURCE.md`).
Wrapper: `SlekPDF/OCR/TesseractEngine.swift` (C API; Sauvola thresholding option, deadline, cancellation; `OCRPreprocessor.clean` = median filter + Core Image document enhancer).

**Limits:** one synthetic page (the six fixture lines, one font, typeset then rendered), so these are best-case numbers, not a benchmark. No real scans, handwriting, tables or multi-column pages yet. Expected text was written by Claude, not reviewed by a fluent reader. Intel numbers are under Rosetta on Apple Silicon, not on an Intel Mac.

## Results — character error rate (CER, NFC, whitespace ignored)

| Page | fast + Otsu | fast + Sauvola | best + Otsu | **best + Sauvola** |
| --- | --- | --- | --- | --- |
| Clean, 300 dpi | 2.2% | 2.2% | 2.2% | **2.2%** |
| Low resolution, 150 dpi | 8.2% | 4.9% | 5.5% | **2.2%** |
| Blurred | 7.1% | 7.1% | 2.2% | **2.2%** |
| Skewed 2° | 8.2% | 3.3% | 3.3% | **3.3%** |
| Grey grainy paper | fails (stopped at 10 s) | 74% | fails (stopped at 10 s) | 70% |
| Grey grainy paper + clean-up | 8.2% | 4.4% | 8.2% | **4.4%** |
| Clean + clean-up (no regression) | 2.2% | 2.2% | 2.2% | **2.2%** |

The remaining errors are the same on every page: the Khmer digits `៣០` read as Latin `mo`, the middle dot `·` and the riel sign `៛` misread. Khmer letters, subscripts (្ត ្រ ្ម ្ប), pre-base vowels and the numerals ០–៩ on their own line were read correctly.

## Speed and memory (OCR alone, best + Sauvola, A4 at 300 dpi)

| | Apple Silicon (dev Mac) | Intel build under Rosetta |
| --- | --- | --- |
| Load models | 65 ms, +100 MB | 139 ms, +100 MB |
| Recognize one page | ~0.65 s | ~1.05 s |
| Peak footprint | ~180 MB, stable over 5 runs | ~215 MB, stable |

The Core Image clean-up step pushed the test process above 1 GB (GPU/intermediate buffers); it needs a lighter implementation (vImage, or a limited CIContext with tiling) before it ships.

## Conclusions

1. **Feasible.** Tesseract 5.5.3 builds universal for macOS 13, links statically, runs offline inside the App Sandbox from bundled models, on both architectures.
2. **Ship `best` models with Sauvola thresholding**, and clean up grey/grainy scans before OCR. `best` adds 18 MB over `fast` but is clearly more robust (low-res, blur). Remove `tessdata-fast.bundle` from the app once the choice is confirmed on real scans.
3. **Always run OCR with a deadline/cancel** — a bad page otherwise burns 20–40 s producing garbage. The wrapper supports both.
4. **Mixed Khmer digits/symbols need attention**: `៣០` → `mo`, `៛` lost. Try `khm` alone vs `khm+eng`, per-region language choice, and a post-correction for digit look-alikes; matters for invoices and tables (Excel export).
5. Confidence tracked CER (clean ≈ 90, failed page ≈ 24–44), so it is a usable signal for "please review" highlighting — not a correctness score.

## Next checks

- Real scans from the user (phone photos, office scanner, photocopies) with fluent-reviewed ground truth; report CER by category.
- Lighter clean-up; automatic choice of when to clean up.
- Searchable PDF from OCR: use the spike-01 text-layer technique (outlines not needed — the scan is the visible layer) and compare with Tesseract's own PDF renderer.
- Run inside a helper process with a memory cap, per the architecture notes.
