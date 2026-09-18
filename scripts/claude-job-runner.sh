#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.claude/claude-native/claude-job-runner.sh by install.sh.
# Invoked by Android's JobScheduler (via termux-job-scheduler) through a tiny
# per-job stub script that `termux-claude-job add` generates at
# ~/.claude/claude-native/jobs/<name>.sh — never call this directly except
# via `termux-claude-job run <name>` for manual testing. See README.md
# ("Extra features" -> "Scheduled jobs").
#
# JobScheduler runs this standalone, not from an interactive shell — never
# assume .bashrc/autocheck.sh ran, or that PATH/TMPDIR are already set up.
set -u
export PATH="$PREFIX/bin:$PATH"
export TMPDIR="$HOME/.cache/claude-tmp"
mkdir -p "$TMPDIR"
unset LD_PRELOAD LD_LIBRARY_PATH

NAME="${1:?usage: claude-job-runner.sh <job-name>}"
DEST="$HOME/.claude/claude-native"
JOBS_DIR="$DEST/jobs"
DEF="$JOBS_DIR/$NAME.json"
LOG="$JOBS_DIR/$NAME.log"
SID="job-$NAME-$$"

if [ ! -e "$DEF" ]; then
  echo "claude-job-runner.sh: no such job '$NAME' (missing $DEF)" >&2
  exit 1
fi

PROMPT=$(jq -r '.prompt' "$DEF" 2>/dev/null)
CWD=$(jq -r '.cwd // empty' "$DEF" 2>/dev/null)
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$HOME"
cd "$CWD" 2>/dev/null || cd "$HOME" || exit 1

# Reuse session-hooks.sh's own ref-counted wake-lock (see its
# WAKELOCK_LOCKFILE note) instead of calling termux-wake-lock/-unlock
# directly here: termux-wake-lock/-unlock are a single systemwide lock, and
# an unconditional call from this background job would race an interactive
# session's own lock/unlock the same way that script was fixed to avoid.
# This also gets us its "task finished" notification (60s+ threshold) for
# free on a normal run, so we only need to push our own notification below
# on failure.
printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$CWD" | "$DEST/session-hooks.sh" submit

START=$(date +%s)
{
  echo "=== $(date '+%Y-%m-%d %H:%M:%S %z') — job '$NAME' starting ==="
  echo "cwd: $CWD"
  echo "prompt: $PROMPT"
  echo "---"
  "$PREFIX/bin/claude" -p "$PROMPT"
} >>"$LOG" 2>&1
RC=$?
NOW=$(date +%s)
echo "=== job '$NAME' finished (exit $RC, $((NOW - START))s) ===" >>"$LOG"

printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$CWD" | "$DEST/session-hooks.sh" stop

if [ "$RC" -ne 0 ] && command -v termux-notification >/dev/null 2>&1; then
  termux-notification --id "claude-job-$NAME" --title "Claude job failed: $NAME" \
    --content "exit $RC — see $(basename "$LOG") for details" 2>/dev/null || true
fi

exit "$RC"
