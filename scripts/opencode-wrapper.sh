#!/data/data/com.termux/files/usr/bin/bash
# Installed to $PREFIX/bin/opencode by install.sh, replacing the weak
# opencode-termux npm launcher (which leaked LD_PRELOAD/LD_LIBRARY_PATH into
# every child process and broke Bionic bash/rg). Every line here works
# around a specific Bionic/musl conflict — see README.md
# ("Troubleshooting") before changing anything.
unset LD_PRELOAD LD_LIBRARY_PATH

OPENCODE_DIR="$HOME/.opencode"
BIN="$OPENCODE_DIR/opencode"
LD="$OPENCODE_DIR/ld-musl-aarch64.so.1"

export TMPDIR="${OPENCODE_TMPDIR:-$HOME/.cache/opencode-tmp}"
mkdir -p "$TMPDIR" 2>/dev/null || true

# The in-process autoupdater would silently drop in an unpatched build that
# can't run on Bionic. Kill it here AND set "autoupdate": false in the global
# opencode.json (install.sh does both; this env var backs it up in-session).
export OPENCODE_DISABLE_AUTOUPDATE=1

# Termux cert store — the musl build has no system CA bundle of its own.
export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem

# Belt-and-suspenders for the Bun TLS-fault crash on epoll_pwait2 (oven-sh
# bun#32489, fixed upstream in bun#32490) — forces the same safe path the
# fix already takes, and protects any older bundled Bun that predates it.
export BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1

# Smart JSC heap sizing — the Termux OOM guard.
# Left alone, JSC sizes its heap off the device's FULL physical RAM and the
# TUI settles around ~785 MB resident. On a 7.4 GB phone that pushed total RAM
# use past Android's OOM threshold, so the kernel mass-killed processes and
# took Termux (plus every session) down with it. Forcing JSC to assume a
# smaller RAM makes it GC more eagerly: measured with
# ~/opencodium/tools/measure_rss.py, a 512 MB cap drops a fresh TUI from
# 785 MB to ~645 MB and it still boots. The cap is derived from MemTotal
# (~7%), clamped to 384–768 MB — below ~384 MB GC thrashes (measured *worse*,
# 696 MB at 384 / 659 MB at 256, not better) and above 768 MB the win fades.
# Set BUN_JSC_forceRAMSize yourself to override; ignored harmlessly if a
# given Bun build doesn't support the option.
if [ -z "${BUN_JSC_forceRAMSize:-}" ] && [ -r /proc/meminfo ]; then
  _memtotal_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
  case "$_memtotal_kb" in
    ''|*[!0-9]*) ;;
    *)
      _cap=$(( _memtotal_kb * 1024 / 100 * 7 ))
      [ "$_cap" -lt 402653184 ] && _cap=402653184
      [ "$_cap" -gt 805306368 ] && _cap=805306368
      export BUN_JSC_forceRAMSize="$_cap"
      ;;
  esac
  unset _memtotal_kb _cap
fi

[ -e "$BIN" ] || { echo "opencode binary missing at $BIN — run: termux-update-opencode" >&2; exit 1; }
[ -e "$LD" ]  || { echo "musl loader missing at $LD — run: bash ~/.opencode/opencode-native/update.sh" >&2; exit 1; }

# Direct exec does NOT work for this musl build: musl's loader can't find
# libstdc++.so.6 / libgcc_s.so.1 / libc.musl unless told where (an embedded
# rpath is off the table — patchelf section surgery corrupts Bun's appended
# payload, see README "Troubleshooting"). So exec the loader itself with
# --library-path: that scopes the search to THIS exec only, never leaking
# anything into opencode's children — the exact opposite of the npm
# launcher's exported LD_PRELOAD/LD_LIBRARY_PATH.

# Auto-resume the last session on a bare `opencode`.
# The RAM cap above makes the OOM kill far less likely, but it can still
# happen (opencode stays the biggest single process). When it does, a bare
# relaunch used to drop you into a fresh session; re-add --continue so the old
# one comes back. Only the truly bare form is touched — any subcommand or flag
# (run, serve, -s, --pure, ...) is passed through untouched, so explicit
# invocations behave exactly as before.
if [ "$#" -eq 0 ]; then
  set -- --continue
fi

exec "$LD" --library-path "$OPENCODE_DIR" "$BIN" "$@"