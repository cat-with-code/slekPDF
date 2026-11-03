"""CER per the TestDocuments README: NFC; whitespace-insensitive; and Khmer-only (U+1780–U+17FF, U+19E0–U+19FF)."""
import sys, unicodedata, json

def norm(t): return unicodedata.normalize("NFC", t)
def nows(t): return "".join(ch for ch in norm(t) if not ch.isspace())
def khmer(t): return "".join(ch for ch in norm(t) if 0x1780 <= ord(ch) <= 0x17FF or 0x19E0 <= ord(ch) <= 0x19FF)

def lev(a, b):
    if len(a) < len(b): a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]

def cer(ref, hyp): return lev(ref, hyp) / max(1, len(ref))

def scores(ref, hyp):
    return {"cer_nows": round(cer(nows(ref), nows(hyp)), 4), "cer_khmer": round(cer(khmer(ref), khmer(hyp)), 4) if khmer(ref) else None,
            "ref_khmer_chars": len(khmer(ref))}
