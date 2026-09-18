#!/data/data/com.termux/files/usr/bin/bash
# One-line remote entry point: fetch this file and pipe it into bash, e.g.
#   curl -fsSL https://raw.githubusercontent.com/<owner>/opencode_termux_native/main/bootstrap.sh | bash
#
# Does the git clone/cd/install.sh dance from the README in one step: clones
# this repo to ~/opencode-code-termux-native (or fast-forwards an existing
# clone) and runs install.sh from it. Safe to re-run — same idempotency
# guarantees as install.sh itself, since that's exactly what this ends up
# calling.
#
# Any arguments are forwarded to install.sh, e.g.:
#   curl -fsSL .../bootstrap.sh | bash -s -- --with-adb-bridge
set -euo pipefail

# TODO: set the real repo URL before publishing this repo.
REPO_URL="https://github.com/C04-wq/opencode-code-termux-native.git"
REPO_DIR="$HOME/opencode-code-termux-native"

command -v git >/dev/null 2>&1 || pkg install -y git

if [ -d "$REPO_DIR/.git" ]; then
  echo "updating existing clone at $REPO_DIR"
  git -C "$REPO_DIR" pull --ff-only
else
  echo "cloning to $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
fi

exec bash "$REPO_DIR/install.sh" "$@"