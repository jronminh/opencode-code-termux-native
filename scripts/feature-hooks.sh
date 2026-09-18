# shellcheck shell=bash
# Meant to be sourced, not executed directly (no shebang, on purpose) —
# same convention as lib.sh. Unlike lib.sh, this file IS staged to
# ~/.opencode/opencode-native/feature-hooks.sh by install.sh
# (unconditionally), because it's sourced from TWO different places:
#   1. scripts/lib.sh sources the REPO copy, so install.sh/uninstall.sh get
#      these functions at install/uninstall time (repo path known).
#   2. scripts/opencode-features.sh sources the STAGED copy at
#      ~/.opencode/opencode-native/feature-hooks.sh, so the standalone
#      `termux-opencode-features` command can enable/disable a feature long
#      after the repo checkout is gone, moved, or out of date.
# This is the ONE place that knows how to wire/unwire each opt-in feature
# — install.sh, uninstall.sh, and opencode-features.sh all just call the
# functions below. Keep it self-contained: no dependency on anything else
# in lib.sh (colors, step banners, ...), since opencode-features.sh sources
# ONLY this file, not the rest of lib.sh.
#
# Note: unlike claude-code-termux-native, opencode has NO settings.json
# hook system, so features here are wired purely by installing/removing
# skill files (and, in the future, plugins) — there is no hook equivalent
# to add or remove.

# --- adb-bridge feature (adb-bridge.sh + the adb-bridge skill) ---

ADB_BRIDGE_SKILL_DIR="$HOME/.config/opencode/skills/adb-bridge"

# enable_adb_bridge SKILL_SRC — SKILL_SRC is the adb-bridge SKILL.md to
# install: the repo's own copy when called from install.sh, or the copy
# install.sh staged at ~/.opencode/opencode-native/skill-sources/adb-bridge/
# SKILL.md when called from opencode-features.sh (repo may be long gone).
enable_adb_bridge() {
  local skill_src="${1:-}"
  [ -n "$skill_src" ] && [ -f "$skill_src" ] || {
    echo "adb-bridge skill source not found: ${skill_src:-<none given>}" >&2
    return 1
  }
  mkdir -p "$ADB_BRIDGE_SKILL_DIR"
  install -m 600 "$skill_src" "$ADB_BRIDGE_SKILL_DIR/SKILL.md"
}

disable_adb_bridge() {
  rm -rf "$ADB_BRIDGE_SKILL_DIR"
}

adb_bridge_wired() {
  [ -e "$ADB_BRIDGE_SKILL_DIR/SKILL.md" ]
}