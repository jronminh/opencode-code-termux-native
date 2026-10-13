#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.opencode/opencode-native/update.sh by install.sh (and by
# install.sh's own first run, to download the initial binary). Invoked as
# `termux-update-opencode` by hand, or with --check-only from autocheck.sh
# on every new shell. See README.md ("Update / rollback").
set -uo pipefail

# The official OpenCode ARM64 musl asset is a single Bun executable. Its
# musl loader and C++ runtime are supplied separately from Alpine packages;
# invoking the loader explicitly keeps this runtime out of child Bionic tools.
REPO=${OPENCODE_REPO:-anomalyco/opencode}
RELEASE_API="https://api.github.com/repos/$REPO/releases"
OPENCODE_DIR="$HOME/.opencode"
DEST="$OPENCODE_DIR/opencode-native"
DEST_SHOW="${DEST/#$HOME/\~}"
BIN="$OPENCODE_DIR/opencode"
RUNTIME_DIR="$OPENCODE_DIR/runtime"
LD="$RUNTIME_DIR/ld-musl-aarch64.so.1"
VERSION_FILE="$OPENCODE_DIR/.opencode-version"
LOCKFILE="$DEST/.opencode-native.lock"
PINFILE="$DEST/.pinned-version"
REQUEST_TIMEOUT=20
ASSET=opencode-linux-arm64-musl.tar.gz
# The opencode archive is ~64MB. A flat --max-time is wrong for it on a slow
# mobile link — use --speed-limit/--speed-time instead: only abort if
# throughput actually stalls (stays below 1KB/s for 30s straight).
#
# --retry-all-errors --retry 5 -C -: a flaky mobile link can drop the
# connection partway through; -C - resumes from the bytes already on disk.
BIN_DOWNLOAD_OPTS=(--connect-timeout 8 --speed-limit 1024 --speed-time 30 --retry 5 --retry-delay 3 --retry-all-errors -C -)
SMALL_DOWNLOAD_OPTS=(--connect-timeout 5 --max-time $REQUEST_TIMEOUT)
tmp=""
CHECK_ONLY=0

notify() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  termux-notification --title "$1" --content "$2" 2>/dev/null || true
}

rollback() {
  exec 203>"$LOCKFILE"
  if ! flock -w 10 203; then
    echo "Another update/repair is in progress — try rollback again in a moment." >&2
    exit 1
  fi
  mv "$BIN" "$BIN.rejected" 2>/dev/null || true
  mv "$BIN.prev" "$BIN"
  [ -e "$VERSION_FILE.prev" ] && mv "$VERSION_FILE.prev" "$VERSION_FILE"
  echo "Rolled back to the previous binary. Quit the running opencode session and reopen it."
  if [ -e "$PINFILE" ]; then
    echo "note: a pin is set to $(cat "$PINFILE") — the next termux-update-opencode run will reinstall it; run --unpin first if that's not what you want."
  fi
  exit 0
}

report_fail() {
  local step="$1" detail="$2"
  if [ "$CHECK_ONLY" = "1" ]; then
    echo "Could not check for updates ($step) — skipping, terminal still works normally."
    exit 0
  fi
  local logfile; logfile="$DEST/update-fail-$(date +%Y%m%d-%H%M%S).log"
  {
    echo "=== opencode-native update.sh FAILED ==="
    echo "Time      : $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "Failed at : $step"
    echo
    echo "--- Details ---"
    echo "$detail"
    echo
    echo "--- Relevant variables ---"
    echo "RELEASE_API=$RELEASE_API"
    echo "OPENCODE_DIR=$OPENCODE_DIR"
    echo "LD=$LD"
    echo "VER=${VER:-<not determined>}"
    echo "CURRENT=${CURRENT:-<not determined>}"
    echo
    echo "--- State of $OPENCODE_DIR ---"
    ls -la "$OPENCODE_DIR" 2>&1
    if [ -n "$tmp" ] && [ -d "$tmp" ]; then
      echo
      echo "--- State of temp dir $tmp ---"
      ls -la "$tmp" 2>&1
    fi
    echo
    echo "--- Disk space ---"
    df -h "$OPENCODE_DIR" 2>&1
  } > "$logfile" 2>&1
  cat "$logfile" >&2
  echo "update.sh FAILED at step: $step" >&2
  echo "Full report saved to: $logfile" >&2
  notify "opencode-native: update failed" "Failed at: $step — see $logfile"
  [ -n "$tmp" ] && [ -d "$tmp" ] && rm -rf "$tmp"
  exit 1
}

