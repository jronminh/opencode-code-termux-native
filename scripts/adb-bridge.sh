#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.opencode/opencode-native/adb-bridge.sh by install.sh
# (unconditionally — staging is harmless since nothing here runs on its
# own). The adb-bridge SKILL is only wired when install.sh runs with
# --with-adb-bridge, or via `termux-opencode-features enable adb-bridge`:
# this is a security-sensitive, opt-in capability, not something to
# surface by default. See skills/adb-bridge/SKILL.md and
# notes/termux-features-research.md ("4b") for the full story and the
# security posture. Unlike the claude repo there is no Stop-hook reminder
# here (opencode has no hook system) — connection hygiene is your job.
#
# Thin wrapper around `dsh` (termux-adb-bridge): the shell-UID daemon
# (already paired once over Wireless Debugging by termux-adb-bridge, see
# ~/termux-adb-bridge/README.md) runs every command here at `shell` UID,
# so no android-tools / adb pairing is involved. Every subcommand is
# read-only or a single explicit action; nothing here polls or loops.
#
# Usage:
#   adb-bridge.sh status [--json]     daemon reachability + device
#   adb-bridge.sh screenshot [PATH]   screencap -> written to PATH (default:
#                                      a tmp file under $TMPDIR), path printed
#   adb-bridge.sh dump [PATH]         uiautomator dump -> written to PATH
#                                      (exact bounds="[x1,y1][x2,y2]" per
#                                      element — more reliable than
#                                      computing taps off a screenshot)
#   adb-bridge.sh tap X Y             input tap at exact coordinates
#   adb-bridge.sh swipe X1 Y1 X2 Y2 [MS]   input swipe
#   adb-bridge.sh logcat [LINES]      last LINES of the system log (default
#                                      500), one-shot dump, does not follow
#   adb-bridge.sh logcat-clear        clear the log buffer (do this before
#                                      reproducing an issue, then `logcat`)
#   adb-bridge.sh nag                 prints one line iff the shell-UID
#                                      daemon is reachable right now, silent
#                                      otherwise — never fails
set -u

DSH_BIN="${DSH_BIN:-dsh}"
STATUS_TIMEOUT=8
RUN_TIMEOUT=30
REMOTE_DUMP=/data/local/tmp/.adb-bridge-dump.xml

dsh_ok() { command -v "$DSH_BIN" >/dev/null 2>&1; }

# bridge_alive — true iff the shell-UID daemon answers (dsh --check runs
# `id` through it). Short timeout so `status` stays snappy.
bridge_alive() { dsh_ok && timeout "$STATUS_TIMEOUT" "$DSH_BIN" --check >/dev/null 2>&1; }

# device_label — best-effort "model (serial)"; empty on failure.
device_label() {
  timeout "$STATUS_TIMEOUT" "$DSH_BIN" \
    'printf "%s (%s)" "$(getprop ro.product.model)" "$(getprop ro.serialno)"' 2>/dev/null
}

require_bridge() {
  bridge_alive || {
    if dsh_ok; then
      echo "shell-UID daemon not reachable — start it: ~/termux-adb-bridge/maintain/deploy.sh" >&2
    else
      echo "dsh not found — install termux-adb-bridge first: ~/termux-adb-bridge/README.md" >&2
    fi
    return 1
  }
}

cmd_status() {
  local json=0
  [ "${1:-}" = "--json" ] && json=1
  if ! dsh_ok; then
    if [ "$json" = "1" ]; then jq -n '{installed:false, connected:false, device:null}'
    else echo "termux-adb-bridge not installed (no dsh) — see ~/termux-adb-bridge/README.md"; fi
    return 0
  fi
  if bridge_alive; then
    local dev; dev=$(device_label)
    if [ "$json" = "1" ]; then
      jq -n --arg dev "$dev" '{installed:true, connected:true, device:$dev}'
    else
      echo "shell UID reachable${dev:+ — $dev}"
    fi
  else
    if [ "$json" = "1" ]; then jq -n '{installed:true, connected:false, device:null}'
    else echo "dsh installed, daemon not reachable — start it: ~/termux-adb-bridge/maintain/deploy.sh"; fi
  fi
}

