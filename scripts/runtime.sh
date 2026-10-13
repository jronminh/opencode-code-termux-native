# shellcheck shell=bash
# Shared paths + upstream sources for the staged scripts (update.sh,
# autocheck.sh, doctor.sh). Sourced, not executed (no shebang, on purpose).
#
# This is the ONE place that knows:
#   - where the binary and the musl runtime live (relocation-robust: every
#     path honors $OPENCODE_DIR / $OPENCODE_RUNTIME_DIR overrides, so a
#     moved $HOME or a test prefix works without re-patching), and
#   - where upstream bits come from (official opencode musl asset +
#     Alpine musl-runtime apks).
#
# The installed wrapper ($PREFIX/bin/opencode) intentionally does NOT source
# this file: it must keep working long after the repo checkout is gone, so
# it inlines the same two path lines instead. Keep them in sync.

: "${OPENCODE_DIR:=$HOME/.opencode}"
: "${OPENCODE_RUNTIME_DIR:=$OPENCODE_DIR/runtime}"
RUNTIME_DIR="$OPENCODE_RUNTIME_DIR"
BIN="$OPENCODE_DIR/opencode"
LOADER="$RUNTIME_DIR/ld-musl-aarch64.so.1"
# Current version marker. The pre-redesign marker
# (.opencode-termux-version, from the C04-wq community builds) is still
# honored as a fallback when reading, but new installs write VERSION_FILE.
VERSION_FILE="$OPENCODE_DIR/.opencode-version"
LEGACY_VERSION_FILE="$OPENCODE_DIR/.opencode-termux-version"
# Deb-native convention: all musl runtime libs live under $RUNTIME_DIR/ so
# the binary + its runtime forms a self-contained relocatable unit.
# The old flat layout (loader/libc/libstdc++/libgcc directly under $OPENCODE_DIR)
# is still supported via migration (see migrate_legacy_layout()), but new installs
# and updates target the runtime/ subdirectory.

# Official upstream: the musl asset published on every opencode release.
# sst/opencode is archived; anomalyco/opencode is the maintained fork that
# keeps publishing the same asset names. OPENCODE_REPO may point at either
# (or a mirror); update.sh tries it first, then the other one.
OPENCODE_REPO="${OPENCODE_REPO:-anomalyco/opencode}"
OPENCODE_REPO_FALLBACK="sst/opencode"
OPENCODE_ASSET="opencode-linux-arm64-musl.tar.gz"
# Version truth: the opencode-ai npm dist-tag (what `opencode upgrade`
# itself consults), with the GitHub latest-release API as fallback.
NPM_LATEST_URL="${NPM_LATEST_URL:-https://registry.npmjs.org/opencode-ai/latest}"

# Musl runtime truth: Alpine's aarch64 apks. No hardcoded package revisions:
# resolve the current version from APKINDEX at fetch time so a rebuild does
# not rot when Alpine revs musl/libgcc/libstdc++.
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_BRANCH="${ALPINE_BRANCH:-latest-stable}"

# current_version — print the installed version (new marker, else legacy).
current_version() {
  local v=""
  [ -s "$VERSION_FILE" ] && v=$(tr -d '[:space:]' < "$VERSION_FILE")
  if [ -z "$v" ] && [ -s "$LEGACY_VERSION_FILE" ]; then
    v=$(tr -d '[:space:]' < "$LEGACY_VERSION_FILE")
  fi
  printf '%s' "$v"
}

# migrate_legacy_layout — move a pre-redesign flat ~/.opencode/*.so* set
# (loader + libc/libstdc++/libgcc beside the binary) into $RUNTIME_DIR.
# Idempotent; prints the number of files moved.
# Also clean up any leftover flat-layout libs that should now be in runtime/.
migrate_legacy_layout() {
  local moved=0 f base
  mkdir -p "$RUNTIME_DIR"
  # Move any flat-layout musl runtime libs into runtime/
  for f in "$OPENCODE_DIR"/ld-musl-aarch64.so.1 \
           "$OPENCODE_DIR"/libc.musl-aarch64.so.1 \
           "$OPENCODE_DIR"/libgcc_s.so.1 \
           "$OPENCODE_DIR"/libstdc++.so.6 \
           "$OPENCODE_DIR"/libstdc++.so.6.0.33; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    # Only move if still sitting flat beside the binary (not already in runtime/)
    if [ "$f" != "$RUNTIME_DIR/$base" ]; then
      mv -f "$f" "$RUNTIME_DIR/$base" 2>/dev/null && moved=$((moved + 1))
    fi
  done
  # If runtime/ now has all required libs, we can optionally remove the flat
  # originals to avoid confusion (they're already at runtime/).
  printf '%s' "$moved"
}

