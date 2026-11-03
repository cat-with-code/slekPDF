import json, io, pathlib
import fitz
from PIL import Image
import khmerocr
root = pathlib.Path("/Users/MAC/Desktop/Websites/SlekPDF/TestDocuments")
bench = pathlib.Path.home() / "Library/Containers/com.example.SlekPDF/Data/tmp/ocr-bench"
for pdf_path in sorted(root.glob("*/[0-9][0-9]_*.pdf")):
    pdf = fitz.open(pdf_path)
    pages = []
    for number, page in enumerate(pdf):
        pix = page.get_pixmap(dpi=300)
        img = Image.open(io.BytesIO(pix.tobytes("png"))).convert("RGB")
        lines = []
        for line in khmerocr.detect(img):
            boxes = []
            for x1, y1, x2, y2, cls, score in line:
                if int(cls) == 0: continue
                x1, y1, x2, y2 = max(0, int(x1)), max(0, int(y1)), int(x2), int(y2)
                if x2 - x1 < 2 or y2 - y1 < 2: continue
                r = khmerocr.recognize(img.crop((x1, y1, x2, y2)))
                boxes.append({"x1": x1, "y1": y1, "x2": x2, "y2": y2, "k_text": r["text"], "k_conf": r["text_confidence"]})
            if boxes: lines.append(boxes)
        pages.append({"page": number, "width": img.width, "height": img.height, "lines": lines})
    (bench / f"{pdf_path.stem}.kboxes.json").write_text(json.dumps(pages, ensure_ascii=False))
    print(pdf_path.stem, sum(len(l) for p in pages for l in p["lines"]), "boxes")
