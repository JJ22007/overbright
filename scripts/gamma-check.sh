#!/usr/bin/env bash
# Measure whether the gamma table changes the light the built-in display
# emits, with the Mac's camera (numbers only, no image is kept). Needs a dark
# room: it stops and says so if the camera mostly sees room light. The screen
# shows a white patch on black; the gamma table, the config file and the boost
# are put back at the end.
#   --out dir   where to write (default: outputs/gamma-check)
#   --force     run even if the room is too bright (to look, not to conclude)
# Needs Overbright running (scripts/install.sh) and camera permission for
# "Overbright Light Meter" (macOS asks once). See AGENTS.md, "Measuring brightness".
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
bash scripts/brightness-camera.sh --build-only
binary=.build/gamma-check
sources=(scripts/tools/BrightnessSampler.swift scripts/tools/CameraRoom.swift scripts/tools/gamma-check/main.swift)
if [[ ! -x $binary ]] || [[ -n $(find "${sources[@]}" -newer "$binary") ]]; then
  mkdir -p .build
  swiftc -O -swift-version 5 "${sources[@]}" -o "$binary"
fi
exec "$binary" "$@"
