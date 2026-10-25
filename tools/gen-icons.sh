#!/usr/bin/env bash
# Regenerates apps/chrome/icons/icon{16,32,48,128}.png from GIST's icon
# artwork (assets/gist-macos-app-icon.png, a committed copy of GIST's
# assets/a-macos-app-icon.png so icons build offline). Committed, since the
# extension package needs them; re-run after the artwork changes. With
# --refresh-source it first downloads the artwork from GitHub at a pinned GIST
# commit (ICON_REF, a full 40-hex sha; never a branch), so the download can't
# change under us. To take newer artwork, find the commit that last touched
# assets/a-macos-app-icon.png in GIST, review the image, and move the pin.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO_ROOT/assets/gist-macos-app-icon.png"
ICON_REF="${ICON_REF:-fb33b2e3d1693be258b9d18908d55216658bebf6}"   # GIST, 2026-09-30
[[ "$ICON_REF" =~ ^[0-9a-f]{40}$ ]] || { echo "error: ICON_REF must be a full 40-hex commit sha, got '$ICON_REF'" >&2; exit 1; }
UPSTREAM="https://raw.githubusercontent.com/BelongaGezza/gist/$ICON_REF/assets/a-macos-app-icon.png"
if [ "${1:-}" = "--refresh-source" ]; then
    curl -fsSL "$UPSTREAM" -o "$SOURCE.tmp" || { rm -f "$SOURCE.tmp"; echo "error: could not download $UPSTREAM" >&2; exit 1; }
    mv "$SOURCE.tmp" "$SOURCE"
    echo "→ Downloaded source from $UPSTREAM (sha256 $(shasum -a 256 "$SOURCE" | cut -d" " -f1))"
fi
OUT="$REPO_ROOT/apps/chrome/icons"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chromegist-icons.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
swift "$SCRIPT_DIR/gen-icons.swift" "$SOURCE" "$TMP/master.png"
mkdir -p "$OUT"
for size in 16 32 48 128; do
    sips -s format png -z "$size" "$size" "$TMP/master.png" --out "$OUT/icon$size.png" >/dev/null
done
echo "✓ icons written to apps/chrome/icons/"
