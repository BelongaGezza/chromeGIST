# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

chromeGIST is a Chrome extension (Manifest V3): select text on a web page,
right-click → "Speed Read with chromeGIST", and a popup window shows it
RSVP-style (one word at a time, paced) with play/pause/rewind/fast-forward/
speed controls. On close, the text is discarded: no library, no
persistence, no accounts, no network.

It lives at <https://github.com/BelongaGezza/chromeGIST>. It was
forked on 2026-09-30 from
**[contextGIST](https://github.com/BelongaGezza/contextGIST)** (the macOS
Services-menu version; full history kept, git remote `contextgist`). Both
reuse **[GIST](https://github.com/BelongaGezza/gist)**'s tokenizer and
pacing engine. Read [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) before
changing `crates/chromegist-wasm` or the extension, and
[`docs/DEVELOPMENT_PLAN.md`](./docs/DEVELOPMENT_PLAN.md) for what's done and
next.

`docs/SECURITY_REVIEW.md` and `docs/PRIVACY.md` were written for the
extension on 2026-10-01 and re-reviewed on 2026-10-25 (incognito, the
Space key and the handoff were then verified in real Chrome; see the
addendum). Re-check them whenever permissions, the manifest, the messaging or
storage change, or the GIST pin moves.

Three public-facing files must stay in step with `docs/PRIVACY.md`: the
plain-language policy page `docs/site/privacy.html` (the Web Store privacy
policy; also carries the version and effective date), the Web Store answers in
`CHROMEWEBSTORE.md`, and `docs/SECURITY_REVIEW.md`. After any change to
`docs/PRIVACY.md`, `apps/chrome/manifest.json` (permissions, CSP, `incognito`),
what is stored, logged or sent, or the extension version: re-read the policy
page and `CHROMEWEBSTORE.md` against the code, update both, and bump the page's
version/effective date. Its contact is the repo's GitHub issues page and its
publisher is BelongaGezza; change both if the Web Store listing differs.

`docs/THIRD-PARTY.md` is generated for chromeGIST
(`tools/gen-third-party.sh`).

## Relationship to GIST (https://github.com/BelongaGezza/gist)

`crates/chromegist-wasm` depends on `gist-model`, `gist-parse-txt`, and
`gist-rsvp` as **git dependencies on `https://github.com/BelongaGezza/gist`,
pinned by commit `rev`** in the workspace `Cargo.toml`
(`[workspace.dependencies]`) — not a vendored copy, not a git fork. GitHub is
the source of truth. This means:

- **No local GIST checkout is needed or consulted.** Cargo fetches the pinned
  commit itself (network needed the first time; then cached in `~/.cargo`).
  Any other clone of GIST on your machine has no effect on this build.
- Pacing/tokenization logic is never edited in this repo — change it in GIST
  (PR/merge on GitHub), then adopt it here by moving the pin via the upstream
  review below. To try an unmerged GIST change locally, use a throwaway
  `[patch]` override
  (`cargo --config 'patch."https://github.com/BelongaGezza/gist".gist-rsvp.path="/path/to/gist/crates/gist-rsvp"' test`)
  and never commit it. Unlike contextGIST, pacing isn't even ported: `Reader`
  wraps GIST's `RsvpSession` directly (a WASM call is cheap; no per-tick FFI
  jitter).
- Display-only adjustments live in `Reader` (e.g. snapping GIST's ORP to a
  whole grapheme cluster). Keep them presentation-only.
- `UPSTREAM_BASELINE` records the last GIST commit (normally on `main`) this
  repo was reviewed and tested against; it always equals the `rev` in
  `Cargo.toml` (`--record` moves both).
- **Upstream review is part of the development cycle.** At the start of a
  work session, and whenever a build prints `warning: GIST ... changed ...
  since the last upstream review`, run `tools/upstream-review.sh`. For each
  item decide adopt, port or skip following `docs/ARCHITECTURE.md`
  "Upstream baseline", telling the user what's applicable before making
  non-trivial changes. Once handled, run `tools/test-browser.sh` and
  `tools/upstream-review.sh --record "<summary>"` (moves the pin; run
  `tools/gen-third-party.sh` if dependencies changed), then commit.
