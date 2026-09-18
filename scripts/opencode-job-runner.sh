#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.opencode/opencode-native/opencode-job-runner.sh by install.sh.
# Invoked by Android's JobScheduler (via termux-job-scheduler) through a tiny
# per-job stub script that `termux-opencode-job add` generates at
# ~/.opencode/opencode-native/jobs/<name>.sh — never call this directly
# except via `termux-opencode-job run <name>` for manual testing. See
# README.md ("Extra features" -> "Scheduled jobs").
#
# JobScheduler runs this standalone, not from an interactive shell — never
# assume .bashrc/autocheck.sh ran, or that PATH/TMPDIR are already set up.
#
# Wake-lock: a long-running job can land partway through Doze. We take a
# systemwide wake-lock for the duration (termux-wake-lock/-unlock). Caveat
# inherited from the claude repo: those are a SINGLE systemwide lock, so if
# an interactive session is itself holding one, this acquires/releases the
# same one — the lock stays held by whichever acquires last and releases
# first. Acceptable for short jobs; don't schedule + run one while you're
# actively waiting on an interactive background task.
set -u
export PATH="$PREFIX/bin:$PATH"
export TMPDIR="$HOME/.cache/opencode-tmp"
mkdir -p "$TMPDIR"
unset LD_PRELOAD LD_LIBRARY_PATH

NAME="${1:?usage: opencode-job-runner.sh <job-name>}"
DEST="$HOME/.opencode/opencode-native"
JOBS_DIR="$DEST/jobs"
DEF="$JOBS_DIR/$NAME.json"
LOG="$JOBS_DIR/$NAME.log"

if [ ! -e "$DEF" ]; then
  echo "opencode-job-runner.sh: no such job '$NAME' (missing $DEF)" >&2
  exit 1
fi

PROMPT=$(jq -r '.prompt' "$DEF" 2>/dev/null)
CWD=$(jq -r '.cwd // empty' "$DEF" 2>/dev/null)
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$HOME"
cd "$CWD" 2>/dev/null || cd "$HOME" || exit 1

command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null || true
cleanup() { command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null || true; }
trap cleanup EXIT

START=$(date +%s)
{
  echo "=== $(date '+%Y-%m-%d %H:%M:%S %z') — job '$NAME' starting ==="
  echo "cwd: $CWD"
  echo "prompt: $PROMPT"
  echo "---"
  "$PREFIX/bin/opencode" run "$PROMPT"
} >>"$LOG" 2>&1
RC=$?
NOW=$(date +%s)
echo "=== job '$NAME' finished (exit $RC, $((NOW - START))s) ===" >>"$LOG"

if [ "$RC" -ne 0 ] && command -v termux-notification >/dev/null 2>&1; then
  termux-notification --id "opencode-job-$NAME" --title "opencode job failed: $NAME" \
    --content "exit $RC — see $(basename "$LOG") for details" 2>/dev/null || true
fi

exit "$RC"