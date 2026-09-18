#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.opencode/opencode-native/doctor.sh by install.sh. One-shot
# diagnostic dump — run this first, before guessing, whenever something's
# broken. See README.md ("Manual verification").
#
# Usage:
#   doctor.sh          human-readable dump (default)
#   doctor.sh --json   same checks, one JSON object on stdout (needs jq)
#   doctor.sh --fix    run self-heal (same locked repair block autocheck.sh
#                      runs on every new shell) first, then the normal dump
JSON=0
FIX=0
for arg in "$@"; do
  case "$arg" in
    --json) JSON=1 ;;
    --fix) FIX=1 ;;
    *) echo "usage: doctor.sh [--json] [--fix]" >&2; exit 2 ;;
  esac
done

DOCTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_DIR="$HOME/.opencode"
BIN="$OPENCODE_DIR/opencode"
LD="$OPENCODE_DIR/ld-musl-aarch64.so.1"
WRAPPER="$PREFIX/bin/opencode"
CONFIG="$HOME/.config/opencode/opencode.jsonc"

if [ "$FIX" = "1" ]; then
  if [ -f "$DOCTOR_DIR/autocheck.sh" ]; then
    bash "$DOCTOR_DIR/autocheck.sh"
  else
    echo "autocheck.sh not found next to doctor.sh — can't self-heal, showing diagnostics only." >&2
  fi
  [ "$JSON" = "1" ] || echo
fi

declare -A R
emit() {
  R["$1"]="$3"
  [ "$JSON" = "1" ] && return
  echo "$2"
  printf '%s\n' "$3"
}

emit arch "== arch ==" "$(uname -m)"

REPORTED_ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
UNAME_ARCH=$(uname -m)
if [ -z "$REPORTED_ABI" ]; then
  ABI_MSG="getprop not available or no ro.product.cpu.abi — cannot cross-check"
elif [ "$REPORTED_ABI" = "arm64-v8a" ] && [ "$UNAME_ARCH" = "aarch64" ]; then
  ABI_MSG="ok: uname ($UNAME_ARCH) matches Android's reported ABI ($REPORTED_ABI)"
else
  ABI_MSG="MISMATCH: uname says $UNAME_ARCH but Android reports ABI $REPORTED_ABI — possible binary-translation layer; this repo's aarch64-only assumptions may not hold"
fi
emit abi_cross_check "== ABI cross-check (uname vs Android-reported) ==" "$ABI_MSG"

KVER=$(uname -r)
KMAJOR=$(printf '%s' "$KVER" | cut -d. -f1)
KMINOR=$(printf '%s' "$KVER" | cut -d. -f2)
if [ "$KMAJOR" -eq "$KMAJOR" ] 2>/dev/null && [ "$KMINOR" -eq "$KMINOR" ] 2>/dev/null \
   && { [ "$KMAJOR" -gt 5 ] || { [ "$KMAJOR" -eq 5 ] && [ "$KMINOR" -ge 11 ]; }; }; then
  if strings "$BIN" 2>/dev/null | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2; then
    EPOLL_MSG="kernel $KVER is 5.11+ (would be at risk on an unpatched Bun)"$'\n'"ok: bundled Bun carries the upstream fix (flag string present in binary)"
  else
    EPOLL_MSG="kernel $KVER is 5.11+ (would be at risk on an unpatched Bun)"$'\n'"RISK: bundled Bun predates the fix (flag string absent) — see README.md \"Troubleshooting\" #9"
  fi
else
  EPOLL_MSG="ok: kernel $KVER is below the 5.11 risk threshold (moot regardless of Bun version)"
fi
emit epoll_risk "== kernel epoll_pwait2 risk (bun#32489, fixed upstream in bun#32490) ==" "$EPOLL_MSG"

emit prefix_home "== PREFIX / HOME ==" "$PREFIX"$'\n'"$HOME"

OPENCODE_PATH=$(command -v opencode 2>/dev/null)
if [ -n "$OPENCODE_PATH" ]; then
  OPENCODE_ON_PATH_MSG="$OPENCODE_PATH"$'\n'"$(readlink -f "$OPENCODE_PATH")"
else
  OPENCODE_ON_PATH_MSG="not found on PATH"
fi
emit opencode_on_path "== opencode on PATH ==" "$OPENCODE_ON_PATH_MSG"

BIN_LS=$(ls -l "$BIN" 2>/dev/null)
emit binary "== binary ==" "${BIN_LS:-MISSING $BIN}"

emit file_type "== file type ==" "$(file "$BIN" 2>/dev/null)"

INTERP=$(patchelf --print-interpreter "$BIN" 2>/dev/null)
emit interpreter "== interpreter ==" "${INTERP:-not patched?}"

LOADER_LS=$(ls -l "$LD" 2>/dev/null)
emit loader "== musl loader exists? ==" "${LOADER_LS:-MISSING LOADER: $LD}"

MUSL_LIBS=$(for f in libc.musl-aarch64.so.1 libstdc++.so.6 libgcc_s.so.1; do ls "$OPENCODE_DIR/$f" 2>/dev/null; done)
emit musl_libs "== musl runtime libs (beside the loader) ==" "${MUSL_LIBS:-one or more MISSING in $OPENCODE_DIR — update.sh will refuse to proceed}"

