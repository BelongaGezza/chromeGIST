#!/usr/bin/env bash
# Runs apps/chrome/tests/*.html in headless Chrome against a fresh WASM build
# and fails if any check fails. Complements `cargo test` (native): these are
# the checks that need a real browser (wasm32 clock/randomness, JsError,
# Intl.Segmenter, real timings).
#
# Each test page logs "[chromeGIST] PASS|FAIL ..." lines and a final
# "[chromeGIST] DONE: ..." line to the console; this script reads them from
# Chrome's stderr. Uses a throwaway profile, never your own.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
TIMEOUT="${TIMEOUT:-30}"

[ -x "$CHROME" ] || { echo "error: Chrome not found at $CHROME (set CHROME=...)" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chromegist-test.XXXXXX")"
SERVER=""
CHROME_PID=""
cleanup() {
    [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null || true
    [ -n "$SERVER" ] && { kill "$SERVER" 2>/dev/null && wait "$SERVER" 2>/dev/null || true; }
    rm -rf "$TMP"
}
trap cleanup EXIT

# Stage a copy of the extension (minus pkg/) and build the test-hooks WASM
# (adds Reader.panicForTest for the crash-recovery test) into the copy, so a
# test build can never end up in the real apps/chrome/pkg/.
mkdir -p "$TMP/chrome"
(cd "$REPO_ROOT/apps/chrome" && tar -cf - --exclude=./pkg .) | tar -xf - -C "$TMP/chrome"
FEATURES=test-hooks OUT_DIR="$TMP/chrome/pkg" "$SCRIPT_DIR/build-wasm.sh"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server --bind 127.0.0.1 "$PORT" --directory "$TMP/chrome" >"$TMP/server.log" 2>&1 &
SERVER=$!
sleep 1

FAILED=0
for page in "$TMP"/chrome/tests/*.html; do
    name="tests/$(basename "$page")"
    echo "→ $name"
    : >"$TMP/stderr"
    "$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
        --user-data-dir="$TMP/profile" --enable-logging=stderr --v=0 \
        "http://127.0.0.1:$PORT/$name" 2>"$TMP/stderr" &
    CHROME_PID=$!
    for _ in $(seq 1 "$TIMEOUT"); do
        sleep 1
        grep -q '\[chromeGIST\] DONE' "$TMP/stderr" && break
    done
    kill "$CHROME_PID" 2>/dev/null || true
    wait "$CHROME_PID" 2>/dev/null || true
    CHROME_PID=""
    RESULTS="$(grep -o '"\[chromeGIST\][^"]*"' "$TMP/stderr" | tr -d '"' | sed 's/^\[chromeGIST\] /   /')" || true
    if [ -z "$RESULTS" ]; then
        echo "   FAIL: no results (page didn't load or threw before logging)"
        grep -E 'CONSOLE|Uncaught' "$TMP/stderr" | head -5 | sed 's/^/   /'
        FAILED=1
        continue
    fi
    echo "$RESULTS"
    echo "$RESULTS" | grep -q 'DONE: all passed' || FAILED=1
done

[ "$FAILED" = 0 ] && echo "✓ browser tests passed" || { echo "✗ browser tests failed" >&2; exit 1; }