run() {
  local desc="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    report_fail "$desc" "Command: $*
Exit code: $rc
Output:
$out"
  fi
  printf '%s' "$out"
}

# The archive is ~64MB, which can take a while on a slow link. Download in
# the background and print how much of $dest has landed so far, so a
# slow-but-alive transfer is visibly different from a stuck one.
download_binary() {
  local url="$1" dest="$2"
  local errlog; errlog=$(mktemp)
  curl -fSL "${BIN_DOWNLOAD_OPTS[@]}" -o "$dest" "$url" >"$errlog" 2>&1 &
  local pid=$! start
  start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    local size=0 mb elapsed
    [ -f "$dest" ] && size=$(wc -c < "$dest" 2>/dev/null)
    mb=$(( ${size:-0} / 1048576 ))
    elapsed=$(( $(date +%s) - start ))
    printf '\r  downloading opencode archive... %dMB (%ds)   ' "$mb" "$elapsed"
    sleep 1
  done
  wait "$pid"; local rc=$?
  printf '\r%*s\r' 50 ''
  if [ $rc -ne 0 ]; then
    report_fail "download aarch64 archive" "Command: curl -fSL ${BIN_DOWNLOAD_OPTS[*]} -o $dest $url
Exit code: $rc
Output:
$(cat "$errlog")"
  fi
  rm -f "$errlog"
}

mkdir -p "$DEST" "$RUNTIME_DIR"
# Keep the shared runtime resolver beside the staged updater. This also makes
# manual `bash ~/.opencode/opencode-native/update.sh` independent of the repo.
if [ -f "$DEST/runtime.sh" ]; then
  source "$DEST/runtime.sh"
