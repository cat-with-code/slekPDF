#!/bin/sh
# Runs the PDFKit Khmer spike tests, copies their output to build/spike-output/pdfkit,
# and checks the exported PDFs with independent extractors (pypdf, pdfminer).
# Needs a Python with pypdf + pdfminer.six: PYTHON=/path/to/venv/bin/python Tools/fixtures/run_pdfkit_spike.sh
set -e
cd "$(dirname "$0")/../.."
xcodebuild test -scheme SlekPDF -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -only-testing:SlekPDFTests/PDFKitKhmerSpikeTests -quiet || true
OUT=build/spike-output/pdfkit
rm -rf "$OUT" && mkdir -p "$OUT"
cp ~/Library/Containers/com.example.SlekPDF/Data/tmp/pdfkit-spike/* "$OUT/"
cat "$OUT"/report-*.txt
echo "--- independent extraction of added text (E4, E5, E6) ---"
printf '["ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"]' > "$OUT/added-line.json"
"${PYTHON:-python3}" Tools/fixtures/check_pdf_text.py "$OUT/added-line.json" "$OUT/e4-flattened-coretext.pdf" "$OUT/e5-outlines-plus-text-layer.pdf" "$OUT/e6-pdfkit-overlay.pdf" || true
echo "--- E7: qpdf overlay of the E5 layers onto the untouched original ---"
qpdf SlekPDFTests/Fixtures/khmer-coretext.pdf --overlay "$OUT/e7-overlay-layer.pdf" -- "$OUT/e7-qpdf-overlay.pdf"
printf '%s' "$(cat SlekPDFTests/Fixtures/khmer-sample-lines.json | sed 's/]$/, "ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ"]/')" > "$OUT/original-plus-added.json"
echo "original fixture (baseline):"
"${PYTHON:-python3}" Tools/fixtures/check_pdf_text.py SlekPDFTests/Fixtures/khmer-sample-lines.json SlekPDFTests/Fixtures/khmer-coretext.pdf | grep -E "OK|MISSING" || true
echo "after overlay (original lines must match baseline, added line must be OK):"
"${PYTHON:-python3}" Tools/fixtures/check_pdf_text.py "$OUT/added-line.json" "$OUT/e7-qpdf-overlay.pdf" | grep -E "OK|MISSING" || true
"${PYTHON:-python3}" Tools/fixtures/check_pdf_text.py SlekPDFTests/Fixtures/khmer-sample-lines.json "$OUT/e7-qpdf-overlay.pdf" | grep -E "OK|MISSING" || true
