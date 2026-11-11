#!/usr/bin/env bash
# Drive the built-in display through a scenario with `overbright key up|down`
# and measure every step: samples every 20 ms, screen frames of the indicator
# area, and a per-press report (direction, time to 90%, overshoot).
#   --scenario full|boost|native   what to press (default: full)
#   --out dir                      where to write (default: outputs/brightness-check)
#   --no-frames                    skip screen frames
#   --model panel|classic          luminance model (default: panel)
# Changes the display's brightness while it runs and puts it back at the end.
# Needs Overbright running (scripts/install.sh) and, for frames, permission to
# record the screen.
set -euo pipefail
cd "$(dirname "$0")/.."
binary=.build/brightness-check
sources=(scripts/tools/BrightnessSampler.swift scripts/tools/brightness-check/main.swift)
if [[ ! -x $binary ]] || [[ -n $(find "${sources[@]}" -newer "$binary") ]]; then
  mkdir -p .build
  swiftc -O -swift-version 5 "${sources[@]}" -o "$binary"
fi
exec "$binary" "$@"
