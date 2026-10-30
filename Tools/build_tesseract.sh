#!/bin/sh
# Builds Leptonica + Tesseract as universal (arm64 + x86_64) static libraries for macOS 13+
# into Vendor/tesseract. No image codecs, curl, archive or training tools: the app hands Tesseract
# raw rendered pixels, so none of those are needed.
#
# Usage: Tools/build_tesseract.sh <dir containing tesseract-5.5.3/ and leptonica-1.87.0/ sources>
# Needs: cmake (brew install cmake), Xcode command-line tools.
set -eu
SRC=$(cd "$1" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$SRC/build"
OUT="$ROOT/Vendor/tesseract"
TESSERACT=tesseract-5.5.3
LEPTONICA=leptonica-1.87.0
JOBS=$(sysctl -n hw.ncpu)

for ARCH in arm64 x86_64; do
  PREFIX="$WORK/$ARCH/install"
  COMMON="-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
    -DCMAKE_OSX_ARCHITECTURES=$ARCH -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR=$ARCH
    -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DCMAKE_FIND_ROOT_PATH=$PREFIX
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY"

  cmake -S "$SRC/$LEPTONICA" -B "$WORK/$ARCH/leptonica" $COMMON \
    -DSW_BUILD=OFF -DBUILD_PROG=OFF -DENABLE_ZLIB=OFF -DENABLE_PNG=OFF -DENABLE_GIF=OFF -DENABLE_JPEG=OFF \
    -DENABLE_TIFF=OFF -DENABLE_WEBP=OFF -DENABLE_OPENJPEG=OFF >/dev/null
  cmake --build "$WORK/$ARCH/leptonica" -j "$JOBS" >/dev/null
  cmake --install "$WORK/$ARCH/leptonica" >/dev/null

  cmake -S "$SRC/$TESSERACT" -B "$WORK/$ARCH/tesseract" $COMMON \
    -DSW_BUILD=OFF -DBUILD_TRAINING_TOOLS=OFF -DBUILD_TESTS=OFF -DDISABLE_ARCHIVE=ON -DDISABLE_CURL=ON \
    -DDISABLE_TIFF=ON -DLEPT_TIFF_RESULT=1 -DLEPT_TIFF_RESULT__TRYRUN_OUTPUT= -DGRAPHICS_DISABLED=ON -DOPENMP_BUILD=OFF -DENABLE_LTO=OFF \
    -DLeptonica_DIR="$PREFIX/lib/cmake/leptonica" >/dev/null
  cmake --build "$WORK/$ARCH/tesseract" -j "$JOBS" >/dev/null
  cmake --install "$WORK/$ARCH/tesseract" >/dev/null
  echo "built $ARCH"
done

rm -rf "$OUT/include" "$OUT/lib"
mkdir -p "$OUT/lib" "$OUT/include"
for LIB in libleptonica libtesseract; do
  A=$(find "$WORK/arm64/install/lib" -name "$LIB*.a" | head -1)
  X=$(find "$WORK/x86_64/install/lib" -name "$LIB*.a" | head -1)
  lipo -create "$A" "$X" -output "$OUT/lib/$LIB.a"
done
cp -R "$WORK/arm64/install/include/tesseract" "$WORK/arm64/install/include/leptonica" "$OUT/include/"
cp "$SRC/$TESSERACT/LICENSE" "$OUT/LICENSE-tesseract"
cp "$SRC/$LEPTONICA/leptonica-license.txt" "$OUT/LICENSE-leptonica" 2>/dev/null || cp "$SRC/$LEPTONICA/LICENSE" "$OUT/LICENSE-leptonica"
cat > "$OUT/include/module.modulemap" <<'EOF'
module Tesseract {
    header "tesseract/capi.h"
    link "tesseract"
    link "leptonica"
    link "c++"
    export *
}
EOF
lipo -info "$OUT/lib/"*.a
