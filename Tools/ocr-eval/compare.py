import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from score import scores
root = pathlib.Path("/Users/MAC/Desktop/Websites/SlekPDF/TestDocuments")
engines = [(name, pathlib.Path(folder), suffix) for name, folder, suffix in (a.split("=") for a in sys.argv[1:])]
docs = sorted(p.with_suffix("") for p in root.glob("*/[0-9][0-9]_*.pdf"))
print(f"{'document':38}" + "".join(f"{n+' all':>14}{n+' km':>12}" for n, _, _ in engines))
tot = {n: [0, 0, 0, 0] for n, _, _ in engines}
for d in docs:
    ref = (d.with_suffix(".txt")).read_text()
    row = f"{d.name:38}"
    for n, folder, suffix in engines:
        f = folder / f"{d.name}.{suffix}.txt"
        if not f.exists(): row += f"{'-':>14}{'-':>12}"; continue
        s = scores(ref, f.read_text())
        row += f"{s['cer_nows']*100:>13.1f}%" + (f"{s['cer_khmer']*100:>11.1f}%" if s['cer_khmer'] is not None else f"{'':>12}")
    print(row)
