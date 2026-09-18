#!/data/data/com.termux/files/usr/bin/bash
# Removes everything install.sh created. Safe to re-run (every step is a
# no-op if there's nothing left to remove).
#
# Deliberately does NOT remove — with or without --full:
#   - the opencode binary + musl libs it also installs/maintains at
#     ~/.opencode/ (that IS the app; this repo only wires it up). Keeping
#     it means a future install.sh run doesn't re-download ~194MB.
#   - ~/.config/opencode/opencode.json itself (your config is user data) —
#     only OUR autoupdate / instructions-pointer keys are stripped from it.
#   - the Termux packages install.sh installed (curl, jq, patchelf, ...) —
#     they're shared with the rest of Termux, not exclusively this
#     project's to take away.
#   - this cloned repo directory — that's your call, see the final message.
#   - the loaded opencode config is not hot-reloaded: reopen opencode after
#     uninstalling to pick up the removal.
#
# Usage:
#   uninstall.sh        remove the wiring, keep the app + libs
#   uninstall.sh --full also remove ~/.opencode/opencode-native ($DEST)
#                       root itself (scripts, docs, jobs, skill-sources)
#                       and the rotation backups kept under ~/.opencode/
#                       (opencode.prev, .opencode-termux-version.prev,
#                       .prev backup).
set -euo pipefail

FULL=0
case "${1:-}" in
  "") ;;
  --full) FULL=1 ;;
  *) echo "usage: uninstall.sh [--full]" >&2; exit 2 ;;
esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="uninstall.sh"
TOTAL=8
[ "$FULL" = "1" ] && TOTAL=$((TOTAL + 1))
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

OPENCODE_DIR="$HOME/.opencode"
DEST="$OPENCODE_DIR/opencode-native"
CONFIG_DIR="$HOME/.config/opencode"
CONFIG="$CONFIG_DIR/opencode.jsonc"
ENV_NOTES="$CONFIG_DIR/environment.md"
BIN_DIR="$PREFIX/bin"
LD="$OPENCODE_DIR/ld-musl-aarch64.so.1"

remove_claude_native() {
  if [ "$FULL" = "1" ]; then
    rm -rf "$DEST"
  else
    # DEST only ever holds scripts/docs, not the ~194MB binary (that's
    # beside it at $OPENCODE_DIR and always kept). Just clear out what made
    # the wiring "live" — leaving docs + skill-sources for a quick future
    # reinstall without needing the repo checkout.
    rm -f "$DEST"/autocheck.sh "$DEST"/update.sh "$DEST"/doctor.sh \
          "$DEST"/opencode-job-runner.sh "$DEST"/adb-bridge.sh \
          "$DEST"/feature-hooks.sh "$DEST"/opencode-features.sh \
          "$DEST"/.opencode-native.lock "$DEST"/.repatch-history \
          "$DEST"/.doctor-last-versions "$DEST"/.last-opencode-version \
          "$DEST"/.pinned-version "$DEST"/.epoll-fix-cache \
          "$DEST"/update-fail-*.log
    rm -rf "$DEST"/jobs
  fi
}

remove_backups() {
  rm -f "$OPENCODE_DIR/opencode.prev" "$OPENCODE_DIR/.opencode-termux-version.prev"
}

remove_wrapper() {
  rm -f "$BIN_DIR/opencode" "$BIN_DIR/termux-update-opencode" "$BIN_DIR/termux-opencode-job" "$BIN_DIR/termux-opencode-features"
}

