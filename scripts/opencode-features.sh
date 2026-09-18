#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.opencode/opencode-native/opencode-features.sh by install.sh,
# and exposed as `termux-opencode-features` in $PREFIX/bin via a thin exec
# wrapper (scripts/termux-opencode-features.sh) — same pattern as
# termux-update-opencode.sh -> update.sh. The dedicated command for turning
# an opt-in feature on/off AFTER install, without re-running install.sh
# (which only ever adds) or uninstall.sh (which removes everything). See
# README.md ("Extra features").
#
# Usage:
#   termux-opencode-features status                    show every feature's state
#   termux-opencode-features enable  <feature>
#   termux-opencode-features disable <feature>
# Features: adb-bridge
set -u

DEST="$HOME/.opencode/opencode-native"
SKILL_SRC_DIR="$DEST/skill-sources"

# shellcheck source=scripts/feature-hooks.sh
source "$DEST/feature-hooks.sh" || {
  echo "$DEST/feature-hooks.sh missing — reinstall: bash install.sh (in your opencode-code-termux-native checkout)" >&2
  exit 1
}

bridge_summary() {
  command -v dsh >/dev/null 2>&1 || { echo "termux-adb-bridge not installed (no dsh)"; return; }
  if timeout 8 dsh --check >/dev/null 2>&1; then
    local dev; dev=$(timeout 8 dsh 'printf "%s (%s)" "$(getprop ro.product.model)" "$(getprop ro.serialno)"' 2>/dev/null)
    echo "shell UID reachable${dev:+ ($dev)}"
  else
    echo "daemon not reachable — start it: ~/termux-adb-bridge/maintain/deploy.sh"
  fi
}

# cmd_status carries each feature's one-line description + safety notes
# directly in its output — this is the single place that text lives, so
# environment.md.template never needs a per-feature bullet or an edit when a
# new feature is added here.
cmd_status() {
  if adb_bridge_wired; then
    echo "adb-bridge    : ON  — see/drive the full Android screen via the termux-adb-bridge shell-UID daemon (dsh): screenshots, exact-coordinate taps, full-system logcat for debugging things termux-api can't reach. SECURITY-SENSITIVE (shell-UID access). $(bridge_summary). disable: termux-opencode-features disable adb-bridge"
  else
    echo "adb-bridge    : off — see/drive the full Android screen via the termux-adb-bridge shell-UID daemon (dsh): screenshots, exact-coordinate taps, full-system logcat for debugging things termux-api can't reach. SECURITY-SENSITIVE (shell-UID access) — ask the user before enabling. enable: termux-opencode-features enable adb-bridge"
  fi
  echo "notifications : n/a — claude's Termux wake-lock/notification hooks have no opencode equivalent (opencode has no settings.json hook system); not planned pending a plugin."
}

cmd_enable() {
  case "${1:-}" in
    adb-bridge)
      enable_adb_bridge "$SKILL_SRC_DIR/adb-bridge/SKILL.md" && {
        echo "adb-bridge enabled (skill installed)"
        echo "requires the termux-adb-bridge daemon; check with: ~/.opencode/opencode-native/adb-bridge.sh status"
      }
      ;;
    "")
      echo "usage: termux-opencode-features enable <adb-bridge>" >&2; return 2 ;;
    *)
      echo "unknown feature: $1 (known: adb-bridge)" >&2; return 2 ;;
  esac
}

cmd_disable() {
  case "${1:-}" in
    adb-bridge)
      disable_adb_bridge && echo "adb-bridge disabled (skill removed) — the shell-UID daemon is separate; stop it per ~/termux-adb-bridge/README.md if you're done"
      ;;
    "")
      echo "usage: termux-opencode-features disable <adb-bridge>" >&2; return 2 ;;
    *)
      echo "unknown feature: $1 (known: adb-bridge)" >&2; return 2 ;;
  esac
}

case "${1:-}" in
  status)  cmd_status ;;
  enable)  shift; cmd_enable "$@" ;;
  disable) shift; cmd_disable "$@" ;;
  *)
    echo "usage: termux-opencode-features {status|enable <feature>|disable <feature>}" >&2
    echo "features: adb-bridge" >&2
    exit 2
    ;;
esac