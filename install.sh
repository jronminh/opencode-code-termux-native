#!/data/data/com.termux/files/usr/bin/bash
# Installs (and updates) OpenCode natively on Termux/Android.
#
# Takes the aarch64 musl build of opencode (published by the
# C04-wq/opencode-termux project), pins its ELF interpreter to the musl
# loader that ships beside it, and wraps launch in a loader
# --library-path call so the musl runtime never leaks into Bionic child
# processes (the leak that breaks bash/rg under the stock opencode-termux
# launcher). See README.md.
#
# Downloads via download.sh; the extract/patch/install steps live here.
# Safe to re-run: every step is idempotent. To undo everything, see
# uninstall.sh.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="install.sh"
TOTAL=8
# shellcheck source=lib.sh
source "$REPO_DIR/lib.sh"

OPENCODE_DIR="$HOME/.opencode"
DEST="$OPENCODE_DIR/opencode-native"
CONFIG_DIR="$HOME/.config/opencode"
CONFIG="$CONFIG_DIR/opencode.jsonc"
ENV_NOTES="$CONFIG_DIR/environment.md"
BIN_DIR="$PREFIX/bin"
BIN="$OPENCODE_DIR/opencode"
LD="$OPENCODE_DIR/ld-musl-aarch64.so.1"
VERSION_FILE="$OPENCODE_DIR/.opencode-termux-version"
REQUIRED_FILES=(opencode ld-musl-aarch64.so.1 libc.musl-aarch64.so.1 libgcc_s.so.1 libstdc++.so.6 libstdc++.so.6.runtime)

install_packages() {
  # Fast path for the update path: `termux-update-opencode` re-runs install.sh
  # and `pkg update` is slow. If everything we need is already present, skip.
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 &&
     command -v patchelf >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
    return 0
  fi
  # --force-confdef/--force-confold: this runs unattended (no TTY to answer
  # dpkg's "keep your modified conffile?" prompt), so auto-keep the existing
  # config instead of hanging/failing on upgrades like openssl's.
  local opts=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  pkg install "${opts[@]}" curl jq patchelf libc++ ripgrep tar coreutils file ca-certificates resolv-conf &&
    pkg update -y 2>/dev/null || true &&
    pkg install "${opts[@]}" curl jq patchelf libc++ ripgrep tar coreutils file ca-certificates resolv-conf &&
    command -v patchelf >/dev/null &&
    # patchelf is linked against a specific libc++ ABI; a stale libc++ left
    # over from before a termux-tools update makes it present on PATH but
    # unable to actually run ("CANNOT LINK EXECUTABLE ... cannot locate
    # symbol"). Force libc++ current to match, then prove patchelf runs.
    pkg install "${opts[@]}" --reinstall libc++ &&
    patchelf --version >/dev/null 2>&1
}

# Stage the scripts themselves so `termux-update-opencode` (the staged
# install.sh) keeps working after the repo checkout is gone or out of date.
stage_scripts() {
  mkdir -p "$DEST"
  local f
  for f in lib.sh download.sh install.sh environment.md.template; do
    [ "$REPO_DIR/$f" -ef "$DEST/$f" ] && continue
    install -m 700 "$REPO_DIR/$f" "$DEST/$f"
  done
}

# download.sh fetches the verified archive; this extracts it, patches the
# ELF interpreter to the bundled musl loader, smoke tests, and installs.
install_binary() {
  local current latest tmp f ver
  current=""
  [ -e "$VERSION_FILE" ] && current=$(tr -d '[:space:]' < "$VERSION_FILE")
  latest=$(bash "$REPO_DIR/download.sh" --check 2>/dev/null) || latest=""

  # Couldn't reach the registry. If a build is already installed, keep it
  # (an offline `termux-update-opencode` shouldn't break a working setup);
  # otherwise we genuinely need the network to get started.
  if [ -z "$latest" ]; then
    if [ -e "$BIN" ] && [ -e "$LD" ]; then
      echo "could not reach the registry (offline?) — keeping installed build${current:+ ($current)}"
      return 0
    fi
    fail "could not reach the opencode registry — check your connection and re-run"
  fi

  if [ "$current" = "$latest" ] && [ -e "$BIN" ] && [ -e "$LD" ]; then
    echo "already on opencode $latest"
    return 0
  fi

  tmp=$(mktemp -d)
  bash "$REPO_DIR/download.sh" "$tmp"
  ver=$(tr -d '[:space:]' < "$tmp/.opencode-termux-version")

  tar -xzf "$tmp/opencode-termux-aarch64.tar.gz" -C "$tmp"
  for f in "${REQUIRED_FILES[@]}"; do
    [ -s "$tmp/$f" ] || fail "release archive is missing $f"
  done

  # Pin the interpreter to the musl loader that lives beside the binary.
  patchelf --set-interpreter "$LD" "$tmp/opencode"

  # Smoke test with a CLEAN environment — the whole point is that opencode
  # runs WITHOUT leaked LD_PRELOAD/LD_LIBRARY_PATH. Reject a build that can't.
  env -u LD_PRELOAD -u LD_LIBRARY_PATH TMPDIR="$HOME/.cache/opencode-tmp" \
    "$tmp/ld-musl-aarch64.so.1" --library-path "$tmp" "$tmp/opencode" --version >/dev/null 2>&1 \
    || fail "staged binary failed its smoke test (opencode --version)"

  [ -e "$BIN" ] && cp -p "$BIN" "$BIN.prev"
  for f in "${REQUIRED_FILES[@]}"; do
    mv "$tmp/$f" "$OPENCODE_DIR/$f"
  done
  printf '%s\n' "$ver" > "$VERSION_FILE"
  rm -rf "$tmp"
  echo "installed opencode $ver"
}

