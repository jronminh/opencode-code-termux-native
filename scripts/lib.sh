# shellcheck shell=bash
# Shared helpers for install.sh / uninstall.sh — colored, numbered step
# banners with noisy command output suppressed to a log unless it fails.
# Meant to be sourced, not executed directly (no shebang, on purpose).
#
# Caller must set REPO_DIR, SCRIPT_NAME, and TOTAL before sourcing.

: "${LOG:=$(mktemp)}"
N=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; BLUE=''; RESET=''
fi

on_err() {
  echo >&2
  echo "${RED}${BOLD}${SCRIPT_NAME} failed${RESET} at line $1" >&2
  echo "${DIM}  see the last output above, or the full log at: $LOG${RESET}" >&2
}
trap 'on_err $LINENO' ERR

fail() { echo "${RED}${BOLD}$*${RESET}" >&2; exit 1; }

# check_platform — shared aarch64/Termux precondition.
check_platform() {
  [ "$(uname -m)" = "aarch64" ] || fail "this installer only supports aarch64 (found $(uname -m))"
  [ -n "${PREFIX:-}" ] && [ -n "${HOME:-}" ] || fail "doesn't look like Termux (PREFIX or HOME unset)"
  command -v pkg >/dev/null 2>&1 || fail "'pkg' not found — this installer is Termux-only"
}

# kernel_is_risky — true (exit 0) if the running kernel is >= 5.11. Same
# Bun epoll_pwait2 TLS-fault territory as claude (opencode is Bun-based
# too): the kernel-version gate decides whether Bun attempts epoll_pwait2,
# and routing that attempt through a foreign libc's generic syscall()
# wrapper faults on a TLS access before the syscall ever runs. Fixed
# upstream in oven-sh/bun#32490 (raw-asm syscall + BUN_FEATURE_FLAG_DISABLE_
# EPOLL_PWAIT2). Pair with epoll_fix_present() to know if the installed
# binary needs to worry. Kernel version is fixed at manufacture — the
# Android version in Settings tells you nothing here.
kernel_is_risky() {
  local kver kmajor kminor
  kver=$(uname -r)
  kmajor=$(printf '%s' "$kver" | cut -d. -f1)
  kminor=$(printf '%s' "$kver" | cut -d. -f2)
  [ "$kmajor" -eq "$kmajor" ] 2>/dev/null || return 1
  [ "$kminor" -eq "$kminor" ] 2>/dev/null || return 1
  [ "$kmajor" -gt 5 ] || { [ "$kmajor" -eq 5 ] && [ "$kminor" -ge 11 ]; }
}

# epoll_fix_present BINARY — true if BINARY carries the upstream Bun fix:
# the feature-flag string is only linked in on a Bun build that has it.
epoll_fix_present() {
  strings "$1" 2>/dev/null | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2
}

# Markers delimiting our managed block inside the user's global opencode
# environment notes file, which may contain unrelated content of their own
# above/below it that must never be touched.
ENV_NOTES_BEGIN="<!-- opencode-code-termux-native:begin -->"
ENV_NOTES_END="<!-- opencode-code-termux-native:end -->"

# env_notes_upsert TEMPLATE_FILE TARGET_FILE — insert TEMPLATE_FILE's
# content into TARGET_FILE if our markers aren't there yet, or replace the
# existing marked block in place if they are. Never touches anything
# outside the markers.
env_notes_upsert() {
  local tmpl="$1" target="$2"
  mkdir -p "$(dirname "$target")"
  touch "$target"
  if grep -qF "$ENV_NOTES_BEGIN" "$target"; then
    awk -v begin="$ENV_NOTES_BEGIN" -v end="$ENV_NOTES_END" -v tmpl="$tmpl" '
      $0 == begin { while ((getline line < tmpl) > 0) print line; close(tmpl); skip=1; next }
      $0 == end   { skip=0; next }
      skip        { next }
      { print }
    ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
  else
    { [ -s "$target" ] && printf '\n'; cat "$tmpl"; } >> "$target"
  fi
}

# env_notes_remove TARGET_FILE — remove our marked block if present.
env_notes_remove() {
  local target="$1"
  [ -e "$target" ] || return 0
  grep -qF "$ENV_NOTES_BEGIN" "$target" || return 0
  awk -v begin="$ENV_NOTES_BEGIN" -v end="$ENV_NOTES_END" '
    $0 == begin { skip=1; next }
    $0 == end   { skip=0; next }
    skip        { next }
    { print }
  ' "$target" > "$target.tmp" && mv "$target.tmp" "$target"
}

# shortp PATH — shorten an absolute path for display: $HOME -> ~, $PREFIX ->
# the literal string "$PREFIX". Only for printing; never use the result for
# actual file operations.
shortp() {
  local p="$1"
  # shellcheck disable=SC2088,SC2016
  case "$p" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${p#"$HOME"/}" ;;
    "$PREFIX"/*) printf '$PREFIX/%s' "${p#"$PREFIX"/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# Fixed width so the "ok"/"FAILED" column lines up across steps regardless
# of how long each step's description is.
STEP_DESC_WIDTH=62

# step_banner "description" — print just the "[n/N] description ...." part.
step_banner() {
  local desc="$1"
  local pad=$(( STEP_DESC_WIDTH - ${#desc} ))
  [ "$pad" -lt 1 ] && pad=1
  local dots; dots=$(printf '%*s' "$pad" '' | tr ' ' '.')
  printf '%s[%d/%d]%s %s %s%s%s ' "${BLUE}${BOLD}" "$N" "$TOTAL" "$RESET" "$desc" "$DIM" "$dots" "$RESET"
}

# step "description" cmd [args...]
step() {
  N=$((N + 1))
  local desc="$1"; shift
  step_banner "$desc"
  if "$@" >>"$LOG" 2>&1; then
    printf '%sok%s\n' "$GREEN" "$RESET"
  else
    local rc=$?
    printf '%sFAILED%s\n' "$RED" "$RESET"
    echo "${DIM}--- last 30 lines of $LOG ---${RESET}"
    tail -n 30 "$LOG"
    echo "${DIM}-----------------------------${RESET}"
    exit "$rc"
  fi
}

# feature-hooks — shared by install.sh / uninstall.sh (which have REPO_DIR
# set) and sourced from THIS repo copy. The standalone termux-opencode-
# features command sources the STAGED copy at
# ~/.opencode/opencode-native/feature-hooks.sh instead, so it keeps working
# long after the repo checkout is gone or out of date.
if [ -n "${REPO_DIR:-}" ] && [ -f "$REPO_DIR/scripts/feature-hooks.sh" ]; then
  # shellcheck source=scripts/feature-hooks.sh
  source "$REPO_DIR/scripts/feature-hooks.sh"
fi