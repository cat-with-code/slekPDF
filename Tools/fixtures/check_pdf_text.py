#!/usr/bin/env python3
"""Independent text check: does a PDF's extractable text contain the expected Khmer lines?

Uses pypdf, pdfminer.six and PDFium via pypdfium2 (Chrome's engine; not Apple's PDFKit) so results reflect what other viewers will copy/search.
Usage: python check_pdf_text.py <lines.json> <file.pdf> [...]
Exit code 1 if any expected line is missing from any extractor.
"""
import json
import sys
import unicodedata

from pdfminer.high_level import extract_text as pdfminer_text
from pypdf import PdfReader
import pypdfium2 as pdfium


def squash(text: str) -> str:
    # Compare without whitespace/line breaks (extractors differ in spacing) and in NFC.
    return "".join(unicodedata.normalize("NFC", text).split())


def main() -> int:
    expected = json.load(open(sys.argv[1]))
    failed = False
    for path in sys.argv[2:]:
        extracted = {
            "pypdf": "\n".join(page.extract_text() or "" for page in PdfReader(path).pages),
            "pdfminer": pdfminer_text(path),
            "pdfium": "\n".join(page.get_textpage().get_text_range() for page in pdfium.PdfDocument(path)),
        }
        for engine, text in extracted.items():
            haystack = squash(text)
            missing = [line for line in expected if squash(line) not in haystack]
            status = "OK" if not missing else f"MISSING {len(missing)}/{len(expected)}"
            print(f"{path.split('/')[-1]:40} {engine:9} {status}")
            for line in missing:
                print(f"    expected: {line}")
            if missing:
                failed = True
                print("    got     : " + " | ".join(l for l in text.splitlines() if l.strip())[:400])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
