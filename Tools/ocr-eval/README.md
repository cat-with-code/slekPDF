# OCR evaluation (TestDocuments)

Scores Slek's OCR against the ground-truth `.txt` files of the TestDocuments set (kept outside the repo).
Method (TestDocuments README): NFC; character error rate = edit distance / reference length, whitespace ignored;
also on Khmer characters only (U+1780–U+17FF, U+19E0–U+19FF). Results and decisions: docs/spikes/04-khmerocr.md.

1. Copy the documents into the app container (sandboxed tests can only read there):
   `cp -R TestDocuments/{digital,scanned,tables} ~/Library/Containers/com.example.SlekPDF/Data/tmp/TestDocuments/`
2. App pipeline (writes `tmp/ocr-bench/<doc>.<engine>.txt`):
   `TEST_RUNNER_OCR_BENCH=1 xcodebuild test -scheme SlekPDF -destination 'platform=macOS' -only-testing:SlekPDFTests/OCRBenchmarkTests/testBenchmarkCurrentEngine`
   (add `TEST_RUNNER_OCR_BENCH_ENGINE=current` for the Tesseract-only path).
3. Score: `python3 Tools/ocr-eval/compare.py "now=$C/ocr-bench=current" "routed=$C/ocr-bench=routed"`
   with `C=~/Library/Containers/com.example.SlekPDF/Data/tmp`.

Reference KhmerOCR experiments (need `pip install git+https://github.com/seanghay/KhmerOCR` in a venv):
`run_khmerocr.py` (KhmerOCR alone), `hybrid.py` (KhmerOCR on Tesseract's lines), `kboxes.py` + the
`testBenchmarkTesseractOnKhmerOCRBoxes` test + `detector_rules.py` (KhmerOCR's boxes, per-box/per-page rules).
