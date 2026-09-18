#!/data/data/com.termux/files/usr/bin/bash
# Installed to $PREFIX/bin/termux-claude-job by install.sh. Manages headless
# `claude -p` runs scheduled through Android's real JobScheduler (via
# termux-job-scheduler) instead of plain cron, so a scheduled run actually
# wakes the device and survives Doze — plain cron/background loops get
# killed by Android the moment the screen locks. See README.md ("Extra
# features" -> "Scheduled jobs").
set -u
DEST="$HOME/.claude/claude-native"
JOBS_DIR="$DEST/jobs"
mkdir -p "$JOBS_DIR"

usage() {
  cat <<'EOF'
usage:
  termux-claude-job add <name> --prompt "TEXT" [--prompt-file PATH]
                     [--period-ms N] [--cwd DIR] [--persisted]
                     [--charging] [--network any|unmetered|cellular|not_roaming|none]
      Schedule a headless `claude -p` run. Re-running add with the same
      name replaces its schedule (same underlying job-id). --period-ms
      omitted or 0 means one-shot; Android clamps periodic jobs to a
      15-minute (900000ms) minimum. --cwd defaults to the current directory.
  termux-claude-job list
      List jobs this tool knows about, plus Android's own pending-job state.
  termux-claude-job remove <name>
      Cancel the Android job and forget it.
  termux-claude-job run <name>
      Trigger it once right now, synchronously (for testing — does not
      touch or consume the real schedule).
  termux-claude-job log <name>
      Show the last 50 lines of its output log.
EOF
}

# job_id NAME — a stable int derived from the job name. termux-job-scheduler
# requires an int job-id (not a name), and re-adding the same name must
# reuse the same id so termux-job-scheduler's own "overwrite any previous
# job with the same id" behavior does the right thing on an update instead
# of leaving the old schedule running alongside a new one.
job_id() {
  printf '%s' "$1" | cksum | awk '{print $1 % 2000000000}'
}

cmd_add() {
  local name="${1:?job name required}"; shift
  local prompt="" prompt_file="" period_ms=0 cwd="$PWD" persisted=false charging=false network="any"
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt) prompt="$2"; shift 2 ;;
      --prompt-file) prompt_file="$2"; shift 2 ;;
      --period-ms) period_ms="$2"; shift 2 ;;
      --cwd) cwd="$2"; shift 2 ;;
      --persisted) persisted=true; shift ;;
      --charging) charging=true; shift ;;
      --network) network="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
  done
  if [ -n "$prompt_file" ]; then
    [ -e "$prompt_file" ] || { echo "prompt file not found: $prompt_file" >&2; exit 1; }
    prompt=$(cat "$prompt_file")
  fi
  [ -n "$prompt" ] || { echo "--prompt or --prompt-file required" >&2; exit 1; }
  cwd=$(cd "$cwd" 2>/dev/null && pwd) || { echo "cwd not found: $cwd" >&2; exit 1; }
  case "$period_ms" in ''|*[!0-9]*) echo "--period-ms must be a non-negative integer" >&2; exit 1 ;; esac
  if [ "$period_ms" -gt 0 ] && [ "$period_ms" -lt 900000 ]; then
    echo "note: Android clamps periodic jobs to a 15-minute (900000ms) minimum since Android N — requested ${period_ms}ms will actually run every 15min." >&2
  fi

  local id; id=$(job_id "$name")
  jq -n --arg prompt "$prompt" --arg cwd "$cwd" --argjson id "$id" --argjson period_ms "$period_ms" \
    '{prompt: $prompt, cwd: $cwd, id: $id, period_ms: $period_ms}' > "$JOBS_DIR/$name.json"

  local stub="$JOBS_DIR/$name.sh"
  printf '#!/data/data/com.termux/files/usr/bin/bash\nexec %q %q\n' "$DEST/claude-job-runner.sh" "$name" > "$stub"
  chmod 700 "$stub"

  local args=(--script "$stub" --job-id "$id" --network "$network" --charging "$charging" --persisted "$persisted")
  [ "$period_ms" -gt 0 ] && args+=(--period-ms "$period_ms")
  termux-job-scheduler "${args[@]}"

  if [ "$period_ms" -gt 0 ]; then
    echo "Scheduled '$name' (job-id $id), every ${period_ms}ms."
  else
    echo "Scheduled '$name' (job-id $id), one-shot — runs once when constraints (network/charging) are met."
  fi
}

cmd_list() {
  if ! ls "$JOBS_DIR"/*.json >/dev/null 2>&1; then
    echo "no jobs registered."
  else
    printf '%-20s %-12s %-12s %s\n' "NAME" "JOB-ID" "PERIOD" "CWD"
    local f name id period cwd
    for f in "$JOBS_DIR"/*.json; do
      name=$(basename "$f" .json)
      id=$(jq -r '.id' "$f")
      period=$(jq -r '.period_ms' "$f")
      cwd=$(jq -r '.cwd' "$f")
      [ "$period" -gt 0 ] && period="${period}ms" || period="one-shot"
      printf '%-20s %-12s %-12s %s\n' "$name" "$id" "$period" "$cwd"
    done
  fi
  echo
  echo "--- termux-job-scheduler --pending (raw Android state) ---"
  termux-job-scheduler --pending
}

cmd_remove() {
  local name="${1:?job name required}"
  local f="$JOBS_DIR/$name.json"
  [ -e "$f" ] || { echo "no such job: $name" >&2; exit 1; }
  local id; id=$(jq -r '.id' "$f")
  termux-job-scheduler --cancel --job-id "$id" || true
  rm -f "$f" "$JOBS_DIR/$name.sh" "$JOBS_DIR/$name.log"
  echo "Removed '$name' (job-id $id)."
}

cmd_run() {
  local name="${1:?job name required}"
  [ -e "$JOBS_DIR/$name.json" ] || { echo "no such job: $name" >&2; exit 1; }
  "$DEST/claude-job-runner.sh" "$name"
}

cmd_log() {
  local name="${1:?job name required}"
  local f="$JOBS_DIR/$name.log"
  [ -e "$f" ] || { echo "no log yet for '$name' — it hasn't run."; exit 0; }
  tail -n 50 "$f"
}

case "${1:-}" in
  add)    shift; cmd_add "$@" ;;
  list)   cmd_list ;;
  remove) shift; cmd_remove "$@" ;;
  run)    shift; cmd_run "$@" ;;
  log)    shift; cmd_log "$@" ;;
  -h|--help|"") usage; [ "${1:-}" = "" ] && exit 1 || exit 0 ;;
  *) echo "unknown command: $1" >&2; usage; exit 2 ;;
esac
