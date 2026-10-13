#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

REPO="${OPENCODE_REPO:-anomalyco/opencode}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_BRANCH="${ALPINE_BRANCH:-latest-stable}"
HOME_DIR="${HOME:?HOME is not set}"
OPENCODE_DIR="$HOME_DIR/.opencode"
INSTALL_RUNTIME_DIR="$OPENCODE_DIR/runtime"
PREFIX_DIR="${PREFIX:?Run this from Termux}"
API="https://api.github.com/repos/$REPO/releases"
ASSET="opencode-linux-arm64-musl.tar.gz"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOAD_DIR="$REPO_DIR/.downloads"

die() { echo "install: $*" >&2; exit 1; }

[ "$(uname -m)" = "aarch64" ] || die "this installer requires an aarch64 Termux device"
command -v pkg >/dev/null 2>&1 || die "pkg was not found; this is not Termux"

echo "Installing OpenCode official ARM64 musl runtime..."
pkg install -y curl jq tar coreutils binutils ca-certificates >/dev/null

mkdir -p "$OPENCODE_DIR" "$DOWNLOAD_DIR"
release_json=$(curl -fsSL --retry 3 --connect-timeout 10 "$API/latest") || die "could not fetch the latest GitHub release"
version=$(printf '%s' "$release_json" | jq -r '.tag_name // empty' | sed 's/^v//')
asset_url=$(printf '%s' "$release_json" | jq -r --arg n "$ASSET" '.assets[] | select(.name==$n) | .browser_download_url' | head -1)
[ -n "$version" ] && [ -n "$asset_url" ] || die "release $ASSET was not found"

echo "Downloading OpenCode $version..."
curl -fL --retry 5 --retry-all-errors --connect-timeout 10 -o "$DOWNLOAD_DIR/opencode.tar.gz" "$asset_url"
echo "OpenCode MD5: $(md5sum "$DOWNLOAD_DIR/opencode.tar.gz" | awk '{print $1}')"
if [ -n "${OPENCODE_MD5:-}" ]; then
  actual_md5=$(md5sum "$DOWNLOAD_DIR/opencode.tar.gz" | awk '{print $1}')
  [ "$actual_md5" = "$OPENCODE_MD5" ] || die "OpenCode MD5 mismatch"
fi

mkdir -p "$DOWNLOAD_DIR/opencode"
tar -xzf "$DOWNLOAD_DIR/opencode.tar.gz" -C "$DOWNLOAD_DIR/opencode"
[ -s "$DOWNLOAD_DIR/opencode/opencode" ] || die "release archive has no opencode binary"

apk_version() {
  awk -v want="P:$1" '$0 == want { found=1; next } found && /^V:/ { sub(/^V:/, ""); print; exit } /^$/ { found=0 }' "$DOWNLOAD_DIR/APKINDEX.desc"
}
fetch_apk() {
  local package="$1" version url
  version=$(apk_version "$package")
  [ -n "$version" ] || die "could not resolve Alpine package $package"
  url="$ALPINE_MIRROR/$ALPINE_BRANCH/main/aarch64/${package}-${version}.apk"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 10 -o "$DOWNLOAD_DIR/${package}.apk" "$url"
  mkdir -p "$DOWNLOAD_DIR/apk/$package"
  tar -xzf "$DOWNLOAD_DIR/${package}.apk" -C "$DOWNLOAD_DIR/apk/$package"
}

echo "Downloading musl runtime from Alpine..."
curl -fsSL --retry 3 --connect-timeout 10 "$ALPINE_MIRROR/$ALPINE_BRANCH/main/aarch64/APKINDEX.tar.gz" -o "$DOWNLOAD_DIR/APKINDEX.tar.gz"
mkdir -p "$DOWNLOAD_DIR/index"
tar -xzf "$DOWNLOAD_DIR/APKINDEX.tar.gz" -C "$DOWNLOAD_DIR/index"
if [ -s "$DOWNLOAD_DIR/index/APKINDEX" ]; then
  cp "$DOWNLOAD_DIR/index/APKINDEX" "$DOWNLOAD_DIR/APKINDEX.desc"
elif [ -s "$DOWNLOAD_DIR/index/APKINDEX.tar" ]; then
  tar -xf "$DOWNLOAD_DIR/index/APKINDEX.tar" -C "$DOWNLOAD_DIR" || die "could not read Alpine package index"
  [ -s "$DOWNLOAD_DIR/APKINDEX.desc" ] || [ -s "$DOWNLOAD_DIR/APKINDEX" ] || die "Alpine package index has no description file"
  [ -s "$DOWNLOAD_DIR/APKINDEX.desc" ] || mv "$DOWNLOAD_DIR/APKINDEX" "$DOWNLOAD_DIR/APKINDEX.desc"
else
  die "Alpine package index has no APKINDEX member"
fi
fetch_apk musl
fetch_apk libgcc
fetch_apk libstdc++

mkdir -p "$DOWNLOAD_DIR/runtime"
cp -L "$DOWNLOAD_DIR/apk/musl/lib/ld-musl-aarch64.so.1" "$DOWNLOAD_DIR/runtime/ld-musl-aarch64.so.1"
cp -L "$DOWNLOAD_DIR/apk/musl/lib/libc.musl-aarch64.so.1" "$DOWNLOAD_DIR/runtime/libc.musl-aarch64.so.1"
cp -L "$DOWNLOAD_DIR/apk/libgcc/usr/lib/libgcc_s.so.1" "$DOWNLOAD_DIR/runtime/libgcc_s.so.1"
stdcpp=$(find "$DOWNLOAD_DIR/apk/libstdc++" -type f -name 'libstdc++.so.6.*' | sort | tail -1)
[ -n "$stdcpp" ] || die "Alpine libstdc++ package has no shared library"
cp -L "$stdcpp" "$DOWNLOAD_DIR/runtime/libstdc++.so.6"

echo "Installing binary and runtime..."
chmod 700 "$DOWNLOAD_DIR/opencode/opencode"
rm -rf "$INSTALL_RUNTIME_DIR"
mkdir -p "$INSTALL_RUNTIME_DIR"
cp -a "$DOWNLOAD_DIR/runtime/." "$INSTALL_RUNTIME_DIR/"
[ -e "$OPENCODE_DIR/opencode" ] && mv "$OPENCODE_DIR/opencode" "$OPENCODE_DIR/opencode.prev"
cp "$DOWNLOAD_DIR/opencode/opencode" "$OPENCODE_DIR/opencode"
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

echo "Running final smoke test on the installed runtime..."
env -u LD_PRELOAD -u LD_LIBRARY_PATH "$INSTALL_RUNTIME_DIR/ld-musl-aarch64.so.1" \
  --library-path "$INSTALL_RUNTIME_DIR" "$OPENCODE_DIR/opencode" --version >/dev/null \
  || die "installed OpenCode failed its final smoke test"

echo "Installed OpenCode $version. Run: opencode"
