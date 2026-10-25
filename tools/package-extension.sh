#!/usr/bin/env bash
# Builds the Chrome Web Store package: dist/chromegist-<version>.zip plus
# dist/chromegist-<version>.BUILD_INFO (docs/SECURITY_REVIEW.md findings #5,
# #7; docs/DEVELOPMENT_PLAN.md Phase 3).
#
#   tools/package-extension.sh                 full checks, then package
#   tools/package-extension.sh --skip-checks   package only (BUILD_INFO says so;
#                                              never submit such a package)
#   WASM_OPT=1 tools/package-extension.sh      also run binaryen's wasm-opt
#   ALLOW_DIRTY=1 ...                          package from an uncommitted tree
#
# The package is an ALLOW-LIST: only the files named in FILES below go into the
# zip. Anything else under apps/chrome/ (tests/, dev/, pkg/ leftovers, a new
# file nobody listed) is never shipped; a new file there that isn't listed or
# in IGNORED stops the build, so adding a shipped file is a deliberate edit
# to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
APP=apps/chrome

# Everything that ships, relative to apps/chrome/.
FILES=(
    manifest.json
    background.js
    handoff.js
    reader.html
    reader.js
    reader-core.js
    reader.css
    icons/icon16.png
    icons/icon32.png
    icons/icon48.png
    icons/icon128.png
    pkg/chromegist_wasm.js
    pkg/chromegist_wasm_bg.wasm
    THIRD_PARTY_NOTICES.txt
)
# Top-level entries of apps/chrome/ that are known not to ship.
IGNORED=(tests dev)

SKIP_CHECKS=0
for a in "$@"; do
    case "$a" in
        --skip-checks) SKIP_CHECKS=1 ;;
        *) echo "usage: $0 [--skip-checks]" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo "→ $*"; }

# 1. Source state ------------------------------------------------------------
if [ "${ALLOW_DIRTY:-0}" != 1 ] && [ -n "$(git status --porcelain)" ]; then
    die "working tree is not clean; commit first (or ALLOW_DIRTY=1 for a trial package)"
fi
COMMIT="$(git rev-parse HEAD)"
[ -n "$(git status --porcelain)" ] && COMMIT="$COMMIT+dirty"

# 2. Allow-list audit: every file under apps/chrome is listed, ignored or pkg --
listed() { local f; for f in "${FILES[@]}"; do [ "$f" = "$1" ] && return 0; done; return 1; }
ignored() { local f; for f in "${IGNORED[@]}"; do [ "$f" = "$1" ] && return 0; done; return 1; }
while IFS= read -r path; do
    rel="${path#"$APP"/}"
    top="${rel%%/*}"
    ignored "$top" && continue
    [ "$top" = pkg ] && continue          # generated; only the two listed files ship
    listed "$rel" || die "$APP/$rel is not in the package allow-list or IGNORED; add it to tools/package-extension.sh deliberately"
done < <(find "$APP" -type f ! -name .DS_Store | sort)

VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$APP/manifest.json")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || die "manifest version '$VERSION' is not a Chrome-valid version"

# 3. Checks ------------------------------------------------------------------
if [ "$SKIP_CHECKS" = 0 ]; then
    if [ -d .upstream/gist ]; then
        step "fetching GIST to check the upstream review is current"
        git -C .upstream/gist fetch -q origin || die "could not fetch GIST (strict upstream check needs a current clone)"
    fi
    step "upstream review is current (--check --strict)"
    "$SCRIPT_DIR/upstream-review.sh" --check --strict
    step "native tests"
    cargo test --workspace --locked
    step "browser tests"
    "$SCRIPT_DIR/test-browser.sh"
    step "cargo deny"
    cargo deny --exclude-dev check
    step "release build is free of test hooks"
    "$SCRIPT_DIR/verify-release-build.sh"
fi

# 4. Rebuild pkg/ from scratch with no features ------------------------------
step "building pkg/ (release, no features${WASM_OPT:+, WASM_OPT=$WASM_OPT})"
env -u FEATURES PROFILE=release "$SCRIPT_DIR/build-wasm.sh" >/dev/null

# 5. Stage exactly the allow-list, with fixed mtimes -------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/chromegist-pkg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
for f in "${FILES[@]}"; do
    [ -f "$APP/$f" ] || die "allow-listed file missing: $APP/$f"
    mkdir -p "$STAGE/$(dirname "$f")"
    cp "$APP/$f" "$STAGE/$f"
done
if grep -aqiE 'panic_?for_?test' "$STAGE"/pkg/*; then
    die "package contains test-only code (panicForTest)"
fi
find "$STAGE" -exec touch -t 202001010000 {} +

# 6. Zip (sorted, no extra attributes) and write BUILD_INFO ------------------
mkdir -p dist
ZIP="$REPO_ROOT/dist/chromegist-$VERSION.zip"
INFO="$REPO_ROOT/dist/chromegist-$VERSION.BUILD_INFO"
rm -f "$ZIP"
(cd "$STAGE" && printf '%s\n' "${FILES[@]}" | LC_ALL=C sort | zip -X -q "$ZIP" -@)

LISTED="$(unzip -Z1 "$ZIP" | LC_ALL=C sort)"
EXPECT="$(printf '%s\n' "${FILES[@]}" | LC_ALL=C sort)"
[ "$LISTED" = "$EXPECT" ] || die "zip contents differ from the allow-list"

GIST_REV="$(sed -n 's/^gist-rsvp .*rev = "\([0-9a-f]*\)".*/\1/p' Cargo.toml)"
{
    echo "chromeGIST $VERSION"
    echo "built:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "git commit:   $COMMIT"
    echo "checks:       $([ "$SKIP_CHECKS" = 1 ] && echo 'SKIPPED (do not submit)' || echo 'passed')"
    echo "rustc:        $(rustc --version)"
    echo "wasm-bindgen: $(grep -A1 '^name = "wasm-bindgen"$' Cargo.lock | sed -n 's/version = "\(.*\)"/\1/p')"
    echo "wasm-opt:     $([ "${WASM_OPT:-0}" = 1 ] && wasm-opt --version || echo 'not used')"
    echo "Cargo.lock:   sha256 $(shasum -a 256 Cargo.lock | cut -d' ' -f1)"
    echo "GIST rev:     $GIST_REV"
    echo "zip:          sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    echo "files:"
    (cd "$STAGE" && printf '%s\n' "${FILES[@]}" | LC_ALL=C sort | while read -r f; do
        echo "  $(shasum -a 256 "$f" | cut -d' ' -f1)  $f"
    done)
} > "$INFO"

echo "✓ $ZIP ($(du -h "$ZIP" | cut -f1)), ${#FILES[@]} files"
echo "✓ $INFO"
[ "$SKIP_CHECKS" = 1 ] && echo "! checks were skipped: this package must not be submitted"
exit 0
