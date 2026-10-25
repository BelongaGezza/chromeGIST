#!/usr/bin/env bash
# Proves a release build carries no test-only exports (docs/SECURITY_REVIEW.md
# finding #5). Builds into throwaway directories, never the real pkg/:
#   1. a release build with FEATURES unset must NOT contain panicForTest;
#   2. a positive control (FEATURES=test-hooks) MUST contain it, so the grep
#      is known to be able to see it.
# Phase 3 packaging runs this before zipping.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/chromegist-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PATTERN='panic_?for_?test'
scan() { grep -aqiE "$PATTERN" "$1"/*.js "$1"/*.wasm; }

echo "→ release build (no features)"
env -u FEATURES PROFILE=release OUT_DIR="$TMP/release" "$SCRIPT_DIR/build-wasm.sh" >/dev/null
if scan "$TMP/release"; then
    echo "✗ release build contains test-only code (panicForTest)" >&2
    exit 1
fi

echo "→ positive control (FEATURES=test-hooks)"
FEATURES=test-hooks PROFILE=release OUT_DIR="$TMP/control" "$SCRIPT_DIR/build-wasm.sh" >/dev/null
if ! scan "$TMP/control"; then
    echo "✗ positive control failed: the grep can't see panicForTest in a test-hooks build" >&2
    exit 1
fi

echo "✓ release build is free of test hooks (positive control matched)"
