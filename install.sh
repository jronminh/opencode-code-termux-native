#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO="${OPENCODE_REPO:-anomalyco/opencode}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_BRANCH="${ALPINE_BRANCH:-latest-stable}"
HOME_DIR="${HOME:?HOME is not set}"
OPENCODE_DIR="$HOME_DIR/.opencode"
RUNTIME_DIR="$OPENCODE_DIR/runtime"
PREFIX_DIR="${PREFIX:?Run this from Termux}"
API="https://api.github.com/repos/$REPO/releases"
ASSET="opencode-linux-arm64-musl.tar.gz"
TMP=""

die() { echo "install: $*" >&2; exit 1; }
cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

[ "$(uname -m)" = "aarch64" ] || die "this installer requires an aarch64 Termux device"
command -v pkg >/dev/null 2>&1 || die "pkg was not found; this is not Termux"

echo "Installing OpenCode official ARM64 musl runtime..."
pkg install -y curl jq tar coreutils binutils ca-certificates >/dev/null

TMP=$(mktemp -d)
mkdir -p "$OPENCODE_DIR"
release_json=$(curl -fsSL --retry 3 --connect-timeout 10 "$API/latest") || die "could not fetch the latest GitHub release"
version=$(printf '%s' "$release_json" | jq -r '.tag_name // empty' | sed 's/^v//')
asset_url=$(printf '%s' "$release_json" | jq -r --arg n "$ASSET" '.assets[] | select(.name==$n) | .browser_download_url' | head -1)
expected=$(printf '%s' "$release_json" | jq -r --arg n "$ASSET" '.assets[] | select(.name==$n) | .digest' | sed 's/^sha256://' | head -1)
[ -n "$version" ] && [ -n "$asset_url" ] && [ -n "$expected" ] || die "release $ASSET or its SHA-256 digest was not found"

echo "Downloading OpenCode $version..."
curl -fL --retry 5 --retry-all-errors --connect-timeout 10 -o "$TMP/opencode.tar.gz" "$asset_url"
actual=$(sha256sum "$TMP/opencode.tar.gz" | awk '{print $1}')
[ "$actual" = "$expected" ] || die "OpenCode checksum mismatch"

mkdir "$TMP/opencode"
tar -xzf "$TMP/opencode.tar.gz" -C "$TMP/opencode"
[ -s "$TMP/opencode/opencode" ] || die "release archive has no opencode binary"

apk_version() {
  awk -v want="P:$1" '$0 == want { found=1; next } found && /^V:/ { sub(/^V:/, ""); print; exit } /^$/ { found=0 }' "$TMP/APKINDEX.desc"
}
fetch_apk() {
  local package="$1" version url
  version=$(apk_version "$package")
  [ -n "$version" ] || die "could not resolve Alpine package $package"
  url="$ALPINE_MIRROR/$ALPINE_BRANCH/main/aarch64/${package}-${version}.apk"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 10 -o "$TMP/${package}.apk" "$url"
  mkdir -p "$TMP/apk/$package"
  tar -xzf "$TMP/${package}.apk" -C "$TMP/apk/$package"
}

echo "Downloading musl runtime from Alpine..."
curl -fsSL --retry 3 --connect-timeout 10 "$ALPINE_MIRROR/$ALPINE_BRANCH/main/aarch64/APKINDEX.tar.gz" -o "$TMP/APKINDEX.tar.gz"
mkdir "$TMP/index"
tar -xzf "$TMP/APKINDEX.tar.gz" -C "$TMP/index"
tar -xf "$TMP/index/APKINDEX.tar" -C "$TMP" || die "could not read Alpine package index"
[ -s "$TMP/APKINDEX.desc" ] || [ -s "$TMP/APKINDEX" ] || die "Alpine package index has no description file"
[ -s "$TMP/APKINDEX.desc" ] || mv "$TMP/APKINDEX" "$TMP/APKINDEX.desc"
fetch_apk musl
fetch_apk libgcc
fetch_apk libstdc++

mkdir "$TMP/runtime"
cp -L "$TMP/apk/musl/lib/ld-musl-aarch64.so.1" "$TMP/runtime/ld-musl-aarch64.so.1"
cp -L "$TMP/apk/musl/lib/libc.musl-aarch64.so.1" "$TMP/runtime/libc.musl-aarch64.so.1"
cp -L "$TMP/apk/libgcc/usr/lib/libgcc_s.so.1" "$TMP/runtime/libgcc_s.so.1"
stdcpp=$(find "$TMP/apk/libstdc++" -type f -name 'libstdc++.so.6.*' | sort | tail -1)
[ -n "$stdcpp" ] || die "Alpine libstdc++ package has no shared library"
cp -L "$stdcpp" "$TMP/runtime/libstdc++.so.6"

echo "Testing staged runtime..."
env -u LD_PRELOAD -u LD_LIBRARY_PATH "$TMP/runtime/ld-musl-aarch64.so.1" --library-path "$TMP/runtime" "$TMP/opencode/opencode" --version >/dev/null || die "staged OpenCode failed its smoke test"

echo "Installing binary and runtime..."
chmod 700 "$TMP/opencode/opencode"
rm -rf "$RUNTIME_DIR.new" "$RUNTIME_DIR.prev"
mkdir "$RUNTIME_DIR.new"
cp -a "$TMP/runtime/." "$RUNTIME_DIR.new/"
[ -e "$RUNTIME_DIR" ] && mv "$RUNTIME_DIR" "$RUNTIME_DIR.prev"
mv "$RUNTIME_DIR.new" "$RUNTIME_DIR"
[ -e "$OPENCODE_DIR/opencode" ] && mv "$OPENCODE_DIR/opencode" "$OPENCODE_DIR/opencode.prev"
cp "$TMP/opencode/opencode" "$OPENCODE_DIR/opencode"
printf '%s\n' "$version" > "$OPENCODE_DIR/version"

cat > "$PREFIX_DIR/bin/opencode" <<'WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
set -e
unset LD_PRELOAD LD_LIBRARY_PATH
OPENCODE_DIR="${OPENCODE_DIR:-$HOME/.opencode}"
RUNTIME_DIR="${OPENCODE_RUNTIME_DIR:-$OPENCODE_DIR/runtime}"
export OPENCODE_DISABLE_AUTOUPDATE=1
export SSL_CERT_FILE=/data/data/com.termux/files/usr/etc/tls/cert.pem
export BUN_FEATURE_FLAG_DISABLE_EPOLL_PWAIT2=1
export TMPDIR="${OPENCODE_TMPDIR:-$HOME/.cache/opencode-tmp}"
mkdir -p "$TMPDIR"
[ -x "$OPENCODE_DIR/opencode" ] || { echo "OpenCode is not installed; run install.sh" >&2; exit 1; }
exec "$RUNTIME_DIR/ld-musl-aarch64.so.1" --library-path "$RUNTIME_DIR" "$OPENCODE_DIR/opencode" "$@"
WRAPPER
chmod 700 "$PREFIX_DIR/bin/opencode"

mkdir -p "$HOME_DIR/.config/opencode"
config="$HOME_DIR/.config/opencode/opencode.jsonc"
[ -e "$config" ] || printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$config"
[ -e "$config.opencode-code-termux-native.bak" ] ||
  cp -f "$config" "$config.opencode-code-termux-native.bak"
tmp_config=$(mktemp)
jq '.autoupdate = false' "$config" > "$tmp_config" && mv "$tmp_config" "$config"
rm -rf "$OPENCODE_DIR/opencode-native"

echo "Installed OpenCode $version. Run: opencode"
