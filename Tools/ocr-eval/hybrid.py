import sys, json, io, pathlib
import fitz
from PIL import Image
import khmerocr
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from score import scores, khmer
root = pathlib.Path("/Users/MAC/Desktop/Websites/SlekPDF/TestDocuments")
bench = pathlib.Path.home() / "Library/Containers/com.example.SlekPDF/Data/tmp/ocr-bench"
cache = pathlib.Path(__file__).parent / "hybrid_cache.json"
data = json.loads(cache.read_text()) if cache.exists() else {}
def latin(t): return sum(1 for c in t if c.isascii() and c.isalpha())
for pdf_path in sorted(root.glob("*/[0-9][0-9]_*.pdf")):
    name = pdf_path.stem
    if name in data: continue
    lines = json.loads((bench / f"{name}.current.lines.json").read_text())
    pdf = fitz.open(pdf_path)
    images = {}
    for line in lines:
        p = line["page"]
        if p not in images:
            pix = pdf[p].get_pixmap(dpi=300)
            images[p] = (Image.open(io.BytesIO(pix.tobytes("png"))).convert("RGB"), pdf[p].rect.height)
        img, ph = images[p]
        s = 300 / 72
        x1, x2 = line["x"] * s, (line["x"] + line["w"]) * s
        y1, y2 = (ph - line["y"] - line["h"]) * s, (ph - line["y"]) * s
        pad = 4
        crop = img.crop((max(0, int(x1) - pad), max(0, int(y1) - pad), int(x2) + pad, int(y2) + pad))
        r = khmerocr.recognize(crop)
        line["k_text"], line["k_conf"] = r["text"], r["text_confidence"]
    data[name] = lines
    cache.write_text(json.dumps(data, ensure_ascii=False))

def page_text(lines, choose):
    pages = {}
    for l in lines: pages.setdefault(l["page"], []).append(choose(l))
    return "\f".join("\n".join(pages[p]) for p in sorted(pages))

rules = {
  "R0 tesseract": lambda l: l["text"],
  "R1 script": lambda l: l["text"] if latin(l["text"]) > len(khmer(l["text"])) else l["k_text"],
}
for t in (0.85, 0.9, 0.95):
    rules[f"R2 script+k>{t}"] = (lambda t: lambda l: l["text"] if latin(l["text"]) > len(khmer(l["text"])) or l["k_conf"] < t else l["k_text"])(t)
for off in (0.0, 0.1):
    rules[f"R3 conf+{off}"] = (lambda off: lambda l: l["k_text"] if l["k_conf"] > l["confidence"] / 100 + off and latin(l["text"]) <= len(khmer(l["text"])) else l["text"])(off)
names = list(data)
print(f"{'rule':22}" + "".join(f"{n[:6]:>8}" for n in names) + f"{'mean':>8}")
for rn, rule in rules.items():
    row, vals = f"{rn:22}", []
    for n in names:
        ref = (next(root.glob(f"*/{n}.txt"))).read_text()
        v = scores(ref, page_text(data[n], rule))["cer_nows"] * 100
        vals.append(v); row += f"{v:>7.1f}%"
    print(row + f"{sum(vals)/len(vals):>7.1f}%")
