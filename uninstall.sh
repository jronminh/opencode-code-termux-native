#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
HOME_DIR="${HOME:?HOME is not set}"
PREFIX_DIR="${PREFIX:?Run this from Termux}"
OPENCODE_DIR="$HOME_DIR/.opencode"
CONFIG="$HOME_DIR/.config/opencode/opencode.jsonc"
rm -f "$PREFIX_DIR/bin/opencode"
rm -rf "$OPENCODE_DIR/runtime" "$OPENCODE_DIR/runtime.prev" "$OPENCODE_DIR/opencode" "$OPENCODE_DIR/opencode.prev" "$OPENCODE_DIR/version" "$OPENCODE_DIR/opencode-native"
if [ -f "$CONFIG.opencode-code-termux-native.bak" ]; then
  mv "$CONFIG.opencode-code-termux-native.bak" "$CONFIG"
elif [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq 'del(.autoupdate)' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
fi
echo "OpenCode native installation removed."
