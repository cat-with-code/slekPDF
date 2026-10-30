#!/bin/sh
# Writes the sample DOCX/XLSX in the app, checks them with python-docx/openpyxl and textutil, and renders Quick Look previews.
# PYTHON=/path/to/venv/bin/python (needs python-docx, openpyxl)
set -e
cd "$(dirname "$0")/../.."
xcodebuild test -scheme SlekPDF -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -only-testing:SlekPDFTests/OfficeExportSpikeTests -quiet
OUT=build/spike-output/office
rm -rf "$OUT" && mkdir -p "$OUT"
cp ~/Library/Containers/com.example.SlekPDF/Data/tmp/office-spike/* "$OUT/"
"${PYTHON:-python3}" Tools/fixtures/check_office.py "$OUT"
textutil -convert txt -stdout "$OUT/sample.docx" | head -5
(cd "$OUT" && qlmanage -t -s 1200 -o . sample.docx sample.xlsx >/dev/null 2>&1)
ls "$OUT"
