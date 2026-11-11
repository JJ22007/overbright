#!/usr/bin/env bash
# Read-only brightness logger for the built-in display. Builds once, then runs.
#   --interval ms   sample period (default 100)
#   --duration s    stop after this many seconds (default: until Ctrl-C)
#   --changes       print a row only when a value changed
#   --once          print one row and exit
#   --model m       how whiteNits is estimated: panel (default) or classic
# Columns and the luminance model are explained in scripts/tools/BrightnessSampler.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
binary=.build/brightness-log
sources=(scripts/tools/BrightnessSampler.swift scripts/tools/brightness-log/main.swift)
if [[ ! -x $binary ]] || [[ -n $(find "${sources[@]}" -newer "$binary") ]]; then
  mkdir -p .build
  swiftc -O -swift-version 5 "${sources[@]}" -o "$binary"
fi
exec "$binary" "$@"
