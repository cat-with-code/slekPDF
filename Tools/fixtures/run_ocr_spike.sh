#!/bin/sh
# Runs the Khmer OCR spike tests and copies the report and rendered scans to build/spike-output/ocr.
set -e
cd "$(dirname "$0")/../.."
xcodebuild test -scheme SlekPDF -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -only-testing:SlekPDFTests/TesseractKhmerSpikeTests -quiet || true
OUT=build/spike-output/ocr
rm -rf "$OUT" && mkdir -p "$OUT"
cp ~/Library/Containers/com.example.SlekPDF/Data/tmp/ocr-spike/* "$OUT/"
grep -v "→" "$OUT/report.txt"; cat "$OUT/memory.txt"
