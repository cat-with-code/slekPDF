#!/usr/bin/env python3
"""Independent check of the spike-03 sample.docx / sample.xlsx with python-docx and openpyxl.

Usage: python check_office.py <dir with sample.docx and sample.xlsx>
Exit code 1 on any failed expectation.
"""
import datetime
import sys
import unicodedata

import docx
import openpyxl

failures = []


def expect(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"  ({detail})"))
    if not ok:
        failures.append(label)


def nfc(text):
    return unicodedata.normalize("NFC", text or "")


def main(folder):
    d = docx.Document(f"{folder}/sample.docx")
    paragraphs = [p for p in d.paragraphs if p.text.strip()]
    expect("docx: heading 1 uses Heading1 style", paragraphs[0].style.name.lower() == "heading 1", paragraphs[0].style.name)
    expect("docx: Khmer paragraph text exact", nfc(paragraphs[1].text) == nfc("សាលារៀនបឋមសិក្សា ភូមិថ្មី។ ឯកសារនេះត្រូវបានពិនិត្យរួចហើយ — reviewed."), paragraphs[1].text)
    expect("docx: bold run kept as a separate editable run", any(r.bold and "ពិនិត្យ" in r.text for r in paragraphs[1].runs))
    expect("docx: subscripts/coeng preserved", "ស្ត្រី ក្រសួង ព្រះរាជាណាចក្រកម្ពុជា" in nfc(paragraphs[2].text), paragraphs[2].text)
    expect("docx: Khmer digits preserved", "០១២៣៤៥៦៧៨៩" in paragraphs[3].text and "៣០" in paragraphs[3].text)
    expect("docx: one real table, 4x6", len(d.tables) == 1 and len(d.tables[0].rows) == 4 and len(d.tables[0].columns) == 6)
    expect("docx: table header text", d.tables[0].cell(0, 2).text == "លេខសម្គាល់")
    expect("docx: leading-zero ID in table", d.tables[0].cell(1, 2).text == "007")

    wb = openpyxl.load_workbook(f"{folder}/sample.xlsx")
    expect("xlsx: sheet names", wb.sheetnames == ["ទំព័រ ២ · តារាង ១", "Invoice 202610 draft", "ទំព័រ ២ · តារាង ១ (2)"], wb.sheetnames)
    ws = wb.worksheets[0]
    expect("xlsx: source page note", ws["A1"].value == "Source: page 2", ws["A1"].value)
    expect("xlsx: header row is text", ws["B3"].value == "ឈ្មោះ" and ws["B3"].font.b)
    expect("xlsx: leading zeros kept as text", ws["C4"].value == "007" and ws["C5"].value == "0042" and ws["C6"].value == "000123",
           (ws["C4"].value, ws["C5"].value, ws["C6"].value))
    expect("xlsx: ID cells use text format @", ws["C4"].number_format == "@", ws["C4"].number_format)
    expect("xlsx: Khmer digits kept as text", ws["A4"].value == "១" and ws["A4"].data_type == "s", (ws["A4"].value, ws["A4"].data_type))
    expect("xlsx: riel amount is a number with riel format", ws["D4"].value == 12500 and "៛" in ws["D4"].number_format, (ws["D4"].value, ws["D4"].number_format))
    expect("xlsx: confirmed date is a real date", isinstance(ws["E4"].value, datetime.datetime) and ws["E4"].value.date() == datetime.date(2026, 10, 30), ws["E4"].value)
    expect("xlsx: ambiguous date stays text", ws["E5"].value == "១២/១០/២០២៦" and ws["E5"].data_type == "s")
    expect("xlsx: formula-looking text is not a formula", ws["F4"].value == "=SUM(A1:A3)" and ws["F4"].data_type == "s", (ws["F4"].value, ws["F4"].data_type))
    expect("xlsx: decimal number", ws["D6"].value == 3.75)
    expect("xlsx: empty cell left empty", ws["E6"].value is None)
    expect("xlsx: header frozen", ws.freeze_panes == "A4", ws.freeze_panes)
    print(f"\n{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
