import sys, json, time, pathlib, io
import fitz
from PIL import Image
import khmerocr
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from score import scores

root = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2]); out.mkdir(exist_ok=True)
docs = ["digital/01_khmer_community_notice", "digital/03_bilingual_library_guide", "digital/04_khmer_training_notes",
        "scanned/06_khmer_clean_scan", "scanned/08_bilingual_dim_photo", "scanned/09_khmer_noisy_photocopy",
        "tables/11_bilingual_digital_invoice", "tables/12_khmer_digital_timetable", "tables/14_bilingual_scanned_scores",
        "tables/15_khmer_scanned_price_list"]
results = {}
for name in docs:
    pdf = fitz.open(root / f"{name}.pdf")
    pages = []
    start = time.time()
    for page in pdf:
        pix = page.get_pixmap(dpi=300)
        img = Image.open(io.BytesIO(pix.tobytes("png"))).convert("RGB")
        lines = khmerocr.detect(img)
        text_lines = []
        for line in lines:
            parts = []
            for box in line:
                x1, y1, x2, y2, cls, score = box
                if int(cls) == 0: continue
                crop = img.crop((max(0, int(x1)), max(0, int(y1)), int(x2), int(y2)))
                if crop.width < 2 or crop.height < 2: continue
                parts.append(khmerocr.recognize(crop)["text"])
            if parts: text_lines.append(" ".join(parts))
        pages.append("\n".join(text_lines))
    hyp = "\f".join(pages)
    (out / (pathlib.Path(name).name + ".khmerocr.txt")).write_text(hyp)
    ref = (root / f"{name}.txt").read_text()
    results[name] = {**scores(ref, hyp), "seconds": round(time.time() - start, 2)}
    print(name, results[name], flush=True)
(out / "khmerocr.json").write_text(json.dumps(results, indent=1))
