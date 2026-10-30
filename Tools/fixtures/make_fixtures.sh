#!/bin/sh
# Regenerates the Khmer test PDFs from Tools/fixtures/khmer-sample-lines.json using two independent PDF producers.
set -e
cd "$(dirname "$0")/../.."
OUT=SlekPDFTests/Fixtures
swift Tools/fixtures/make_coretext_pdf.swift Tools/fixtures/khmer-sample-lines.json SlekPDF/Resources/Fonts "$OUT/khmer-coretext.pdf"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --no-pdf-header-footer \
  --allow-file-access-from-files --print-to-pdf="$PWD/$OUT/khmer-chrome.pdf" "file://$PWD/Tools/fixtures/khmer-sample.html" 2>/dev/null
cp Tools/fixtures/khmer-sample-lines.json "$OUT/khmer-sample-lines.json"
ls -l "$OUT"
