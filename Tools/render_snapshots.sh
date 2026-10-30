#!/bin/sh
# Renders the main window in Khmer/English x Light/Dark at 1280x900 and copies the PNGs to build/snapshots/.
set -e
cd "$(dirname "$0")/.."
TEST_RUNNER_SNAPSHOT_DIR=1 xcodebuild test -scheme SlekPDF -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData -only-testing:SlekPDFTests/ShellSnapshotTests -quiet
mkdir -p build/snapshots
cp ~/Library/Containers/com.example.SlekPDF/Data/tmp/shell-snapshots/*.png build/snapshots/
ls build/snapshots
