#!/usr/bin/env bash
# Test, build both architectures, and zip a universal Overbright.app into outputs/.
# Set SIGN_ID to a Developer ID identity to sign for distribution.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
OUTPUT_DIR="$ROOT_DIR/outputs"
APP="$OUTPUT_DIR/Overbright.app"

"$ROOT_DIR/scripts/test.sh"
# Both architectures are packaged; the display's live EDR capability decides support.
swift build --scratch-path .build/universal-arm64 -c release --arch arm64
ARM_BINARY="$(swift build --scratch-path .build/universal-arm64 -c release --arch arm64 --show-bin-path)/Overbright"
swift build --scratch-path .build/universal-x86_64 -c release --arch x86_64
INTEL_BINARY="$(swift build --scratch-path .build/universal-x86_64 -c release --arch x86_64 --show-bin-path)/Overbright"

mkdir -p "$OUTPUT_DIR"
lipo -create "$ARM_BINARY" "$INTEL_BINARY" -output "$OUTPUT_DIR/Overbright-universal-binary"
"$ROOT_DIR/scripts/bundle.sh" "$OUTPUT_DIR/Overbright-universal-binary" "$APP"
rm "$OUTPUT_DIR/Overbright-universal-binary"

plutil -lint "$APP/Contents/Info.plist"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Overbright")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "not universal: $ARCHS" >&2; exit 1; }
rm -f "$OUTPUT_DIR/Overbright-universal.zip"
ditto -c -k --keepParent "$APP" "$OUTPUT_DIR/Overbright-universal.zip"

echo "$OUTPUT_DIR/Overbright-universal.zip"
