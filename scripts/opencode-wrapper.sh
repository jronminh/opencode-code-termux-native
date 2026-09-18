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

[ -e "$BIN" ] || { echo "opencode binary missing at $BIN — run: termux-update-opencode" >&2; exit 1; }
[ -e "$LD" ]  || { echo "musl loader missing at $LD — run: bash ~/.opencode/opencode-native/update.sh" >&2; exit 1; }

# Direct exec does NOT work for this musl build: musl's loader can't find
# libstdc++.so.6 / libgcc_s.so.1 / libc.musl unless told where (an embedded
# rpath is off the table — patchelf section surgery corrupts Bun's appended
# payload, see README "Troubleshooting"). So exec the loader itself with
# --library-path: that scopes the search to THIS exec only, never leaking
# anything into opencode's children — the exact opposite of the npm
# launcher's exported LD_PRELOAD/LD_LIBRARY_PATH.
exec "$LD" --library-path "$OPENCODE_DIR" "$BIN" "$@"