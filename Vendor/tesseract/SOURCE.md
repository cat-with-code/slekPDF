# Tesseract + Leptonica (built from source)

- Tesseract 5.5.3 (https://github.com/tesseract-ocr/tesseract/archive/refs/tags/5.5.3.tar.gz, sha256 9218e62793116d42a9f6d14cd9348518b27f382096eea3d0f2d1a24616bb5884), Apache-2.0.
- Leptonica 1.87.0 (GitHub release asset leptonica-1.87.0.tar.gz, sha256 c73363397f96eb1295602bf44d708a994ad42046c791bf03ea0505d829bdb6a7), BSD-2.
- Built by `Tools/build_tesseract.sh <source dir>`: static, universal (arm64 + x86_64; NEON / AVX paths), minimum macOS 13.0, no image codecs, curl, archive or training tools.
- Models (`SlekPDF/Resources/tessdata-{fast,best}.bundle`): `khm` and `eng` from tessdata_fast / tessdata_best tag 4.1.0, Apache-2.0.
