#!/usr/bin/env bash
# Builds crates/chromegist-wasm for the browser and writes the .wasm plus its
# JS glue to apps/chrome/pkg/ (gitignored, regenerated on every build).
#
# Needs: rustup target wasm32-unknown-unknown (rust-toolchain.toml installs
# it) and wasm-bindgen-cli at the *same version* as the wasm-bindgen crate
# in Cargo.lock. Install once with:
#   cargo install wasm-bindgen-cli --version <that version> --locked \
#       --root ~/.cargo-wasm-bindgen
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# OUT_DIR is overridable so tests and release checks never touch the real pkg/.
OUT_DIR="${OUT_DIR:-$REPO_ROOT/apps/chrome/pkg}"
cd "$REPO_ROOT"

"$SCRIPT_DIR/upstream-review.sh" --check || true

PROFILE="${PROFILE:-release}"
# FEATURES=test-hooks adds test-only exports (tools/test-browser.sh sets it).
FEATURES="${FEATURES:-}"
ARGS=(-p chromegist-wasm --target wasm32-unknown-unknown)
[ "$PROFILE" = release ] && ARGS+=(--release)
[ -n "$FEATURES" ] && ARGS+=(--features "$FEATURES")
echo "→ Building chromegist-wasm ($PROFILE, wasm32-unknown-unknown${FEATURES:+, features: $FEATURES})..."
# Keep local paths out of the .wasm: rustc embeds source paths (panic
# locations) for this repo and for every dependency under CARGO_HOME. Map them
# to fixed names so a shipped build never contains the builder's home directory.
SYSROOT="$(rustc --print sysroot)"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$SYSROOT=/rust-toolchain --remap-path-prefix=$REPO_ROOT=/src"
cargo build --locked "${ARGS[@]}"

WANT="$(grep -A1 '^name = "wasm-bindgen"$' Cargo.lock | sed -n 's/version = "\(.*\)"/\1/p')"
BINDGEN="$(command -v wasm-bindgen || echo "$HOME/.cargo-wasm-bindgen/bin/wasm-bindgen")"
HAVE="$("$BINDGEN" --version 2>/dev/null | awk '{print $2}')" || true
if [ "$HAVE" != "$WANT" ]; then
    echo "error: wasm-bindgen-cli $WANT required (found: ${HAVE:-none}). See this script's header." >&2
    exit 1
fi

rm -rf "$OUT_DIR"
"$BINDGEN" --target web --no-typescript --out-dir "$OUT_DIR" \
    "target/wasm32-unknown-unknown/$PROFILE/chromegist_wasm.wasm"
# Optional: WASM_OPT=1 runs binaryen's wasm-opt (-Oz) over the glue output.
# Opt-in so the default build needs no extra tool; saves ~20 KB more.
if [ "${WASM_OPT:-0}" = 1 ]; then
    command -v wasm-opt >/dev/null || { echo "error: WASM_OPT=1 needs wasm-opt (brew install binaryen)" >&2; exit 1; }
    wasm-opt -Oz --enable-bulk-memory --enable-nontrapping-float-to-int \
        --enable-sign-ext --enable-mutable-globals \
        -o "$OUT_DIR/opt.wasm" "$OUT_DIR/chromegist_wasm_bg.wasm"
    mv "$OUT_DIR/opt.wasm" "$OUT_DIR/chromegist_wasm_bg.wasm"
fi
echo "✓ $(du -h "$OUT_DIR/chromegist_wasm_bg.wasm" | cut -f1) wasm written to $OUT_DIR"
