#!/usr/bin/env bash
# Hardware-independent checks. Safe to run anywhere, including CI.
#   1. logic tests for the pure model code (levels, key steps, config parsing)
#   2. every file in examples/ must pass `overbright check`
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
TEST_BINARY="$ROOT_DIR/.build/overbright-logic-tests"

mkdir -p "$ROOT_DIR/.build"
swiftc -swift-version 5 Sources/Overbright/Models/*.swift Tests/LogicTests/main.swift -o "$TEST_BINARY"
"$TEST_BINARY" | grep -v '^PASS' || true
"$TEST_BINARY" >/dev/null

swift build >/dev/null
APP_BINARY="$(swift build --show-bin-path)/Overbright"
for example in examples/*.json; do
  "$APP_BINARY" check "$example" >/dev/null || { echo "bad example config: $example" >&2; exit 1; }
done
echo "examples ok"