cmd_screenshot() {
  local out="${1:-}"
  [ -n "$out" ] || out="${TMPDIR:-/tmp}/adb-bridge-shot-$(date +%s).png"
  require_bridge || return 1
  if ! timeout "$RUN_TIMEOUT" "$DSH_BIN" 'screencap -p' >"$out"; then
    echo "screencap failed" >&2; rm -f "$out"; return 1
  fi
  [ -s "$out" ] || { echo "screencap produced no data" >&2; rm -f "$out"; return 1; }
  echo "$out"
}

cmd_dump() {
  local out="${1:-}"
  [ -n "$out" ] || out="${TMPDIR:-/tmp}/adb-bridge-dump-$(date +%s).xml"
  require_bridge || return 1
  if ! timeout "$RUN_TIMEOUT" "$DSH_BIN" \
      "uiautomator dump $REMOTE_DUMP >/dev/null 2>&1; cat $REMOTE_DUMP" >"$out"; then
    echo "uiautomator dump failed" >&2; rm -f "$out"; return 1
  fi
  timeout "$STATUS_TIMEOUT" "$DSH_BIN" "rm -f $REMOTE_DUMP" >/dev/null 2>&1
  [ -s "$out" ] || { echo "uiautomator dump produced no data" >&2; rm -f "$out"; return 1; }
  echo "$out"
}

cmd_tap() {
  local x="${1:-}" y="${2:-}"
  [ -n "$x" ] && [ -n "$y" ] || { echo "usage: adb-bridge.sh tap X Y" >&2; return 2; }
  require_bridge || return 1
  timeout "$RUN_TIMEOUT" "$DSH_BIN" "input tap $x $y"
}

cmd_swipe() {
  local x1="${1:-}" y1="${2:-}" x2="${3:-}" y2="${4:-}" ms="${5:-300}"
  [ -n "$x1" ] && [ -n "$y1" ] && [ -n "$x2" ] && [ -n "$y2" ] || { echo "usage: adb-bridge.sh swipe X1 Y1 X2 Y2 [MS]" >&2; return 2; }
  require_bridge || return 1
  timeout "$RUN_TIMEOUT" "$DSH_BIN" "input swipe $x1 $y1 $x2 $y2 $ms"
}

cmd_logcat() {
  local n="${1:-500}"
  require_bridge || return 1
  timeout "$RUN_TIMEOUT" "$DSH_BIN" "logcat -d -t $n"
}

cmd_logcat_clear() {
  require_bridge || return 1
  timeout "$RUN_TIMEOUT" "$DSH_BIN" 'logcat -c'
}

# nag — best-effort, NEVER fails (always returns 0): prints exactly one
# line iff the shell-UID daemon is reachable right now, nothing otherwise.
cmd_nag() {
  bridge_alive || return 0
  echo "shell-UID bridge is live — if you're done, stop the daemon (see ~/termux-adb-bridge/README.md)."
  return 0
}

case "${1:-}" in
  status)       shift; cmd_status "$@" ;;
  screenshot)   shift; cmd_screenshot "$@" ;;
  dump)         shift; cmd_dump "$@" ;;
  tap)          shift; cmd_tap "$@" ;;
  swipe)        shift; cmd_swipe "$@" ;;
  logcat)       shift; cmd_logcat "$@" ;;
  logcat-clear) shift; cmd_logcat_clear "$@" ;;
  nag)          shift; cmd_nag "$@" ;;
  *)
    echo "usage: adb-bridge.sh {status [--json]|screenshot [PATH]|dump [PATH]|tap X Y|swipe X1 Y1 X2 Y2 [MS]|logcat [LINES]|logcat-clear|nag}" >&2
    exit 2
    ;;
esac