# The wrapper execs the musl loader with --library-path (scoped to that one
# exec, never inherited) instead of exporting LD_PRELOAD/LD_LIBRARY_PATH the
# way the stock opencode-termux launcher does — that leak is what breaks
# Bionic bash/ripgrep under opencode. It also kills the in-process
# autoupdater (which would drop in an unpatched, unrunnable build) and
# applies the Termux-specific tuning opencode needs to survive on Android.
install_wrapper() {
  cat > "$BIN_DIR/opencode" <<'WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
# opencode-code-termux-native wrapper (generated by install.sh)
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

# Smart JSC heap sizing — the Termux OOM guard. Left alone, JSC sizes its
# heap off the device's FULL physical RAM and the TUI settles around ~785 MB
# resident, which on a ~7.4 GB phone pushed total RAM past Android's OOM
# threshold and the kernel mass-killed processes. Forcing JSC to assume a
# smaller RAM makes it GC more eagerly; a 512 MB cap drops a fresh TUI from
# ~785 MB to ~645 MB and it still boots. The cap is ~7% of MemTotal, clamped
# to 384–768 MB. Set BUN_JSC_forceRAMSize yourself to override.
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
[ -e "$LD" ]  || { echo "musl loader missing at $LD — run: termux-update-opencode" >&2; exit 1; }

# Direct exec does NOT work for this musl build: musl's loader can't find
# libstdc++.so.6 / libgcc_s.so.1 / libc.musl unless told where (an embedded
# rpath is off the table — patchelf section surgery corrupts Bun's appended
# payload). So exec the loader itself with --library-path: that scopes the
# search to THIS exec only, never leaking into opencode's children.

# Auto-resume the last session on a bare `opencode`: after an OOM kill a bare
# relaunch used to drop you into a fresh session. Only the truly bare form is
# touched — any subcommand or flag is passed through untouched.
if [ "$#" -eq 0 ]; then
  set -- --continue
fi

exec "$LD" --library-path "$OPENCODE_DIR" "$BIN" "$@"
WRAPPER
  chmod 700 "$BIN_DIR/opencode"

  cat > "$BIN_DIR/termux-update-opencode" <<'CMD'
#!/data/data/com.termux/files/usr/bin/bash
exec "$HOME/.opencode/opencode-native/install.sh" "$@"
CMD
  chmod 700 "$BIN_DIR/termux-update-opencode"
}

# opencode's own config has an autoupdate knob, and the wrapper exports
# OPENCODE_DISABLE_AUTOUPDATE=1 too — both together stop the in-process
# autoupdater from silently dropping in an unpatched build that can't run
# on Bionic.
disable_autoupdater() {
  mkdir -p "$CONFIG_DIR"
  if [ -e "$CONFIG" ]; then
    cp -f "$CONFIG" "$CONFIG.bak"
  else
    printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$CONFIG"
  fi
  local tmp; tmp=$(mktemp)
  jq '.autoupdate = false' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

# Merge our managed block into the global environment notes (preserving any
# user content outside the begin/end markers).
install_env_notes() {
  env_notes_upsert "$REPO_DIR/environment.md.template" "$ENV_NOTES"
}

# Point opencode's global instructions at the environment notes so every
# session knows it's on a patched-musl/Termux setup. Preserves any existing
# instructions.
point_instructions() {
  mkdir -p "$CONFIG_DIR"
  if [ -e "$CONFIG" ]; then
    cp -f "$CONFIG" "$CONFIG.bak"
  else
    printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$CONFIG"
  fi
  local tmp; tmp=$(mktemp)
  jq --arg f "$ENV_NOTES" '.instructions = (((.instructions // []) + [$f]) | unique)' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

echo "${BOLD}opencode-code-termux-native${RESET} — installing OpenCode natively on Termux"
echo

step "checking platform"                                   check_platform
step "installing Termux packages"                          install_packages
step "staging scripts at $(shortp "$DEST")"                stage_scripts
step "downloading + patching the opencode binary"          install_binary
step "installing wrapper + termux-update-opencode"         install_wrapper
step "disabling the in-process autoupdater"                disable_autoupdater
step "installing environment notes"                        install_env_notes
step "pointing opencode at the environment notes"          point_instructions

rm -f "$LOG"
trap - ERR
echo
echo "${GREEN}${BOLD}install complete${RESET}"
echo "  ${DIM}1.${RESET} open a NEW Termux session (or run: exec bash)"
echo "  ${DIM}2.${RESET} run: ${BOLD}opencode${RESET}"
echo
printf '  %-18s: %s\n' "update"    "${DIM}termux-update-opencode${RESET}"
printf '  %-18s: %s\n' "uninstall" "${DIM}bash $(shortp "$REPO_DIR")/uninstall.sh${RESET}"
echo
echo "  The wrapper locks the autoupdater off, so an in-process update can't"
echo "  silently replace the patched binary with an unpatched one. Update"
echo "  deliberately with: termux-update-opencode."
