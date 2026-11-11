#!/usr/bin/env bash
# Measure the light the built-in display really emits while pressing real
# brightness keys, with the Mac's camera (numbers only, no image is kept).
# Best in a dark room. About two minutes; the screen shows a white patch on
# black, and the display is restored at the end.
#   --out dir   where to write (default: outputs/light-check)
# Needs Overbright running with its brightness keys working
# (scripts/install.sh), and camera permission for "Overbright Light Meter"
# (macOS asks once). See AGENTS.md, "Measuring brightness".
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
# Build the camera meter app.
bash scripts/brightness-camera.sh --build-only
binary=.build/light-check
sources=(scripts/tools/BrightnessSampler.swift scripts/tools/light-check/main.swift)
if [[ ! -x $binary ]] || [[ -n $(find "${sources[@]}" -newer "$binary") ]]; then
  mkdir -p .build
  swiftc -O -swift-version 5 "${sources[@]}" -o "$binary"
fi
exec "$binary" "$@"