remove_scheduled_jobs() {
  if command -v termux-job-scheduler >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -d "$DEST/jobs" ]; then
    local f id
    for f in "$DEST"/jobs/*.json; do
      [ -e "$f" ] || continue
      id=$(jq -r '.id' "$f" 2>/dev/null) || continue
      [ -n "$id" ] && termux-job-scheduler --cancel --job-id "$id" 2>/dev/null || true
    done
    # NOT --cancel-all: that would also cancel any unrelated
    # termux-job-scheduler job another tool on this device has scheduled —
    # termux-job-scheduler has no per-app job namespacing, so cancelling by
    # the specific job-id each of ours was registered under (same ids
    # `termux-opencode-job` computes from the job name) is the only safe way
    # to remove exactly what we added.
  fi
  rm -rf "$DEST/jobs"
}

remove_bashrc_hook() {
  local bashrc="$HOME/.bashrc"
  [ -e "$bashrc" ] || return 0
  sed -i '\#opencode-native/autocheck\.sh#d' "$bashrc"
}

# Strip OUR two edits from the global config: the autoupdate-off key and the
# "instructions" pointer to environment.md (only if the instructions entry is
# exactly ours — never another file). Everything else the user may have set
# is preserved, and the file is backed up first like all config writes.
remove_config_entries() {
  [ -e "$CONFIG" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  cp -f "$CONFIG" "$CONFIG.bak"
  local tmp; tmp=$(mktemp)
  jq --arg notes "$ENV_NOTES" '
    del(.autoupdate)
    | .instructions = ((.instructions // [])
        | map(select(. != $notes)))
    | if (.instructions | length) == 0 then del(.instructions) else . end
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

remove_env_notes() {
  env_notes_remove "$ENV_NOTES"
}

remove_skill() {
  rm -rf "$CONFIG_DIR/skills/opencode-termux-doctor"
}

# Calls the same disable function `termux-opencode-features disable
# adb-bridge` uses at runtime (feature-hooks.sh, sourced via lib.sh from
# this repo's own copy — independent of whether the STAGED copy under
# ~/.opencode/opencode-native/ has already been removed by
# remove_claude_native, since this doesn't shell out to it).
remove_adb_bridge() {
  disable_adb_bridge
}

echo "${BOLD}opencode-code-termux-native${RESET} — uninstalling"
echo

step "removing the opencode wrapper + termux-opencode-* commands" remove_wrapper
step "cancelling scheduled opencode jobs (termux-job-scheduler)"  remove_scheduled_jobs
step "removing the autocheck hook from ~/.bashrc"                remove_bashrc_hook
step "removing autoupdate/instructions entries from opencode.json" remove_config_entries
step "removing our section from ~/.config/opencode/environment.md" remove_env_notes
step "removing the opencode-termux-doctor skill"                 remove_skill
step "removing the optional ADB bridge skill"                    remove_adb_bridge
if [ "$FULL" = "1" ]; then
  step "removing ~/.opencode/opencode-native + rotation backups"  remove_claude_native
  step "removing the prev-binary rotation backups"                remove_backups
else
  step "removing self-repair scripts (keeping the app + libs cached)" remove_claude_native
fi

rm -f "$LOG"
trap - ERR
echo
echo "${GREEN}${BOLD}uninstall complete${RESET}"
echo "  The opencode wrapper and termux-opencode-* commands are gone."
echo "  The autocheck .bashrc hook, the config auto-edit keys, the"
echo "  environment notes section, and both skills were removed."
echo
if [ "$FULL" = "1" ]; then
  echo "  $DEST and the rotation backups under ~/.opencode/ were removed"
  echo "  too. The app binary + musl libs at ~/.opencode/ are KEPT —"
  echo "  delete them yourself if you also want opencode gone:"
  echo "    rm -rf $(shortp "$OPENCODE_DIR")/opencode $(shortp "$OPENCODE_DIR")/ld-musl-aarch64.so.1"
  echo "    rm -f $(shortp "$OPENCODE_DIR")/libc.musl-aarch64.so.1 $(shortp "$OPENCODE_DIR")/libstdc++.so.6 $(shortp "$OPENCODE_DIR")/libstdc++.so.6.0.33 $(shortp "$OPENCODE_DIR")/libgcc_s.so.1"
else
  echo "  The app + musl libs stay at $OPENCODE_DIR (that's the app"
  echo "  itself, ~194MB — a future install.sh reuses it instead of"
  echo "  re-downloading). Run ${BOLD}bash uninstall.sh --full${RESET} to also"
  echo "  remove $(shortp "$DEST") and the rotation backups."
fi
echo
echo "  Not touched (shared with the rest of Termux, not this project's to remove):"
echo "    - packages: curl, jq, patchelf, ripgrep, tar, coreutils, file,"
echo "      ca-certificates, resolv-conf"
echo "    - ~/.config/opencode/opencode.jsonc (your config; only our keys"
echo "      were stripped — a leftover is backed up at opencode.jsonc.bak)"
echo "    - this cloned repo directory: ${DIM}$(shortp "$REPO_DIR")${RESET}"
echo "      (remove it yourself if you're not planning to reinstall: rm -rf $(shortp "$REPO_DIR"))"
echo
echo "  Open a NEW Termux session (or run: exec bash) so the removed wrapper/hook take effect."
echo "  Quit and reopen opencode if it's currently running."