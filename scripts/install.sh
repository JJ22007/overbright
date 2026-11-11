#!/usr/bin/env bash
# Build Overbright from source and install it for the current user.
#   bash scripts/install.sh
#
# Runs the tests, builds a release binary, installs Overbright.app into
# ~/Applications, links the `overbright` command into ~/.local/bin, and
# launches the app. Nothing needs sudo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
DEST="$HOME/Applications/Overbright.app"
BIN_DIR="$HOME/.local/bin"

"$ROOT_DIR/scripts/test.sh"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/Overbright"

# Ask a running copy to restore the display and quit before replacing it.
if pgrep -x Overbright >/dev/null; then
  pkill -TERM -x Overbright || true
  for _ in {1..50}; do pgrep -x Overbright >/dev/null || break; sleep 0.1; done
fi

mkdir -p "$HOME/Applications" "$BIN_DIR"
"$ROOT_DIR/scripts/bundle.sh" "$BINARY" "$DEST"
ln -sf "$DEST/Contents/MacOS/Overbright" "$BIN_DIR/overbright"
open "$DEST"

echo "installed: $DEST"
echo "command:   $BIN_DIR/overbright"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH. Add it, or call the command by its full path." ;;
esac