# resolve_opencode_version — print the target upstream version: npm
# registry first, GitHub latest-release API second.
resolve_opencode_version() {
  local out ver
  out=$(curl -fsSL --connect-timeout 5 --max-time 20 "$NPM_LATEST_URL" 2>&1) && \
    ver=$(printf '%s' "$out" | jq -r '.version // empty' 2>/dev/null) && \
    [ -n "$ver" ] && { printf '%s' "$ver"; return 0; }
  local repo api
  for repo in "$OPENCODE_REPO" "$OPENCODE_REPO_FALLBACK"; do
    api="https://api.github.com/repos/$repo/releases/latest"
    out=$(curl -fsSL --connect-timeout 5 --max-time 20 "$api" 2>&1) && \
      ver=$(printf '%s' "$out" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//') && \
      [ -n "$ver" ] && { printf '%s' "$ver"; return 0; }
  done
  return 1
}

# opencode_asset_url VER — print the first reachable asset URL for VER,
# trying $OPENCODE_REPO then the fallback.
opencode_asset_url() {
  local ver="$1" repo url code
  for repo in "$OPENCODE_REPO" "$OPENCODE_REPO_FALLBACK"; do
    url="https://github.com/$repo/releases/download/v${ver}/$OPENCODE_ASSET"
    code=$(curl -fsSL -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 "$url" 2>&1 | tail -1)
    [ "$code" = "200" ] && { printf '%s' "$url"; return 0; }
  done
  return 1
}

# alpine_apk_version PKG INDEX_DIR — print PKG's version from an extracted
# APKINDEX description file (paragraphs: "P:<pkg>" ... "V:<ver>").
alpine_apk_version() {
  local pkg="$1" idx="$2"
  awk -v want="P:$pkg" '
    $0 == want { found=1; next }
    found && /^V:/ { sub(/^V:/, ""); print; exit }
    /^$/ { found=0 }
  ' "$idx"
}

# fetch_alpine_pkg PKG TMPDIR — download PKG's aarch64 apk into TMPDIR and
# print its path. Resolves the version via APKINDEX (no pinned revisions).
fetch_alpine_pkg() {
  local pkg="$1" tmp="$2" idx ver apk url
  mkdir -p "$tmp"
  [ -s "$tmp/APKINDEX.desc" ] || {
    curl -fsSL --connect-timeout 5 --max-time 30 \
      "$ALPINE_MIRROR/$ALPINE_BRANCH/main/aarch64/APKINDEX.tar.gz" \
      -o "$tmp/APKINDEX.tar.gz" || return 1
    tar -xzf "$tmp/APKINDEX.tar.gz" -C "$tmp" || return 1
    # APKINDEX.tar.gz contains APKINDEX.tar; unwrap the inner tar and use
    # its description file (the exact member name varies by Alpine mirror).
    if [ -f "$tmp/APKINDEX.tar" ]; then
      tar -xf "$tmp/APKINDEX.tar" -C "$tmp" 2>/dev/null || return 1
    fi
    [ -s "$tmp/APKINDEX.desc" ] || [ -s "$tmp/APKINDEX" ] || return 1
    [ -s "$tmp/APKINDEX.desc" ] || mv "$tmp/APKINDEX" "$tmp/APKINDEX.desc"
    [ -s "$tmp/APKINDEX.desc" ] || return 1
  }
  ver=$(alpine_apk_version "$pkg" "$tmp/APKINDEX.desc")
  [ -n "$ver" ] || return 1
  apk="${pkg}-${ver}.apk"
  url="$ALPINE_MIRROR/$ALPINE_BRANCH/main/aarch64/$apk"
  curl -fSL --connect-timeout 8 --speed-limit 1024 --speed-time 30 \
    --retry 5 --retry-delay 3 --retry-all-errors \
    -o "$tmp/$apk" "$url" || return 1
  printf '%s' "$tmp/$apk"
}
