import sys, json, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from score import scores, khmer
root = pathlib.Path("/Users/MAC/Desktop/Websites/SlekPDF/TestDocuments")
bench = pathlib.Path.home() / "Library/Containers/com.example.SlekPDF/Data/tmp/ocr-bench"
def latin(t): return sum(1 for c in t if c.isascii() and c.isalnum())
def is_english(b, conf): return b["t_eng"] and latin(b["t_eng"]) >= max(1, 0.6 * len(b["t_eng"].replace(" ", ""))) and b["t_eng_conf"] >= conf
def text(pages, choose):
    return "\f".join("\n".join(" ".join(choose(b) for b in line) for line in p["lines"]) for p in pages)
rules = {"D0 khmerocr": lambda b: b["k_text"]}
for c in (60, 75):
    rules[f"D1 eng>{c}"] = (lambda c: lambda b: b["t_eng"] if is_english(b, c) else b["k_text"])(c)
    for t in (0.8, 0.9):
        rules[f"D2 eng>{c} k<{t}->mix"] = (lambda c, t: lambda b: b["t_eng"] if is_english(b, c) else (b["t_mix"] if b["k_conf"] < t else b["k_text"]))(c, t)
    rules[f"D3 eng>{c} best"] = (lambda c: lambda b: b["t_eng"] if is_english(b, c) else (b["k_text"] if b["k_conf"] >= b["t_mix_conf"] / 100 else b["t_mix"]))(c)
data = {p.name.split(".")[0]: json.loads(p.read_text()) for p in sorted(bench.glob("*.kboxes.tess.json"))}
names = list(data)
print(f"{'rule':24}" + "".join(f"{n[:6]:>8}" for n in names) + f"{'mean':>8}")
for rn, rule in rules.items():
    row, vals = f"{rn:24}", []
    for n in names:
        ref = next(root.glob(f"*/{n}.txt")).read_text()
        v = scores(ref, text(data[n], rule))["cer_nows"] * 100
        vals.append(v); row += f"{v:>7.1f}%"
    print(row + f"{sum(vals)/len(vals):>7.1f}%")

print("\nper-page routing (English share of boxes ≥ s → Tesseract page, else D2 eng>75 k<0.9):")
d2 = rules["D2 eng>75 k<0.9->mix"]
for share in (0.3, 0.5, 0.7):
    row, vals = f"{'route s>=' + str(share):24}", []
    for n in names:
        ref = next(root.glob(f"*/{n}.txt")).read_text()
        tess_pages = (bench / f"{n}.current.txt").read_text().split("\f")
        out = []
        for p in data[n]:
            boxes = [b for line in p["lines"] for b in line]
            english = sum(1 for b in boxes if is_english(b, 60)) / max(1, len(boxes))
            out.append(tess_pages[p["page"]] if english >= share else "\n".join(" ".join(d2(b) for b in line) for line in p["lines"]))
        v = scores(ref, "\f".join(out))["cer_nows"] * 100
        vals.append(v); row += f"{v:>7.1f}%"
    print(row + f"{sum(vals)/len(vals):>7.1f}%")

print("\ncheaper: Tesseract only for boxes with KhmerOCR conf < g (others count as Khmer):")
for gate in (0.9, 0.95, 0.98):
    def fast(b, g=gate): return b if b["k_conf"] < g else {**b, "t_eng": "", "t_eng_conf": 0, "t_mix": b["k_text"], "t_mix_conf": 100}
    row, vals, checked = f"{'gate<' + str(gate):24}", [], 0
    total = 0
    for n in names:
        ref = next(root.glob(f"*/{n}.txt")).read_text()
        tess_pages = (bench / f"{n}.current.txt").read_text().split("\f")
        out = []
        for p in data[n]:
            boxes = [fast(b) for line in p["lines"] for b in line]
            checked += sum(1 for b in boxes if b["t_eng"] or b["t_mix_conf"] != 100); total += len(boxes)
            english = sum(1 for b in boxes if is_english(b, 60)) / max(1, len(boxes))
            out.append(tess_pages[p["page"]] if english >= 0.7 else "\n".join(" ".join(d2(fast(b)) for b in line) for line in p["lines"]))
        v = scores(ref, "\f".join(out))["cer_nows"] * 100
        vals.append(v); row += f"{v:>7.1f}%"
    print(row + f"{sum(vals)/len(vals):>7.1f}%   Tesseract runs on {checked}/{total} boxes")