LEAKED=$(env | grep -i '^LD_')
emit leaked_ld_env "== leaked env LD_* (must be clean; a value here breaks Bionic children) ==" "${LEAKED:-clean}"

AUTOUPD=$(grep -s OPENCODE_DISABLE_AUTOUPDATE "$WRAPPER" 2>/dev/null)
CFG_AUTOUPD=$(jq -r 'if has("autoupdate") then (.autoupdate | tostring) else "not-set" end' "$CONFIG" 2>/dev/null || echo "unreadable-or-missing")
emit autoupdater_disabled "== autoupdater off? (wrapper env + global config) ==" "${AUTOUPD:-OPENCODE_DISABLE_AUTOUPDATE NOT in wrapper — risk of overwritten binary}"$'\n'"global config autoupdate: $CFG_AUTOUPD (want: false)"

CONFIG_BAK="$CONFIG.bak"
if [ -e "$CONFIG_BAK" ]; then
  CONFIG_BAK_MSG="backup exists: $CONFIG_BAK ($(date -r "$CONFIG_BAK" '+%Y-%m-%d %H:%M' 2>/dev/null))"$'\n'"restore with: cp $CONFIG_BAK $CONFIG"
else
  CONFIG_BAK_MSG="no backup yet — one is taken automatically the next time install.sh, autocheck.sh, or uninstall.sh writes opencode.json"
fi
emit config_backup "== ~/.config/opencode/opencode.json backup ==" "$CONFIG_BAK_MSG"

if command -v termux-notification >/dev/null 2>&1; then
  TERMUX_API_MSG="ok: termux-notification available — update-failure and repatch-escalation alerts will push a notification"
else
  TERMUX_API_MSG="not installed — update-failure/repatch-escalation alerts stay terminal-only. Optional: pkg install termux-api + install the Termux:API app from the same source as Termux itself"
fi
emit termux_api "== Termux:API notifications ==" "$TERMUX_API_MSG"

if grep -qs 'opencode-code-termux-native:adb-bridge' "$DOCTOR_DIR/adb-bridge.sh" 2>/dev/null || [ -e "$HOME/.config/opencode/skills/adb-bridge/SKILL.md" ]; then
  ADB_WIRED_MSG="skill installed — see the adb-bridge skill for usage; disable: termux-opencode-features disable adb-bridge"
else
  ADB_WIRED_MSG="not installed — optional, opt-in. Run: termux-opencode-features enable adb-bridge"
fi
if ! command -v dsh >/dev/null 2>&1; then
  ADB_CONN_MSG="termux-adb-bridge not installed (no dsh) — the adb-bridge skill needs it: ~/termux-adb-bridge/README.md"
elif timeout 8 dsh --check >/dev/null 2>&1; then
  ADB_DEV=$(timeout 8 dsh 'printf "%s (%s)" "$(getprop ro.product.model)" "$(getprop ro.serialno)"' 2>/dev/null)
  ADB_CONN_MSG="ok: shell-UID daemon reachable${ADB_DEV:+ ($ADB_DEV)} — screen/input access is live; stop the daemon when done"
else
  ADB_CONN_MSG="dsh installed, daemon not reachable — start it: ~/termux-adb-bridge/maintain/deploy.sh"
fi
emit adb_bridge "== ADB bridge (optional full-screen access via dsh, see adb-bridge skill) ==" "$ADB_WIRED_MSG"$'\n'"$ADB_CONN_MSG"

JOBS_DIR="$OPENCODE_DIR/opencode-native/jobs"
if ! command -v termux-job-scheduler >/dev/null 2>&1; then
  JOBS_MSG="termux-job-scheduler not found — pkg install termux-api + the Termux:API app to use termux-opencode-job"
else
  JOB_COUNT=0
  [ -d "$JOBS_DIR" ] && JOB_COUNT=$(find "$JOBS_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${JOB_COUNT:-0}" -gt 0 ]; then
    JOBS_MSG="ok: ${JOB_COUNT} job(s) registered — termux-opencode-job list for details"
  else
    JOBS_MSG="ok: available, no jobs scheduled yet — termux-opencode-job add <name> --prompt \"...\" --period-ms N"
  fi
fi
emit scheduled_jobs "== Scheduled jobs (termux-opencode-job) ==" "$JOBS_MSG"

