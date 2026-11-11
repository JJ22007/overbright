#!/usr/bin/env bash
# Build (if needed) and run the camera light meter as its own small app, so
# macOS asks for camera permission once, for it alone.
#   scripts/brightness-camera.sh --out file.tsv --seconds N
#   scripts/brightness-camera.sh --build-only
# Records numbers only: how bright each camera frame is. No image is kept.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
app=.build/BrightnessCamera.app
src=scripts/tools/brightness-camera/main.swift
if [[ ! -x $app/Contents/MacOS/BrightnessCamera ]] || [[ $src -nt $app/Contents/MacOS/BrightnessCamera ]]; then
  mkdir -p "$app/Contents/MacOS"
  swiftc -O -swift-version 5 "$src" -o "$app/Contents/MacOS/BrightnessCamera"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.jj22007.overbright.camera-meter</string>
<key>CFBundleName</key><string>Overbright Light Meter</string>
<key>CFBundleExecutable</key><string>BrightnessCamera</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>Measures how bright the screen is, as numbers only. No picture is kept.</string>
</dict></plist>
PLIST
  identity="Overbright Local Signing"
  if security find-identity -p codesigning | grep -q "$identity"; then
    codesign --force --sign "$identity" "$app" >/dev/null 2>&1 || codesign --force --sign - "$app"
  else
    codesign --force --sign - "$app"
  fi
fi
[[ ${1:-} == --build-only ]] && exit 0
out=camera.tsv
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ ${args[i]} == --out ]]; then out=${args[i+1]}; args[i+1]=$(cd "$(dirname "$out")" && pwd)/$(basename "$out"); fi
done
open -n -W "$app" --args "${args[@]}"
