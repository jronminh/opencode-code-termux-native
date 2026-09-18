#!/data/data/com.termux/files/usr/bin/bash
# Installs OpenCode natively on Termux/Android.
#
# What this actually does: takes the aarch64 musl build of the opencode
# binary (published by the C04-wq/opencode-termux project), pins its ELF
# interpreter to the musl loader that ships beside it, and wraps launch in
# a loader --library-path call so the musl runtime never leaks into
# Bionic child processes (the leak that breaks bash/rg under the stock
# opencode-termux launcher). See README.md for the full story.
#
# Safe to re-run: every step is idempotent. To undo everything, see
# uninstall.sh.
set -euo pipefail

WITH_ADB_BRIDGE=0
for arg in "$@"; do
  case "$arg" in
    --with-adb-bridge) WITH_ADB_BRIDGE=1 ;;
    *) echo "usage: install.sh [--with-adb-bridge]" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="install.sh"
TOTAL=10
[ "$WITH_ADB_BRIDGE" = "1" ] && TOTAL=$((TOTAL + 1))
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

OPENCODE_DIR="$HOME/.opencode"
DEST="$OPENCODE_DIR/opencode-native"
CONFIG_DIR="$HOME/.config/opencode"
CONFIG="$CONFIG_DIR/opencode.jsonc"
ENV_NOTES="$CONFIG_DIR/environment.md"
BIN_DIR="$PREFIX/bin"
LD="$OPENCODE_DIR/ld-musl-aarch64.so.1"

install_packages() {
  # --force-confdef/--force-confold: this runs unattended (no TTY to answer
  # dpkg's "keep your modified conffile?" prompt), so auto-keep the existing
  # config instead of hanging/failing on upgrades like openssl's.
  local opts=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  pkg install "${opts[@]}" curl jq patchelf ripgrep tar coreutils file ca-certificates resolv-conf &&
    pkg update -y 2>/dev/null || true &&
    pkg install "${opts[@]}" curl jq patchelf ripgrep tar coreutils file ca-certificates resolv-conf &&
    [ "$(command -v patchelf)" ]
}