TT_VER=$(dpkg -s termux-tools 2>/dev/null | awk -F': ' '/^Version/{print $2}')
APT_SRC=$(cat "$PREFIX"/etc/apt/sources.list 2>/dev/null; cat "$PREFIX"/etc/apt/sources.list.d/*.list 2>/dev/null)
if printf '%s' "$APT_SRC" | grep -q 'termux\.dev'; then
  APT_MSG="ok: apt sources point at a current Termux mirror"
else
  APT_MSG="WARN: apt sources don't reference termux.dev — possible stale/Play-Store install (Play Store builds are frozen and unsupported; see README)"
fi
emit termux_freshness "== Termux build freshness ==" \
  "TERMUX_VERSION=${TERMUX_VERSION:-unset (older Termux, or var not exported)}"$'\n'"termux-tools=${TT_VER:-not found}"$'\n'"$APT_MSG"

PATCHELF_VER=$(patchelf --version 2>/dev/null | awk '{print $2}')
LOADER_SHA=$(sha256sum "$LD" 2>/dev/null | cut -c1-8)
CUR_VERSIONS="musl-loader=${LOADER_SHA:-missing} patchelf=${PATCHELF_VER:-?}"
STATE="$OPENCODE_DIR/opencode-native/.doctor-last-versions"
LAST_VERSIONS=$(cat "$STATE" 2>/dev/null || true)
VERSIONS_MSG="$CUR_VERSIONS"
if [ -n "$LAST_VERSIONS" ] && [ "$LAST_VERSIONS" != "$CUR_VERSIONS" ]; then
  VERSIONS_MSG="$CUR_VERSIONS"$'\n'"CHANGED since last doctor.sh run (was: $LAST_VERSIONS) — the musl libs have been replaced since; quit and reopen opencode"
fi
printf '%s' "$CUR_VERSIONS" > "$STATE" 2>/dev/null
emit loader_patchelf_versions "== musl loader / patchelf versions (drift since last doctor.sh run) ==" "$VERSIONS_MSG"

MOUNT_LINE=$(awk -v h="$HOME" 'index(h, $2)==1 {print length($2), $0}' /proc/mounts 2>/dev/null | sort -n | tail -1)
if [ -z "$MOUNT_LINE" ]; then
  NOEXEC_MSG="could not determine mount options for \$HOME"
elif printf '%s' "$MOUNT_LINE" | grep -q noexec; then
  NOEXEC_MSG="RISK: \$HOME's filesystem is mounted noexec — binaries there cannot run"$'\n'"${MOUNT_LINE#* }"
else
  NOEXEC_MSG="ok: not noexec"
fi
emit home_noexec "== \$HOME mount options (noexec would break everything) ==" "$NOEXEC_MSG"

AVAIL_KB=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$AVAIL_KB" ]; then
  DISK_MSG="$((AVAIL_KB / 1024)) MiB available"
  [ "$AVAIL_KB" -lt 512000 ] && DISK_MSG="$DISK_MSG"$'\n'"WARN: under 500MiB free — the opencode binary alone is ~190MB; a download/update may fail partway"
else
  DISK_MSG="could not determine free space"
fi
emit disk_space "== disk space free at \$HOME ==" "$DISK_MSG"

VER_OUT=$(opencode --version 2>/dev/null)
VER_FILE_CONTENT=$(tr -d '[:space:]' < "$OPENCODE_DIR/.opencode-termux-version" 2>/dev/null)
if [ -z "$VER_OUT" ]; then
  VERSION_MSG="opencode does not run — see items above"
else
  VER_STATE="$OPENCODE_DIR/opencode-native/.last-opencode-version"
  PREV_SEEN="" LAST_SEEN=""
  if [ -f "$VER_STATE" ]; then
    PREV_SEEN=$(sed -n '1p' "$VER_STATE")
    LAST_SEEN=$(sed -n '2p' "$VER_STATE")
  fi
  VERSION_MSG="$VER_OUT"
  if [ -n "$LAST_SEEN" ] && [ "$LAST_SEEN" != "$VER_OUT" ]; then
    VERSION_MSG="$VER_OUT"$'\n'"UPDATED: opencode binary changed since the last session-start check (was: $LAST_SEEN) — this session is running a different build than last time"
    PREV_SEEN="$LAST_SEEN"
  fi
  if [ -n "$LAST_SEEN" ] && [ "$LAST_SEEN" != "$VER_OUT" ] || [ -z "$LAST_SEEN" ]; then
    { printf '%s\n' "$PREV_SEEN"; printf '%s\n' "$VER_OUT"; } > "$VER_STATE" 2>/dev/null
  fi
fi
emit version "== version (recognizes a binary change since the last check) ==" "$VERSION_MSG"$'\n'"release marker (.opencode-termux-version): ${VER_FILE_CONTENT:-<none>}"

PINFILE="$OPENCODE_DIR/opencode-native/.pinned-version"
if [ -s "$PINFILE" ]; then
  PIN=$(tr -d '[:space:]' < "$PINFILE")
  if [ -n "$VER_FILE_CONTENT" ] && [ "$VER_FILE_CONTENT" != "$PIN" ]; then
    PIN_MSG="MISMATCH: pinned to $PIN but installed release marker is $VER_FILE_CONTENT — run: termux-update-opencode"
  else
    PIN_MSG="ok: pinned to $PIN (matches installed release)"
  fi
else
  PIN_MSG="not pinned — tracking stable"
fi
emit version_pin "== version pin ==" "$PIN_MSG"

if [ "$JSON" = "1" ]; then
  JOBJ='{}'
  for key in "${!R[@]}"; do
    JOBJ=$(jq -cn --argjson o "$JOBJ" --arg k "$key" --arg v "${R[$key]}" '$o + {($k): $v}')
  done
  printf '%s\n' "$JOBJ"
fi