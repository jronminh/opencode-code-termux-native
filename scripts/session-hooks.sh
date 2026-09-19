#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.claude/claude-native/session-hooks.sh by install.sh, wired
# into ~/.claude/settings.json's UserPromptSubmit/Stop/Notification hooks
# only when install.sh is run with --with-notifications (opt-in — this
# changes day-to-day interactive behavior, unlike the doctor.sh hook).
# See README.md ("Extra features" -> "Session hooks").
#
# Every action here is best-effort and NEVER fails the hook: each
# subcommand always exits 0, since Claude Code's docs don't document any
# safe way to recover a blocked Stop hook and this repo isn't going to
# guess at one. No-ops silently if termux-wake-lock/termux-notification
# aren't installed.
set -u

STATE_DIR="${TMPDIR:-/tmp}/claude-code-termux-native"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# termux-wake-lock/-unlock are a single systemwide lock (both just send an
# intent to the one TermuxService — confirmed by reading
# $PREFIX/bin/termux-wake-lock/-unlock), not scoped to a PID or session. With
# two+ concurrent claude sessions (normal with Termux's tabbed UI) an
# unconditional unlock in cmd_stop would drop the lock out from under a
# *different* session still mid-task the instant this one's turn ends. This
# lockfile serializes the ref-count check below (own .since marker removed,
# then "does any other session's marker still exist") so two sessions
# stopping at once can't both misread the count.
WAKELOCK_LOCKFILE="$STATE_DIR/.wakelock.lock"

# Claude Code passes one JSON object on the hook's stdin; read it once.
INPUT=$(cat 2>/dev/null || true)

# field NAME — top-level string field from $INPUT, empty if missing or if
# jq isn't available (install.sh already depends on jq, but this script
# can be invoked by hand too).
field() {
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  printf '%s' "$INPUT" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
}

state_file() {
  local sid; sid=$(field session_id)
  printf '%s/%s.since' "$STATE_DIR" "${sid:-unknown}"
}

# Long-task-finished threshold, in seconds. A Stop fires after every turn,
# not just long ones, so this keeps short back-and-forth chat quiet.
THRESHOLD=60

# Battery percentage at/below which battery_context() speaks up (only when
# also not charging — see below).
BATTERY_LOW_PERCENT=20

# battery_context — best-effort: on a mobile device running low on battery
# and not charging, print one line of plain text. For UserPromptSubmit,
# Claude Code feeds a command hook's stdout back to Claude as context (see
# notes/termux-features-research.md) — so this is how Claude becomes aware
# of real battery state without the human having to say so. Silent
# (no output) whenever battery is fine, unknown, or termux-battery-status
# isn't available/responding — `timeout` caps the wait so a missing/
# ungranted Termux:API app can't delay every single prompt.
battery_context() {
  command -v termux-battery-status >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local info percentage status
  info=$(timeout 3 termux-battery-status 2>/dev/null) || return 0
  percentage=$(printf '%s' "$info" | jq -r '.percentage // empty' 2>/dev/null)
  status=$(printf '%s' "$info" | jq -r '.status // empty' 2>/dev/null)
  [ -n "$percentage" ] || return 0
  case "$status" in
    CHARGING|FULL) return 0 ;;
  esac
  if [ "$percentage" -le "$BATTERY_LOW_PERCENT" ] 2>/dev/null; then
    echo "Device battery is low (${percentage}%, not charging) — this is a mobile device; prefer batching work and avoid kicking off long unattended background tasks until it's charging."
  fi
  return 0
}

cmd_submit() {
  command -v termux-hooks >/dev/null 2>&1 && termux-hooks emit session.start '{"hook":"submit"}' 2>/dev/null || true
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
  # Sweep state files from crashed/never-stopped sessions so STATE_DIR
  # doesn't grow unbounded.
  find "$STATE_DIR" -name '*.since' -mmin +1440 -delete 2>/dev/null
  (
    flock -w 3 200 2>/dev/null
    date +%s > "$(state_file)" 2>/dev/null
  ) 200>"$WAKELOCK_LOCKFILE"
  battery_context
  return 0
}

cmd_stop() {
  command -v termux-hooks >/dev/null 2>&1 && termux-hooks emit session.end '{"hook":"stop"}' 2>/dev/null || true
  local f info started others
  f=$(state_file)
  info=$(
    flock -w 3 200 2>/dev/null
    s=0
    [ -f "$f" ] && s=$(cat "$f" 2>/dev/null || echo 0)
    rm -f "$f" 2>/dev/null
    o=0
    ls "$STATE_DIR"/*.since >/dev/null 2>&1 && o=1
    printf '%s %s' "$s" "$o"
  ) 200>"$WAKELOCK_LOCKFILE"
  started=${info%% *}
  others=${info##* }

  # Only release the systemwide lock once no other session's marker is left
  # — i.e. this is the last session still standing. Otherwise leave it held
  # for whichever session(s) are still running (see WAKELOCK_LOCKFILE note).
  if [ "$others" = "0" ]; then
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null
  fi

  command -v termux-notification >/dev/null 2>&1 || return 0
  [ "${started:-0}" -gt 0 ] 2>/dev/null || return 0
  local now elapsed
  now=$(date +%s)
  elapsed=$(( now - started ))
  [ "$elapsed" -ge "$THRESHOLD" ] || return 0
  local cwd; cwd=$(field cwd)
  termux-notification \
    --id claude-task-done \
    --title "Claude Code finished" \
    --content "Task took ${elapsed}s${cwd:+ in $(basename "$cwd")}" \
    2>/dev/null
  return 0
}

cmd_notify() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  local ntype content
  ntype=$(field notification_type)
  case "$ntype" in
    permission_prompt) content="Waiting for permission" ;;
    idle_prompt)       content="Waiting for you" ;;
    agent_needs_input) content="A background agent needs input" ;;
    agent_completed)   content="A background agent finished" ;;
    *)                 content="${ntype:-notification}" ;;
  esac
  termux-notification --id claude-notify --title "Claude Code" --content "$content" 2>/dev/null
  return 0
}

case "${1:-}" in
  submit) cmd_submit ;;
  stop)   cmd_stop ;;
  notify) cmd_notify ;;
esac
exit 0