elif [ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime.sh" ]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime.sh"
else
  report_fail "load runtime resolver" "runtime.sh is missing; re-run install.sh"
fi

# --- CLI: --rollback / --unpin / --pin -------------------------------
if [ "${1:-}" = "--rollback" ]; then
  [ -e "$BIN.prev" ] || { echo "No backup found at $BIN.prev — nothing to roll back to." >&2; exit 1; }
  rollback
fi

if [ "${1:-}" = "--unpin" ]; then
  [ -e "$PINFILE" ] || { echo "Not currently pinned."; exit 0; }
  exec 203>"$LOCKFILE"
  if ! flock -w 10 203; then echo "Another update/repair is in progress — try again in a moment." >&2; exit 1; fi
  rm -f "$PINFILE"
  echo "Unpinned — future updates resume tracking stable."
  exit 0
fi

if [ "${1:-}" = "--pin" ] && [ -z "${2:-}" ]; then
  exec 203>"$LOCKFILE"
  if ! flock -w 10 203; then echo "Another update/repair is in progress — try again in a moment." >&2; exit 1; fi
  PIN_CURRENT=""
  [ -e "$VERSION_FILE" ] && PIN_CURRENT=$(tr -d '[:space:]' < "$VERSION_FILE")
  if [ -z "$PIN_CURRENT" ]; then
    echo "Nothing installed to pin to yet — pass an explicit version: termux-update-opencode --pin <version>" >&2
    exit 1
  fi
  printf '%s' "$PIN_CURRENT" > "$PINFILE"
  echo "Pinned to $PIN_CURRENT (already installed, no download)."
  exit 0
fi

# --- determine target version ------------------------------------------
# --pin VERSION falls through into the normal pipeline below with VER forced.
PIN_REQUESTED=0
if [ "${1:-}" = "--pin" ] && [ -n "${2:-}" ]; then
  PIN_REQUESTED=1
  VER=$(printf '%s' "$2" | tr -d '[:space:]')
fi

CHECK_ONLY=0
[ "${1:-}" = "--check-only" ] && CHECK_ONLY=1
CHECK_OPTS=(--connect-timeout 3 --max-time 8)

PINNED=0
if [ "$PIN_REQUESTED" = "1" ]; then
  PINNED=1
elif [ -s "$PINFILE" ]; then
  PINNED=1
  VER=$(tr -d '[:space:]' < "$PINFILE")
else
  if [ "$CHECK_ONLY" = "1" ]; then
    REG_OUT=$(curl -fsSL "${CHECK_OPTS[@]}" "$RELEASE_API/latest" 2>&1); VER_RC=$?
  else
    REG_OUT=$(curl -fsSL "${SMALL_DOWNLOAD_OPTS[@]}" "$RELEASE_API/latest" 2>&1); VER_RC=$?
  fi
  if [ $VER_RC -ne 0 ]; then
    report_fail "fetch latest version from $RELEASE_API/latest" "Command: curl -fsSL $RELEASE_API/latest
Exit code: $VER_RC
Output:
$REG_OUT"
  fi
  VER=$(printf '%s' "$REG_OUT" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
  [ -n "$VER" ] || report_fail "fetch latest version" "Registry response had no .version — it may have changed shape. Raw response:
${REG_OUT:0:500}"
fi

[ "$PIN_REQUESTED" = "1" ] && PINNED=1

CURRENT=""
[ -e "$VERSION_FILE" ] && CURRENT=$(tr -d '[:space:]' < "$VERSION_FILE")

RUNTIME_OK=1
for f in "$BIN" "$RUNTIME_DIR/ld-musl-aarch64.so.1" \
         "$RUNTIME_DIR/libc.musl-aarch64.so.1" "$RUNTIME_DIR/libgcc_s.so.1" \
         "$RUNTIME_DIR/libstdc++.so.6"; do
  [ -s "$f" ] || RUNTIME_OK=0
done
if [ "$CURRENT" = "$VER" ] && [ "$RUNTIME_OK" = "1" ]; then
  if [ "$PINNED" = "1" ]; then
    printf '%s' "$VER" > "$PINFILE"
    [ "$CHECK_ONLY" = "1" ] || echo "Already on $VER — pinned."
  else
    [ "$CHECK_ONLY" = "1" ] || echo "Already on the latest version ($VER)."
  fi
  exit 0
fi

if [ "$CHECK_ONLY" = "1" ]; then
  if [ "$PINNED" = "1" ]; then
    echo "Installed version ($CURRENT) differs from pinned version ($VER). Run: termux-update-opencode"
  else
    echo "New version available: $VER. Run: termux-update-opencode"
  fi
  exit 0
fi

if [ "$PINNED" = "1" ]; then
  echo "Installed version ($CURRENT) differs from pinned version ($VER). Installing..."
else
  echo "New version available: $VER. Downloading..."
fi

# Locked from here on: this writes $OPENCODE_DIR/opencode, the same file
# autocheck.sh may run concurrently; both paths use the same lock.
exec 203>"$LOCKFILE"
if ! flock -w 10 203; then
  echo "Another update/repair is already running — try again in a moment." >&2
  exit 1
fi

tmp=$(mktemp -d)

# 1. Download the official release and verify the digest published by the
#    GitHub Releases API. No community npm wrapper or local ELF rewrite.
RELEASE_JSON=$(curl -fsSL "${SMALL_DOWNLOAD_OPTS[@]}" "$RELEASE_API/tags/v$VER" 2>&1) || \
  report_fail "fetch release metadata" "$RELEASE_JSON"
ASSET_URL=$(printf '%s' "$RELEASE_JSON" | jq -r --arg n "$ASSET" '.assets[] | select(.name==$n) | .browser_download_url' | head -1)
EXP=$(printf '%s' "$RELEASE_JSON" | jq -r --arg n "$ASSET" '.assets[] | select(.name==$n) | .digest' | sed 's/^sha256://' | head -1)
[ -n "$ASSET_URL" ] && [ -n "$EXP" ] || report_fail "locate official ARM64 musl asset" "Asset $ASSET or its SHA-256 digest is missing from v$VER."
download_binary "$ASSET_URL" "$tmp/release.tar.gz"
ACTUAL=$(sha256sum "$tmp/release.tar.gz" | awk '{print $1}')
[ "$EXP" = "$ACTUAL" ] || report_fail "verify official release checksum" "Expected: $EXP\nActual: $ACTUAL"

# 2. Extract the official single binary. The PT_INTERP remains its normal
#    /lib/ld-musl-aarch64.so.1; the wrapper invokes our loader explicitly.
mkdir -p "$tmp/bin"
run "extract official release archive" tar -xzf "$tmp/release.tar.gz" -C "$tmp/bin" >/dev/null
EXTRACTED="$tmp/bin"
[ -s "$EXTRACTED/opencode" ] || report_fail "verify official archive contents" "Missing opencode executable."

# 3. Fetch the four musl runtime objects from Alpine arm64. Alpine's
#    libstdc++/libgcc are musl-linked; Termux's libc++ and Debian's glibc
#    libstdc++ are not substitutes.
for pkg in musl libgcc libstdc++; do
  apk=$(fetch_alpine_pkg "$pkg" "$tmp/alpine") || report_fail "download Alpine $pkg runtime" "Could not resolve/download $pkg from $ALPINE_MIRROR/$ALPINE_BRANCH."
  mkdir -p "$tmp/apk/$pkg"
  run "extract Alpine $pkg" tar -xzf "$apk" -C "$tmp/apk/$pkg" >/dev/null
done
mkdir -p "$tmp/runtime"
cp -L "$tmp/apk/musl/lib/ld-musl-aarch64.so.1" "$tmp/runtime/ld-musl-aarch64.so.1"
cp -L "$tmp/apk/musl/lib/libc.musl-aarch64.so.1" "$tmp/runtime/libc.musl-aarch64.so.1"
cp -L "$tmp/apk/libgcc/usr/lib/libgcc_s.so.1" "$tmp/runtime/libgcc_s.so.1"
cp -L "$(find "$tmp/apk/libstdc++" -name 'libstdc++.so.6.*' -type f | sort | tail -1)" "$tmp/runtime/libstdc++.so.6"
for f in ld-musl-aarch64.so.1 libc.musl-aarch64.so.1 libgcc_s.so.1 libstdc++.so.6; do
  [ -s "$tmp/runtime/$f" ] || report_fail "verify musl runtime" "Missing runtime object: $f"
done

# 4. Smoke test with a CLEAN environment — the whole point of this repo is
#    that opencode runs WITHOUT leaked LD_PRELOAD/LD_LIBRARY_PATH. If the
#    staged bundle can't launch cleanly here, reject the update.
SMOKE_OUT=$(env -u LD_PRELOAD -u LD_LIBRARY_PATH TMPDIR="$HOME/.cache/opencode-tmp" \
  "$tmp/runtime/ld-musl-aarch64.so.1" --library-path "$tmp/runtime" "$EXTRACTED/opencode" --version 2>&1)
SMOKE_RC=$?
[ $SMOKE_RC -eq 0 ] || report_fail "smoke test new binary" "Command: staged opencode --version
Exit code: $SMOKE_RC
Output: $SMOKE_OUT"

# 5. Rotate + install.
[ -e "$BIN" ] && run "back up previous binary" cp -p "$BIN" "$BIN.prev" >/dev/null
[ -e "$VERSION_FILE" ] && run "back up previous version marker" cp -p "$VERSION_FILE" "$VERSION_FILE.prev" >/dev/null

# Install the binary and the self-contained musl runtime as one relocatable
# unit. The old flat runtime is left in place for manual rollback, but is no
# longer used by new installs.
run "install opencode" cp -f "$EXTRACTED/opencode" "$BIN"
for f in ld-musl-aarch64.so.1 libc.musl-aarch64.so.1 libgcc_s.so.1 libstdc++.so.6; do
  run "install $f" cp -f "$tmp/runtime/$f" "$RUNTIME_DIR/$f"
done
chmod 700 "$BIN"
printf '%s\n' "$VER" > "$VERSION_FILE"
rm -rf "$tmp"
tmp=""

# Refresh the epoll_pwait2 risk cache the wrapper / doctor read (the fix
# status can change with the binary, so recompute after every real update).
if strings "$BIN" 2>/dev/null | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2; then
  printf '1' > "$DEST/.epoll-fix-cache" 2>/dev/null
else
  printf '0' > "$DEST/.epoll-fix-cache" 2>/dev/null
fi

if [ "$PIN_REQUESTED" = "1" ]; then
  printf '%s' "$VER" > "$PINFILE"
  echo "Pinned to $VER."
fi

echo "Update successful: $VER."
echo "Previous binary kept at $BIN.prev — roll back with: termux-update-opencode --rollback"
echo "Quit the running opencode session and reopen it to use the new version."
