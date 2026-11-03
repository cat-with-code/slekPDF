# ONNX Runtime 1.31.1 (Microsoft, MIT)

- Download: https://github.com/microsoft/onnxruntime/releases/download/v1.31.1/onnxruntime-osx-arm64-1.31.1.tgz
- SHA-256 of the archive: 2e1344a1926ee50eb25b38153cb6992c3567515aef0e677a1a520a1798896d6f
- `lib/libonnxruntime.dylib` = the archive's `lib/libonnxruntime.1.31.1.dylib` (arm64 only — Microsoft no longer publishes an
  x86_64/universal macOS build). Headers: `onnxruntime_c_api.h`, `onnxruntime_ep_c_api.h`, `onnxruntime_error_code.h`.
- Not linked: `KhmerOCREngine` opens it with `dlopen` and uses the C API (`OrtGetApiBase`), so the universal app still runs
  on Intel Macs, where Khmer OCR falls back to Tesseract. Adding an x86_64 slice (`lipo`) enables KhmerOCR there unchanged.
- Embedded in Contents/Frameworks by the “Embed Libraries” phase (signed on copy).
