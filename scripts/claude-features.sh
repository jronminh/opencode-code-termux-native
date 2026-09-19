#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.claude/claude-native/claude-features.sh by install.sh, and
# exposed as `termux-claude-features` in $PREFIX/bin via a thin exec
# wrapper (scripts/termux-claude-features.sh) — same pattern as
# termux-update-claude.sh -> update.sh. The dedicated command for turning
# an opt-in feature on/off AFTER install, without re-running install.sh
# (which only ever adds) or uninstall.sh (which removes everything). See
# README.md ("Extra features").
#
# Usage:
#   termux-claude-features status                    show every feature's state
#   termux-claude-features enable  <feature>
#   termux-claude-features disable <feature>
# Features: notifications, adb-bridge
set -u

DEST="$HOME/.claude/claude-native"
SKILL_SRC_DIR="$DEST/skill-sources"

# shellcheck source=scripts/feature-hooks.sh
source "$DEST/feature-hooks.sh" || {
  echo "$DEST/feature-hooks.sh missing — reinstall: bash install.sh (in your claude-code-termux-native checkout)" >&2
  exit 1
}

adb_connected_summary() {
  command -v adb >/dev/null 2>&1 || { echo "android-tools not installed"; return; }
  local dev; dev=$(timeout 3 adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}')
  if [ -n "$dev" ]; then echo "connected ($dev)"; else echo "not connected"; fi
}

# cmd_status carries each feature's one-line description + safety notes
# directly in its output — this is the single place that text lives, so
# CLAUDE.md.template never needs a per-feature bullet or an edit when a
# new feature is added here.
cmd_status() {
  if notifications_wired; then
    echo "notifications : ON  — per-turn Termux wake-lock + Termux:API notifications (permission/idle prompts, long-task-finished). Not security-sensitive. disable: termux-claude-features disable notifications"
  else
    echo "notifications : off — per-turn Termux wake-lock + Termux:API notifications (permission/idle prompts, long-task-finished). Not security-sensitive. enable: termux-claude-features enable notifications"
  fi

  if adb_bridge_wired; then
    echo "adb-bridge    : ON  — see/drive the full Android screen via wireless ADB (screenshots, exact-coordinate taps, full-system logcat) for debugging things termux-api can't reach. SECURITY-SENSITIVE (shell-UID access) — read the adb-bridge skill before pairing a NEW device; a connection persists until revoked in Developer options. $(adb_connected_summary). disable: termux-claude-features disable adb-bridge"
  else
    echo "adb-bridge    : off — see/drive the full Android screen via wireless ADB (screenshots, exact-coordinate taps, full-system logcat) for debugging things termux-api can't reach. SECURITY-SENSITIVE (shell-UID access) — ask the user before enabling. enable: termux-claude-features enable adb-bridge"
  fi
}

cmd_enable() {
  case "${1:-}" in
    notifications)
      enable_notifications && { command -v termux-hooks >/dev/null 2>&1 && termux-hooks emit feature.toggle '{"feature":"notifications","action":"enable"}' 2>/dev/null || true; echo "notifications enabled — open a NEW Termux session for it to take effect"; }
      ;;
    adb-bridge)
      enable_adb_bridge "$SKILL_SRC_DIR/adb-bridge/SKILL.md" && {
        command -v termux-hooks >/dev/null 2>&1 && termux-hooks emit feature.toggle '{"feature":"adb-bridge","action":"enable"}' 2>/dev/null || true
        echo "adb-bridge enabled — open a NEW Termux session for the Stop hook to take effect"
        echo "read the adb-bridge skill (~/.claude/skills/adb-bridge/SKILL.md) before pairing a device"
      }
      ;;
    "")
      echo "usage: termux-claude-features enable <notifications|adb-bridge>" >&2; return 2 ;;
    *)
      echo "unknown feature: $1 (known: notifications, adb-bridge)" >&2; return 2 ;;
  esac
}

cmd_disable() {
  case "${1:-}" in
    notifications)
      disable_notifications && { command -v termux-hooks >/dev/null 2>&1 && termux-hooks emit feature.toggle '{"feature":"notifications","action":"disable"}' 2>/dev/null || true; echo "notifications disabled — open a NEW Termux session for it to take effect"; }
      ;;
    adb-bridge)
      disable_adb_bridge && { command -v termux-hooks >/dev/null 2>&1 && termux-hooks emit feature.toggle '{"feature":"adb-bridge","action":"disable"}' 2>/dev/null || true; echo "adb-bridge disabled (skill + Stop hook removed) — if a device is still connected, also turn off Wireless debugging in Developer options"; }
      ;;
    "")
      echo "usage: termux-claude-features disable <notifications|adb-bridge>" >&2; return 2 ;;
    *)
      echo "unknown feature: $1 (known: notifications, adb-bridge)" >&2; return 2 ;;
  esac
}

case "${1:-}" in
  status)  cmd_status ;;
  enable)  shift; cmd_enable "$@" ;;
  disable) shift; cmd_disable "$@" ;;
  *)
    echo "usage: termux-claude-features {status|enable <feature>|disable <feature>}" >&2
    echo "features: notifications, adb-bridge" >&2
    exit 2
    ;;
esac
