#!/data/data/com.termux/files/usr/bin/bash
# Downloads the latest aarch64 musl build of opencode and verifies its
# SHA-256. Pure downloader — extracting, patching and installing are
# install.sh's job.
#
# Usage:
#   download.sh [DEST_DIR]   download the release archive into DEST_DIR
#                            (default: $PWD). Writes:
#                              DEST_DIR/opencode-termux-aarch64.tar.gz
#                              DEST_DIR/.opencode-termux-version
#   download.sh --check      print the latest version and exit (no download)
set -uo pipefail

REGISTRY=https://registry.npmjs.org/opencode-termux/latest
REPO_URL=https://github.com/C04-wq/opencode-termux/releases/download
SMALL_DOWNLOAD_OPTS=(--connect-timeout 5 --max-time 20)
# The archive is ~64MB. A flat --max-time is wrong for it on a slow mobile
# link — abort only if throughput actually stalls (below 1KB/s for 30s), and
# retry a flaky connection instead of dying on it.
BIN_DOWNLOAD_OPTS=(--connect-timeout 8 --speed-limit 1024 --speed-time 30 --retry 5 --retry-delay 3 --retry-all-errors)

die() { echo "download.sh: $*" >&2; exit 1; }

# The npm package is the source of truth for both the version and the
# archive's SHA-256 (release-checksums.json).
REG_OUT=$(curl -fsSL "${SMALL_DOWNLOAD_OPTS[@]}" "$REGISTRY" 2>&1) \
  || die "could not reach $REGISTRY: $REG_OUT"
VER=$(printf '%s' "$REG_OUT" | jq -r '.version // empty' 2>/dev/null)
[ -n "$VER" ] || die "registry response had no .version — it may have changed shape"

if [ "${1:-}" = "--check" ]; then
  printf '%s\n' "$VER"
  exit 0
fi

DEST_DIR="${1:-$PWD}"
mkdir -p "$DEST_DIR"
ARCHIVE="$DEST_DIR/opencode-termux-aarch64.tar.gz"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "${SMALL_DOWNLOAD_OPTS[@]}" -o "$TMP/pkg.tgz" \
  "$(printf '%s' "$REG_OUT" | jq -r '.dist.tarball // empty' 2>/dev/null)" \
  || die "could not fetch the checksum package"

tar -xzf "$TMP/pkg.tgz" -C "$TMP" package/release-checksums.json 2>/dev/null \
  || tar -xzf "$TMP/pkg.tgz" -C "$TMP"
CS="$TMP/package/release-checksums.json"; [ -e "$CS" ] || CS="$TMP/release-checksums.json"
EXP=$(jq -r '.archiveSha256 // empty' "$CS" 2>/dev/null)
CS_VER=$(jq -r '.version // empty' "$CS" 2>/dev/null)
[ -n "$EXP" ] || die "could not read archiveSha256 from release-checksums.json"
[ "$CS_VER" = "$VER" ] || die "checksum metadata is for $CS_VER but the registry reports $VER"

echo "Downloading opencode $VER ..."
curl -fSL "${BIN_DOWNLOAD_OPTS[@]}" -o "$ARCHIVE" \
  "$REPO_URL/v${VER}/opencode-termux-aarch64.tar.gz" \
  || die "download failed"

ACTUAL=$(sha256sum "$ARCHIVE" | awk '{print $1}')
[ "$EXP" = "$ACTUAL" ] || die "sha256 mismatch (expected $EXP, got $ACTUAL)"

printf '%s\n' "$VER" > "$DEST_DIR/.opencode-termux-version"
echo "Downloaded opencode $VER to $ARCHIVE"
