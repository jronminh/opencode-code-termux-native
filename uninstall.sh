#!/data/data/com.termux/files/usr/bin/bash
# Removes everything install.sh created. Safe to re-run (every step is a
# no-op if there's nothing left to remove).
#
# Deliberately does NOT remove — with or without --full:
#   - the opencode binary + musl libs at ~/.opencode/ (that IS the app; this
#     repo only wires it up). Keeping it means a future install.sh run
#     doesn't re-download ~194MB.
#   - ~/.config/opencode/opencode.jsonc itself (your config is user data) —
#     only OUR autoupdate key is stripped from it.
#   - the Termux packages install.sh installed (curl, jq, patchelf, ...).
#   - this cloned repo directory — that's your call, see the final message.
#
# Usage:
#   uninstall.sh        remove the wiring, keep the app + libs
#   uninstall.sh --full also remove ~/.opencode/opencode-native ($DEST)
#                       and the rotation backups kept under ~/.opencode/
set -euo pipefail

FULL=0
case "${1:-}" in
  "") ;;
  --full) FULL=1 ;;
  *) echo "usage: uninstall.sh [--full]" >&2; exit 2 ;;
esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="uninstall.sh"
TOTAL=4
[ "$FULL" = "1" ] && TOTAL=$((TOTAL + 1))
# shellcheck source=lib.sh
source "$REPO_DIR/lib.sh"

OPENCODE_DIR="$HOME/.opencode"
DEST="$OPENCODE_DIR/opencode-native"
CONFIG_DIR="$HOME/.config/opencode"
CONFIG="$CONFIG_DIR/opencode.jsonc"
ENV_NOTES="$CONFIG_DIR/environment.md"
BIN_DIR="$PREFIX/bin"

# Only remove $BIN_DIR/opencode if it's actually our generated wrapper (it
# carries a marker line) — never clobber a foreign opencode the user has.
remove_wrapper() {
  if [ -e "$BIN_DIR/opencode" ]; then
    if grep -q "opencode-code-termux-native wrapper" "$BIN_DIR/opencode" 2>/dev/null; then
      rm -f "$BIN_DIR/opencode"
    else
      echo "note: $BIN_DIR/opencode isn't this repo's wrapper — leaving it in place" >&2
    fi
  fi
  rm -f "$BIN_DIR/termux-update-opencode"
}

# Strip OUR edits from the global config: the autoupdate-off key and the
# `instructions` pointer to environment.md (only if that entry is exactly
# ours). Everything else the user may have set is preserved, and the file is
# backed up first.
remove_config_entries() {
  [ -e "$CONFIG" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cp -f "$CONFIG" "$CONFIG.bak"
  local tmp; tmp=$(mktemp)
  jq --arg notes "$ENV_NOTES" '
    del(.autoupdate)
    | .instructions = ((.instructions // []) | map(select(. != $notes)))
    | if (.instructions | length) == 0 then del(.instructions) else . end
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

# Remove only our marked block from the global environment notes (any user
# content outside the markers is preserved).
remove_env_notes() {
  env_notes_remove "$ENV_NOTES"
}

remove_staged() {
  if [ "$FULL" = "1" ]; then
    rm -rf "$DEST"
  else
    rm -f "$DEST"/install.sh "$DEST"/download.sh "$DEST"/lib.sh "$DEST"/environment.md.template "$DEST"/.opencode-native.lock
  fi
}

remove_backups() {
  rm -f "$OPENCODE_DIR/opencode.prev"
}

echo "${BOLD}opencode-code-termux-native${RESET} — uninstalling"
echo

step "removing the opencode wrapper + termux-update-opencode"     remove_wrapper
step "removing our autoupdate/instructions entries from config"   remove_config_entries
step "removing our section from environment.md"                   remove_env_notes
if [ "$FULL" = "1" ]; then
  step "removing ~/.opencode/opencode-native + rotation backups"  remove_staged
  step "removing the prev-binary rotation backup"                 remove_backups
else
  step "removing staged scripts (keeping the app + libs cached)"  remove_staged
fi

rm -f "$LOG"
trap - ERR
echo
echo "${GREEN}${BOLD}uninstall complete${RESET}"
echo "  The opencode wrapper and termux-update-opencode are gone; our"
echo "  autoupdate/instructions keys were stripped from opencode.jsonc, and"
echo "  our section was removed from environment.md."
echo
if [ "$FULL" = "1" ]; then
  echo "  $DEST and the rotation backup under ~/.opencode/ were removed"
  echo "  too. The app binary + musl libs at ~/.opencode/ are KEPT —"
  echo "  delete them yourself if you also want opencode gone:"
  echo "    rm -rf $(shortp "$OPENCODE_DIR")/opencode $(shortp "$OPENCODE_DIR")/ld-musl-aarch64.so.1"
  echo "    rm -f $(shortp "$OPENCODE_DIR")/libc.musl-aarch64.so.1 $(shortp "$OPENCODE_DIR")/libstdc++.so.6 $(shortp "$OPENCODE_DIR")/libstdc++.so.6.runtime $(shortp "$OPENCODE_DIR")/libgcc_s.so.1"
else
  echo "  The app + musl libs stay at $OPENCODE_DIR (that's the app"
  echo "  itself, ~194MB — a future install.sh reuses it instead of"
  echo "  re-downloading). Run ${BOLD}bash uninstall.sh --full${RESET} to also"
  echo "  remove $(shortp "$DEST") and the rotation backup."
fi
echo
echo "  Open a NEW Termux session (or run: exec bash) so the removed wrapper takes effect."