- WASM caveats: GIST's crates need uuid's `js` feature on wasm32 (enabled in
  `crates/chromegist-wasm/Cargo.toml`), and a new upstream dependency may
  not build for wasm32 at all. Panics abort in WASM (`catch_unwind` doesn't
  work there).

## Build / test commands

```bash
cargo test --workspace                  # native tests (Reader + adversarial tests of GIST's code); fetches GIST from GitHub on first build
./tools/build-wasm.sh                   # wasm32 build + wasm-bindgen glue → apps/chrome/pkg/ (gitignored)
WASM_OPT=1 ./tools/build-wasm.sh         # same, plus binaryen wasm-opt -Oz (~20 KB smaller; needs `brew install binaryen`)
./tools/package-extension.sh            # checks, then dist/chromegist-<version>.zip + BUILD_INFO (allow-list; clean tree; --skip-checks for a trial)
./tools/test-browser.sh                 # build, then run apps/chrome/tests/*.html in headless Chrome
cargo deny --exclude-dev check          # licence/advisory/source policy (deny.toml); needs cargo-deny >= 0.20
./tools/gen-third-party.sh              # regenerate docs/THIRD-PARTY.md + apps/chrome/THIRD_PARTY_NOTICES.txt
./tools/gen-icons.sh [--refresh-source] # regenerate apps/chrome/icons/ from assets/ (GIST's artwork; --refresh-source downloads it from GitHub first)

# Upstream (GIST) review
./tools/upstream-review.sh [--ref <ref>]  # what changed in GIST (GitHub main, via .upstream/gist clone) since UPSTREAM_BASELINE
./tools/upstream-review.sh --record "..." # after reviewing: move the Cargo.toml rev + baseline, run tests, log it
```

`wasm-bindgen-cli` must match the `wasm-bindgen` version in `Cargo.lock`;
it's installed in `~/.cargo-wasm-bindgen/bin` (see `tools/build-wasm.sh`).
Browser tests need Google Chrome (`CHROME=...` to override the path) and use
a throwaway profile. Node isn't required.

## Layout

- **`crates/chromegist-wasm`** — the Rust core: the `Reader` class exported
  via wasm-bindgen (tokenize, ORP split, progress, pacing). Native `cargo
  test` covers it plus adversarial tests of GIST's crates.
- **`apps/chrome/`** — the extension (load this folder unpacked):
  `manifest.json`, `background.js` (service worker), `handoff.js`
  (in-memory one-time text handoff), `reader.html`/`reader.js` (bootstrap),
  `reader-core.js` (`ReaderView`: display, controls, playback, crash
  guard), `reader.css`, `icons/`, and the generated `pkg/` (run
  `tools/build-wasm.sh` first). `tests/` are browser test pages;
  `dev/preview.html` shows the reader with sample text over localhost.
  `tests/` and `dev/` are dev-only (excluded from the Phase 3 package).

- **`assets/`** — GIST's icon artwork (copy), source for the extension icons.
- **`tools/`** — build, test, notices, upstream review.

To try the extension: `./tools/build-wasm.sh`, then in Chrome open
`chrome://extensions`, turn on Developer mode, "Load unpacked", and choose
`apps/chrome`. Google Chrome won't load unpacked extensions from the
command line, so this step is manual.

## Current state

Phase 0 (spike) done on 2026-09-30: GIST's core runs as WASM in Chrome,
with two findings recorded in the architecture doc (uuid `js` feature;
panics abort in WASM) and one upstream issue (gist#78, ORP mid-grapheme; fixed in GIST #79 and adopted
2026-10-01).

Phase 1 (the extension) is mostly built: manifest, service worker, handoff,
reader, icons, crash recovery. 17 native + 41 browser tests pass. Left: the
manual checks in a real Chrome profile (context menu, PDF viewer, iframes,
long selections), and automated extension-level tests via Chrome for
Testing.

2026-10-01: moved to its own GitHub repo (BelongaGezza/chromeGIST)
and stopped depending on a local GIST checkout: GIST's crates are now
rev-pinned git dependencies (see above), and `tools/upstream-review.sh` works
from a read-only clone of GitHub in `.upstream/gist`. The `contextgist`
remote points at the contextGIST GitHub repo.
