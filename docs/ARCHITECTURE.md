# Architecture

## What chromeGIST is

chromeGIST is a Chrome extension that speed-reads the text you've selected
on a web page. Select text, right-click, choose "Speed Read with
chromeGIST", and a small popup window shows it RSVP-style: one word at a
time, paced, with play/pause/rewind/fast-forward/speed controls. Close the
window and the text is gone. No library, no history, no account, no
network.

It is a fork of **[contextGIST](https://github.com/BelongaGezza/contextGIST)**
(the macOS Services-menu version), which is itself a narrow reuse of
**[GIST](https://github.com/BelongaGezza/gist)** (the full reading app). All three share GIST's
tokenizer and RSVP pacing engine.

**Status (2026-09-30):** the WebAssembly core is built and tested in
Chrome; the extension itself (manifest, service worker, reader page) is
next. See `docs/DEVELOPMENT_PLAN.md`.

## Relationship to GIST and contextGIST

- **GIST** is the upstream for reading logic. `crates/chromegist-wasm`
  depends on `gist-model`, `gist-parse-txt` and `gist-rsvp` as git
  dependencies on `https://github.com/BelongaGezza/gist` pinned by commit
  `rev` in the workspace `Cargo.toml`, exactly like contextGIST: no vendored
  copy, and tokenization and pacing fixes arrive when the pin is moved after
  an upstream review (see "Upstream baseline" below). No local GIST checkout
  is consulted.
- **contextGIST** is where this repo was forked from (full history kept; the
  `contextgist` git remote points at
  `git@github.com:BelongaGezza/contextGIST.git`). Its macOS app
  was removed here. Fixes to shared ideas (the size cap, adversarial tests,
  `deny.toml`, the upstream-review tooling) can be pulled across with `git
  fetch contextgist` and cherry-picked; there's no automatic sync.

## Components

```
Web page ──(right-click "Speed Read with chromeGIST")──▶ service worker
                                                            │ selection text
                                                            ▼
                                     reader popup window (extension page)
                                       reader.js ── chromegist-wasm (Reader)
                                                     └─ gist-parse-txt / gist-rsvp
```

### `crates/chromegist-wasm` (built)

GIST's crates compiled to `wasm32-unknown-unknown`, exposed through
`wasm-bindgen` as one class, `Reader`:

- `new Reader(text)`: tokenizes with GIST's parser. Throws `Error("selection
  too long")` above `Reader.maxSelectionBytes()` (512 KiB of UTF-8, the same
  cap and rationale as contextGIST).
- Token access for display: `kind(i)`, `prefix(i)`/`focus(i)`/`suffix(i)`
  around the ORP letter, `prefixLen(i)`/`suffixLen(i)` in grapheme clusters,
  `wordsThrough(i)`/`wordCount()` for progress.
- Playback: `play()`, `pause(elapsed)`, `current(elapsed)`,
  `remainingMs(elapsed)`, `back(n, elapsed)`, `forward(n, elapsed)`,
  `setWpm(wpm, elapsed)`, `isAtEnd(elapsed)`.

**Pacing is GIST's own `RsvpSession`, not a port.** contextGIST's Swift
`PacingEngine` is a hand copy of `gist-rsvp`'s maths, because a uniffi
round trip on every tick caused timing jitter. A WASM call is a same-thread
function call, so `Reader` wraps `RsvpSession` directly and JavaScript
supplies only wall-clock time. Measured in Chrome 154: the worst-case tick
(`token_at_elapsed` walking ~83k tokens at the end of a 5.8-hour unpaused
session) takes 0.94 ms, against a 60 ms per-word budget at 1000 WPM.
Tokenizing a 512 KiB selection takes ~35 ms.

**Time model** (GIST's): while playing, JS keeps `resumedAt =
performance.now()` from the last `play()`, `back()`, `forward()` or
`setWpm()`, and passes `elapsed = performance.now() - resumedAt`. Fractional
milliseconds are rounded, not truncated (the bug contextGIST found and
ported from GIST).

**ORP display.** `gist_rsvp::orp_index` used to work in code points, so it
could land inside a grapheme cluster: on the zero-width joiner of an emoji
family, the second half of a flag, or a combining accent. That was reported
as [gist#78](https://github.com/BelongaGezza/gist/issues/78) and fixed in
GIST #79 (adopted here 2026-10-01): it now counts extended grapheme clusters
and returns a cluster boundary. `Reader` still snaps the focus to the whole
cluster containing GIST's ORP, now a no-op kept as a defence (and tested as
such), so the red letter is always one visible character. The reader page will centre the focus letter with CSS: in a
monospace font `1ch` is one character's width, so contextGIST's offset
formula becomes `translateX(calc((suffixLen - prefixLen) / 2 * 1ch))`, with
no measuring and so no frame-lag jitter.

**Two WASM-specific findings:**

1. **uuid needs a browser randomness/clock source.** GIST's `Document::new`
   calls `uuid::Uuid::now_v7()`. On `wasm32-unknown-unknown` uuid refuses to
   compile without a randomness source. chromegist-wasm enables uuid's `js`
   feature for wasm32 only; Cargo's feature unification applies it to GIST's
   crate without editing GIST. Verified at runtime in Chrome.
2. **Panics abort in WASM.** There's no unwinding on
   `wasm32-unknown-unknown`, so `catch_unwind` (contextGIST's `contain`)
   catches nothing there; a Rust panic surfaces in JS as `RuntimeError:
   unreachable` and the module instance is unusable afterwards. The reader
   page must catch that, discard the instance, and show an error rather than
   hang (planned; see the development plan). The adversarial tests found no
   panics in GIST's tokenizer or ORP code.

### Extension (Phase 1, built)

Manifest V3, in `apps/chrome/`:

- **Permissions: `contextMenus` only.** Chrome delivers the selection as
  `info.selectionText` when the menu item fires, so there are no content
  scripts, no host permissions, and no access to page contents. **No
  keyboard shortcut** (decided 2026-09-30): without page access a shortcut
  can't read the selection, and adding `activeTab` + `scripting` isn't worth
  the extra permission surface.
- **Service worker** (`background.js`): registers the menu item; on click,
  opens `reader.html#<id>` with `chrome.windows.create({type: "popup"})`.
- **Handing over the text** (`handoff.js`): the worker keeps the selection
  in memory under a random one-time id (`crypto.randomUUID()`); the reader
  claims it once with `chrome.runtime.sendMessage({type: "take", id})`,
  which deletes it, and drops the id from its URL. Unclaimed text expires
  after 60 s (timer plus sweep); a restarted worker has nothing. No
  `chrome.storage` is used at all: `storage.local` writes to disk, and
  `storage.session` would need a `storage` permission. The worker only
  answers messages from its own `reader.html`.
- **Reader page** (`reader.html`, `reader.js`, `reader-core.js`,
  `reader.css`): `reader.js` claims the text and loads the WASM;
  `ReaderView` (`reader-core.js`, no extension APIs, so testable on a plain
  page) renders words and drives the time model above with `setTimeout`
  scheduled from `remainingMs()`. Every WASM call goes through
  `ReaderView.guard`, which turns a `WebAssembly.RuntimeError` (a Rust
  panic) into an error message and drops the instance. Keyboard: space,
  arrows, Escape (closes the window).
- **CSP:** `extension_pages` is `default-src 'none'; script-src 'self'
  'wasm-unsafe-eval'; style-src 'self'; img-src 'self'; connect-src 'self';
  object-src 'none'; base-uri 'none'; form-action 'none'`.
  `'wasm-unsafe-eval'` is the Manifest V3 requirement to instantiate WASM;
  `connect-src 'self'` is for the loader's `fetch` of its own `.wasm`.
  Nothing can reach another origin.

## Testing

- **Native** (`cargo test --workspace`): `Reader` semantics against
  `RsvpSession`, grapheme-safe ORP splitting, and contextGIST's adversarial
  tests of GIST's tokenizer and ORP code (long words, bidi, ZWJ, whitespace,
  control characters, seeded pseudo-fuzz).
- **Browser** (`tools/test-browser.sh`): stages a copy of `apps/chrome` in a
  temp dir, builds the test-hooks WASM into the copy (the real `pkg/` is
  never touched), serves it on a free localhost port, runs each `apps/chrome/tests/*.html`
  in headless Chrome with a throwaway profile, and reads `[chromeGIST]
  PASS|FAIL` console lines. Covers what needs a real browser: the wasm32
  clock/randomness, `JsError`, UTF-8 cap measurement, `Intl.Segmenter`, real
  timings.
- **Extension logic** (`tests/extension.html`, run by the same script):
  `Handoff` and `ReaderView` against the real WASM, built with the
  `test-hooks` feature so a deliberate Rust panic can test crash recovery.
- **Service worker** (`tests/background.html`): imports `background.js` with
  a stubbed `chrome` global: incognito tab vs popup, menu filtering, handoff URL and
  one-time claim, sender checks.
- **Manifest policy and CSP** (`tests/manifest-policy.html`,
  `tests/csp.html`): the first lints the manifest (permissions, allowed
  keys, CSP tokens), `reader.html` and `reader.css`; the second applies the
  manifest's CSP as a `<meta>` policy and asserts that remote `fetch`/image
  are blocked while WASM and the reader still work. A meta-CSP is not
  Chrome's extension-page CSP, so the real one remains a manual check.
- **Release build** (`tools/verify-release-build.sh`): a feature-less release
  build must not contain `panicForTest`; a test-hooks build is the positive
  control.
- **Extension end-to-end:** not automated yet. Google Chrome ignores
  `--load-extension`; Chrome for Testing allows it. Until then, load the
  unpacked extension by hand (see `CLAUDE.md`). `dev/preview.html` runs the
  reader with sample text over localhost for visual checks.

## Upstream baseline

chromeGIST builds against the GIST commit pinned in `Cargo.toml` (a git
dependency on GitHub), not against whatever is on disk. chromeGIST exists to
reuse GIST, so reviewing upstream changes is part of the normal development
cycle, not a one-off. (Process inherited from contextGIST.)

**How it's enforced.** `UPSTREAM_BASELINE` records the last GIST commit
chromeGIST was reviewed and tested against; it always equals the `rev` in
`Cargo.toml`. `tools/upstream-review.sh` keeps a read-only clone of GIST at
the gitignored `.upstream/gist` (override with `GIST_UPSTREAM`) and compares
GitHub `main` (or `--ref <ref>`) with the baseline:

- **Every build:** `tools/build-wasm.sh` (and so `tools/test-browser.sh`)
  runs `upstream-review.sh --check`, which prints a warning when GIST code
  chromeGIST uses has changed since the baseline, as of the clone's last
  fetch. It is offline, never fails the build, and is a no-op until the
  first full review has created the clone.
- **Every release:** packaging will run `--check --strict` and refuse until
  the review is done (Phase 3).
- **Start of a work session:** run `tools/upstream-review.sh` (it fetches),
  so work starts from a reviewed upstream.

**Doing a review.** `tools/upstream-review.sh` groups changes by how they
can reach chromeGIST. For each item, decide *adopt*, *port* or *skip*:

1. **Shared crates** (`gist-model`, `gist-parse-txt`, `gist-rsvp`): compiled
   into the WASM; they change only when `--record` moves the pin. Check the behaviour
   change is wanted, run both test suites, and update any test that pins
   upstream behaviour (e.g. `line_ending_styles`). Re-check the WASM build
   too: a new upstream dependency may not support wasm32.
2. **GIST's Swift RSVP view** (`apps/apple/macOS/RsvpView.swift`): pacing
   isn't ported here, but reader-UI and ORP-display fixes may apply to
   `reader.js`.
3. **Icon artwork** (`assets/`): re-copy and regenerate the extension icons.
4. **Security/dependency policy** (`deny.toml`, GIST's security reviews):
   mirror what applies.
5. **Everything else**: usually GIST-only, but skim for shared ideas.
6. **GIST issues mentioning chromeGIST or contextGIST**: a closed one may
   need a matching change here.

Then record it with `tools/upstream-review.sh --record "<what was adopted,
ported or skipped>"`. That moves the `rev` in `Cargo.toml` to the reviewed
commit, runs `cargo test --workspace`, and on success updates
`UPSTREAM_BASELINE` and adds a row below (on failure it restores
`Cargo.toml`/`Cargo.lock`). Commit them together with any adopted changes
(and run `tools/gen-third-party.sh` if dependencies changed). (Run `tools/test-browser.sh` as well; `--record` only
runs the native tests.)

History of reviews (the first two were contextGIST's, inherited at the
fork):

| Date | GIST commit | Branch | Notes |
|---|---|---|---|
| 2026-09-30 | `24f4138` | `integration/m4-2026-09-28` | contextGIST: upstream changes since its 2026-09-25 scaffold reviewed; ported the `elapsedMs` rounding fix. |
| 2026-09-30 | `9dc537c` | `main` | contextGIST: adopted the #76 paragraph-break fix (PR #77). chromeGIST forked from contextGIST at this baseline. |
| 2026-10-01 | `fb6946a` | `origin/main` | chromeGIST: moved from a local-path dependency to rev-pinned git deps on GitHub. Adopted GIST #79 (orp_index counts grapheme clusters, fixes #78); Reader's cluster snapping is now a no-op kept as a defence. |
| 2026-10-03 | `d5b2de7` | `origin/main` | criterion dev-dep bump only; all other changes (imageprep/epub hardening, dep bumps) not used by chromeGIST, skipped |
| 2026-10-04 | `0293fee` | `origin/main` | toolchain bump (#89) and docs-only (#88) changes; not used by chromeGIST, skipped |
| 2026-10-25 | `9be1700` | `9be1700` | Adopted GIST 9be1700: MAX_TOKEN_BYTES chunking and memoised pacing schedule (gist-rsvp), pause_on_punctuation (default on, no UI yet), encoding detection in gist-parse-txt unused but compiled in (wasm 125K -> 394K). Skipped: Windows/Linux/Apple/DOCX/PDF/storage work, gist-web deps. Native, browser tests and cargo deny pass. |

### WASM size

Release profile: `opt-level = "s"`, `lto`, `codegen-units = 1`,
`strip = "symbols"`. Measured on GIST `9be1700`: 394 KB before the last two
settings, 348 KB after; `WASM_OPT=1 tools/build-wasm.sh` (binaryen `-Oz`)
brings it to 328 KB. `opt-level = "z"` was larger. Before GIST `9be1700` the
module was 125 KB; the other ~200 KB is `encoding_rs`/`chardetng` tables that
`gist-parse-txt` now always links for encoding detection, which chromeGIST
never needs (JS strings are already UTF-8). Only an upstream Cargo feature
for that detection can remove them.

Everything else in GIST (`gist-store`, `gist-core`, the other parsers,
`gist-web`, `gist-imageprep`, `gist-ffi`) is intentionally not used.
chromeGIST never has a file path or a database; its only input is a string
already in memory.
