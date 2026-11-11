#!/usr/bin/env bash
# Development loop: debug build into dist/Overbright.app, then run it.
#   scripts/dev.sh            build and open
#   scripts/dev.sh --logs     also stream the app's log
#   scripts/dev.sh --verify   open, then check it restores and exits on SIGTERM
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP="$ROOT_DIR/dist/Overbright.app"

wait_for_exit() {
  for _ in {1..50}; do pgrep -x Overbright >/dev/null || return 0; sleep 0.1; done
  return 1
}

if pgrep -x Overbright >/dev/null; then
  pkill -TERM -x Overbright || true
  wait_for_exit || { echo "a running Overbright did not restore and exit" >&2; exit 1; }
fi

swift build
"$ROOT_DIR/scripts/bundle.sh" "$(swift build --show-bin-path)/Overbright" "$APP"

case "$MODE" in
  run)
    open "$APP"
    ;;
  --logs|logs)
    open "$APP"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "io.github.overbright"'
    ;;
  --verify|verify)
    open --env OVERBRIGHT_SKIP_ACCESSIBILITY_PROMPT=1 "$APP"
    for _ in {1..50}; do pgrep -x Overbright >/dev/null && break; sleep 0.1; done
    pkill -TERM -x Overbright
    wait_for_exit || { echo "verification failed: app did not exit after SIGTERM" >&2; exit 1; }
    echo "verified: launches, then restores and exits on SIGTERM"
    ;;
  *)
    echo "usage: $0 [run|--logs|--verify]" >&2
    exit 2
    ;;
esac
