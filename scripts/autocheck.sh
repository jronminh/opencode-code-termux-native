#!/data/data/com.termux/files/usr/bin/bash
# Staged to ~/.opencode/opencode-native/autocheck.sh by install.sh, sourced
# from ~/.bashrc on every interactive shell. Self-heals silently, then
# hands off to update.sh --check-only. See README.md ("Self-check + self-heal").
OPENCODE_DIR="$HOME/.opencode"
BIN="$OPENCODE_DIR/opencode"
LD="$OPENCODE_DIR/ld-musl-aarch64.so.1"
DEST="$OPENCODE_DIR/opencode-native"
WRAPPER="$PREFIX/bin/opencode"
CONFIG="$HOME/.config/opencode/opencode.jsonc"
LOCKFILE="$DEST/.opencode-native.lock"
HISTORY_FILE="$DEST/.repatch-history"

notify() {
  command -v termux-notification >/dev/null 2>&1 || return 0
  termux-notification --title "$1" --content "$2" 2>/dev/null || true
}

unset LD_PRELOAD LD_LIBRARY_PATH

mkdir -p "$HOME/.cache/opencode-tmp" 2>/dev/null || true

if [ ! -e "$LD" ]; then
  echo "MISSING loader $LD — the musl libs are missing. Run install.sh / termux-update-opencode to reinstall." >&2
  return 0 2>/dev/null || exit 0
fi

if [ ! -e "$BIN" ]; then
  echo "MISSING binary $BIN — run termux-update-opencode to reinstall." >&2
  return 0 2>/dev/null || exit 0
fi

# Hard incompatibility: no binary can execute at all on a noexec $HOME.
MOUNT_LINE=$(awk -v h="$HOME" 'index(h, $2)==1 {print length($2), $0}' /proc/mounts 2>/dev/null | sort -n | tail -1)
if printf '%s' "$MOUNT_LINE" | grep -q noexec; then
  echo "FATAL: \$HOME is mounted noexec — opencode (or any binary) cannot execute here, patched or not. See README.md \"Troubleshooting\"." >&2
fi

# Informational: binary-translation layers can still run an aarch64 binary.
REPORTED_ABI=$(getprop ro.product.cpu.abi 2>/dev/null)
if [ -n "$REPORTED_ABI" ] && [ "$REPORTED_ABI" != "arm64-v8a" ]; then
  echo "NOTE: Android reports CPU ABI '$REPORTED_ABI' (not arm64-v8a) — if opencode misbehaves, this repo's aarch64-only assumptions may be why." >&2
fi

# Bun epoll_pwait2 risk cache (see README "Troubleshooting" #9). update.sh
# refreshes it on every install/update; this is a backfill for a binary
# that predates the cache existing at all.
EPOLL_CACHE="$DEST/.epoll-fix-cache"
if [ ! -e "$EPOLL_CACHE" ]; then
  if strings "$BIN" 2>/dev/null | grep -q BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2; then
    printf '1' > "$EPOLL_CACHE" 2>/dev/null
  else
    printf '0' > "$EPOLL_CACHE" 2>/dev/null
  fi
fi
if [ "$(cat "$EPOLL_CACHE" 2>/dev/null)" = "0" ]; then
  KVER=$(uname -r); KMAJOR=${KVER%%.*}; KREST=${KVER#*.}; KMINOR=${KREST%%.*}
  if { [ "$KMAJOR" -gt 5 ] 2>/dev/null || { [ "$KMAJOR" -eq 5 ] 2>/dev/null && [ "$KMINOR" -ge 11 ] 2>/dev/null; }; }; then
    echo "RISK: kernel $KVER is 5.11+ and the installed opencode build predates the epoll_pwait2 fix — it may segfault once its event loop starts. Run doctor.sh, or: termux-update-opencode" >&2
  fi
fi

# Writes to $BIN / global config happen inside this locked block so a second
# Termux tab opened at the same time can't race with this one (or with
# update.sh's own install step, which takes the same lock).
mkdir -p "$DEST"
(
  flock -w 5 202 || { echo "Another session is repairing the binary right now — skipping self-heal this time."; exit 0; }

  FIXED=0

  if [ ! -x "$BIN" ]; then
    chmod +x "$BIN" && FIXED=1
  fi

  CUR_INTERP=$(patchelf --print-interpreter "$BIN" 2>/dev/null || true)
  if [ "$CUR_INTERP" != "$LD" ]; then
    if patchelf --set-interpreter "$LD" "$BIN" 2>/dev/null; then
      chmod +x "$BIN"
      FIXED=1
      echo "Binary was overwritten with an unpatched build (usually by the in-process autoupdater) — re-patched the interpreter automatically."

      date +%s >> "$HISTORY_FILE"
      tail -n 50 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" 2>/dev/null && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
      NOW=$(date +%s)
      RECENT=$(awk -v now="$NOW" '{ if (now - $1 < 86400) c++ } END { print c+0 }' "$HISTORY_FILE" 2>/dev/null)
      if [ "${RECENT:-0}" -ge 2 ] 2>/dev/null; then
        echo "WARNING: the binary has needed re-patching ${RECENT} times in the last 24h — the autoupdater may not actually be off. Check the wrapper and your opencode.json (autoupdate: false)." >&2
        notify "opencode-native: repeated re-patching" "Re-patched ${RECENT}x in 24h — the autoupdater may not be off. Run doctor.sh."
      fi
    else
      echo "Binary could not be patched (may segfault on launch) — try update.sh." >&2
    fi
  fi

  # The two autoupdater off-switches (mirrors install.sh): the wrapper's env
  # var, and the global config's "autoupdate": false. Restore either if it
  # went missing.
  if ! grep -q 'OPENCODE_DISABLE_AUTOUPDATE=1' "$WRAPPER" 2>/dev/null; then
    echo "WARNING: $WRAPPER lost OPENCODE_DISABLE_AUTOUPDATE=1 — restore it by hand (re-run install.sh to rewrite the wrapper) so the autoupdater can't overwrite the patched binary." >&2
  fi

  if [ -e "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
    HAS_OFF=$(jq -r 'if has("autoupdate") then (.autoupdate | tostring) else "not-set" end' "$CONFIG" 2>/dev/null || echo err)
    if [ "$HAS_OFF" != "false" ]; then
      cp -f "$CONFIG" "$CONFIG.bak" 2>/dev/null
      settmp=$(mktemp)
      jq '.autoupdate = false' "$CONFIG" > "$settmp" 2>/dev/null && mv "$settmp" "$CONFIG" && FIXED=1 && \
        echo "autoupdate was not false in $CONFIG — re-added (previous version backed up to $CONFIG.bak)."
    fi
  fi

  if [ "$FIXED" = "1" ]; then
    echo "Auto-fixed. If opencode is running in another session, quit and reopen it to pick up the fix."
  fi
) 202>"$LOCKFILE"

if grep -q 'LD_LIBRARY_PATH=' "$WRAPPER" 2>/dev/null; then
  echo "WARNING: wrapper $WRAPPER is setting LD_LIBRARY_PATH via an environment variable (will crash Bionic bash/rg — the leak this repo exists to kill). Needs a manual fix to the --library-path form; re-run install.sh." >&2
fi

bash "$DEST/update.sh" --check-only