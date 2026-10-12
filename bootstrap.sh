#!/data/data/com.termux/files/usr/bin/bash
# One-line entry point — fetch and pipe into bash:
#
#   curl -fsSL https://raw.githubusercontent.com/jronminh/opencode-code-termux-native/main/bootstrap.sh | bash
#
# Clones (or fast-forwards) this repo to ~/opencode-code-termux-native, then
# runs install.sh from it. Any arguments are forwarded to install.sh. Safe to
# re-run.
set -euo pipefail

REPO_URL="https://github.com/jronminh/opencode-code-termux-native.git"
REPO_DIR="$HOME/opencode-code-termux-native"

command -v git >/dev/null 2>&1 || pkg install -y git

if [ -d "$REPO_DIR/.git" ]; then
  echo "updating existing clone at $REPO_DIR"
  git -C "$REPO_DIR" pull --ff-only \
    || echo "warning: could not update the clone — using the existing checkout" >&2
else
  echo "cloning to $REPO_DIR"
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi

exec bash "$REPO_DIR/install.sh" "$@"
