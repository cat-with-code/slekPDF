# PDFium (vendored binary)

- Source: https://github.com/bblanchon/pdfium-binaries release `chromium/8086` (PDFium 157.0.8086.0, published 2026-10-05), asset `pdfium-mac-univ.tgz`.
- Universal (arm64 + x86_64), minimum macOS 13.0 (`otool -l lib/libpdfium.dylib | grep minos`).
- Changes after download: install name set to `@rpath/libpdfium.dylib` (`install_name_tool -id`); `include/module.modulemap` added for Swift.
- Licence: BSD-3 (`LICENSE`); third-party notices in `licenses/` must ship with the app.
- To update: download a newer universal release (prefer one public for at least two weeks), repeat the two changes above, rerun the PDFium tests.