stage_scripts() {
  mkdir -p "$DEST"
  install -m 700 "$REPO_DIR/scripts/autocheck.sh"           "$DEST/autocheck.sh"
  install -m 700 "$REPO_DIR/scripts/update.sh"               "$DEST/update.sh"
  install -m 700 "$REPO_DIR/scripts/doctor.sh"               "$DEST/doctor.sh"
  install -m 700 "$REPO_DIR/scripts/adb-bridge.sh"           "$DEST/adb-bridge.sh"
  install -m 700 "$REPO_DIR/scripts/feature-hooks.sh"        "$DEST/feature-hooks.sh"
  install -m 700 "$REPO_DIR/scripts/opencode-features.sh"    "$DEST/opencode-features.sh"
  install -m 700 "$REPO_DIR/scripts/opencode-job-runner.sh"  "$DEST/opencode-job-runner.sh"
  # Skill sources for features that install a skill (currently just
  # adb-bridge): staged unconditionally, so `termux-opencode-features enable
  # adb-bridge` works later even if --with-adb-bridge wasn't passed at
  # install time (or the repo checkout this ran from is long gone by then).
  mkdir -p "$DEST/skill-sources/adb-bridge"
  install -m 600 "$REPO_DIR/skills/adb-bridge/SKILL.md" "$DEST/skill-sources/adb-bridge/SKILL.md"
  # docs/ — staged so this detail is available on-device on demand without
  # needing the repo checkout.
  mkdir -p "$DEST/docs"
  for f in "$REPO_DIR"/docs/*.md; do
    install -m 600 "$f" "$DEST/docs/$(basename "$f")"
  done
}

install_wrapper() {
  install -m 700 "$REPO_DIR/scripts/opencode-wrapper.sh"       "$BIN_DIR/opencode"
  install -m 700 "$REPO_DIR/scripts/termux-update-opencode.sh" "$BIN_DIR/termux-update-opencode"
  install -m 700 "$REPO_DIR/scripts/opencode-job.sh"           "$BIN_DIR/termux-opencode-job"
  install -m 700 "$REPO_DIR/scripts/termux-opencode-features.sh" "$BIN_DIR/termux-opencode-features"
}

wire_bashrc() {
  local bashrc="$HOME/.bashrc"
  touch "$bashrc"
  grep -qF 'opencode-native/autocheck.sh' "$bashrc" ||
    printf '\nsource "%s/autocheck.sh"\n' "$DEST" >> "$bashrc"
}

# opencode's own config has an autoupdate knob, and the wrapper exports
# OPENCODE_DISABLE_AUTOUPDATE=1 too — both together are the analog of
# claude's DISABLE_AUTOUPDATER. The in-process autoupdater would otherwise
# silently drop in an unpatched build that can't run on Bionic.
disable_autoupdater() {
  mkdir -p "$CONFIG_DIR"
  if [ -e "$CONFIG" ]; then
    cp -f "$CONFIG" "$CONFIG.bak"
  else
    printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$CONFIG"
  fi
  local tmp; tmp=$(mktemp)
  jq '.autoupdate = false' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

# Point opencode's global instructions at the environment notes so every
# session knows it's on a patched-musl/Termux setup (the opencode analog of
# claude's CLAUDE.md section). Preserves any existing instructions.
point_instructions() {
  mkdir -p "$CONFIG_DIR"
  if [ -e "$CONFIG" ]; then
    cp -f "$CONFIG" "$CONFIG.bak"
  else
    printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$CONFIG"
  fi
  local tmp; tmp=$(mktemp)
  jq --arg f "$ENV_NOTES" '.instructions = (((.instructions // []) + [$f]) | unique)' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

install_env_notes() {
  env_notes_upsert "$REPO_DIR/environment.md.template" "$ENV_NOTES"
}

install_skill() {
  local dir="$CONFIG_DIR/skills/opencode-termux-doctor"
  mkdir -p "$dir"
  install -m 600 "$REPO_DIR/skills/opencode-termux-doctor/SKILL.md" "$dir/SKILL.md"
}

# Opt-in only (security-sensitive — see skills/adb-bridge/SKILL.md). The
# script itself is always staged by stage_scripts; this wires the skill.
install_adb_bridge() {
  enable_adb_bridge "$REPO_DIR/skills/adb-bridge/SKILL.md" "$CONFIG_DIR/skills"
}

echo "${BOLD}opencode-code-termux-native${RESET} — installing OpenCode natively on Termux"
echo

step "checking platform"                                   check_platform
step "installing Termux packages"                          install_packages
step "staging self-repair scripts at $(shortp "$DEST")"    stage_scripts

N=$((N + 1))
bash "$DEST/update.sh" || fail "initial download/patch failed — run: bash $(shortp "$DEST")/doctor.sh"
step_banner "downloading and patching the opencode binary"
printf '%sok%s\n' "$GREEN" "$RESET"

step "installing wrapper + termux-opencode-* commands"     install_wrapper
step "wiring autocheck.sh into ~/.bashrc"                   wire_bashrc
step "disabling the in-process autoupdater"                 disable_autoupdater
step "installing environment notes + global config pointer" install_env_notes
step "pointing opencode at the environment notes"           point_instructions
step "installing the opencode-termux-doctor skill"          install_skill
if [ "$WITH_ADB_BRIDGE" = "1" ]; then
  step "installing the optional ADB bridge skill"            install_adb_bridge
fi

rm -f "$LOG"
trap - ERR
echo
echo "${GREEN}${BOLD}install complete${RESET}"
echo "  ${DIM}1.${RESET} open a NEW Termux session (or run: exec bash)"
echo "  ${DIM}2.${RESET} run: ${BOLD}opencode${RESET}"
echo
printf '  %-18s: %s\n' "verify anytime"    "${DIM}bash $(shortp "$DEST")/doctor.sh${RESET}"
printf '  %-18s: %s\n' "check for updates" "${DIM}termux-update-opencode${RESET}"
printf '  %-18s: %s\n' "schedule a job"    "${DIM}termux-opencode-job add <name> --prompt \"...\" --period-ms 900000${RESET}"
printf '  %-18s: %s\n' "toggle a feature"  "${DIM}termux-opencode-features {status|enable|disable} <feature>${RESET}"
printf '  %-18s: %s\n' "uninstall"         "${DIM}bash $(shortp "$REPO_DIR")/uninstall.sh${RESET}"
echo
echo "  Environment notes were added to ~/.config/opencode/environment.md"
echo "  (wired into your global opencode.json instructions), and the"
echo "  opencode-termux-doctor skill was installed, so opencode recognizes"
echo "  this setup (and its quirks) and knows how to self-diagnose."
echo
echo "  The wrapper (and autocheck.sh) lock the autoupdater off, so an"
echo "  in-process update can't silently replace the patched binary with an"
echo "  unpatched one. Update deliberately with: termux-update-opencode."

if [ "$WITH_ADB_BRIDGE" = "1" ]; then
  echo
  echo "  The adb-bridge skill was installed. This is security-sensitive"
  echo "  (commands run at the shell UID via the termux-adb-bridge daemon) —"
  echo "  see the skill's \"Security posture\" section."
  echo "  Turn off anytime: ${BOLD}termux-opencode-features disable adb-bridge${RESET}."
else
  echo
  echo "  Tip: ${BOLD}termux-opencode-features enable adb-bridge${RESET} lets opencode see and"
  echo "  drive the full Android screen through the termux-adb-bridge shell-UID"
  echo "  daemon (screenshots, exact-coordinate taps, full-system logcat) —"
  echo "  opt-in, security-sensitive."
fi

if kernel_is_risky && ! epoll_fix_present "$OPENCODE_DIR/opencode"; then
  echo
  echo "${DIM}note:${RESET} kernel $(uname -r) is 5.11+, and this build of opencode predates"
  echo "  the upstream fix for a Bun TLS-fault crash on epoll_pwait2 (bun#32490) —"
  echo "  it may segfault right at launch on some devices. The wrapper already"
  echo "  sets BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1; if it still crashes, see"
  echo "  README.md (\"Troubleshooting\")."
fi