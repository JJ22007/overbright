#!/usr/bin/env bash
# Assemble and sign an app bundle from a built binary.
#   scripts/bundle.sh <binary> <destination.app>
#
# Signing, in order of preference:
#   1. SIGN_ID="Developer ID Application: You" (hardened runtime, timestamped)
#   2. the local identity created by scripts/setup-signing.sh (used automatically)
#   3. ad-hoc. Works, but macOS forgets the Accessibility grant on every rebuild.
set -euo pipefail

BINARY="$1"
APP="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="io.github.overbright"
LOCAL_ID="Overbright Local Signing"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/Overbright"
cp "$ROOT_DIR/Support/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/Overbright"

IDENTITY="${SIGN_ID:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$LOCAL_ID\""; then
  IDENTITY="$LOCAL_ID"
fi
if [[ -z "$IDENTITY" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "signed ad-hoc (run scripts/setup-signing.sh once to keep the Accessibility grant across rebuilds)"
elif [[ "$IDENTITY" == "$LOCAL_ID" ]]; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"
  echo "signed with: $IDENTITY"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
  echo "signed with: $IDENTITY"
fi
codesign --verify --strict "$APP"
