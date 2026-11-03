# KhmerOCR (Seanghay Yath, MIT)

- Source: https://github.com/seanghay/KhmerOCR at commit 68c2c72efee0f3ad4c6d650b550abd19bb10d73c (2026-02-12)
- Models in `SlekPDF/Resources/khmerocr.bundle` (from the Python package `khmerocr/`):
  - `det.onnx` (text/figure detector, 1024×1024 input) — SHA-256 61fb440d2eecd561a4d5ccd41e3be5a14a882643f1ac0e1f05f9f53ff9098e67
  - `rec.onnx` (line recognizer, 32 px high, Khmer CTC + font style) — SHA-256 931e3c960815a6119731d63759eac2ef800318bf131b8a92fecdb580fbbf1e65
- Pre/post-processing re-implemented in Swift (`SlekPDF/OCR/KhmerOCREngine.swift`) from the reference Python
  `khmerocr/__init__.py` (letterbox, NMS 0.45, line grouping, CTC greedy decode, token offset 3).
- Khmer only (no Latin letters, digits or spaces in its alphabet); Slek routes Latin text to Tesseract.
