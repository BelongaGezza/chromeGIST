# Development plan

Written 2026-09-30, when chromeGIST was forked from contextGIST. Read
`docs/ARCHITECTURE.md` first: this plan assumes its design (GIST's crates
in WASM, `Reader` wrapping GIST's own pacing session, `contextMenus`-only
extension, nothing persisted).

Guiding principles, carried over from contextGIST:

- **Reuse, don't port.** Reading logic comes from GIST. chromeGIST goes
  further than contextGIST: pacing runs from `gist-rsvp` itself instead of
  a hand copy.
- **Narrow and private by construction.** Least permissions, no network,
  no persistence, input-only. Every phase re-checks this.
- **Test the risky assumption first, in the real environment** (a browser,
  not just `cargo test`).

## Phase 0 — Spike: can GIST's core run as WASM in Chrome? (done)

- [x] Fork contextGIST (full history; `contextgist` remote), remove the
  macOS app, and replace `contextgist-ffi` (uniffi) with
  `crates/chromegist-wasm` (wasm-bindgen).
- [x] `Reader` API wrapping GIST's `RsvpSession`: tokenize, ORP split,
  progress, play/pause/seek/WPM. 17 native tests, including contextGIST's
  adversarial tests (all passing, clippy/rustfmt clean).
- [x] **uuid on wasm32:** confirmed the predicted blocker. GIST's
  `Document::new` → `uuid::now_v7()` doesn't compile for
  `wasm32-unknown-unknown` without a randomness source. Fixed with uuid's
  `js` feature from chromeGIST's manifest (no GIST change). Verified at
  runtime.
- [x] **Browser test harness:** `tools/test-browser.sh` runs test pages in
  headless Chrome (throwaway profile). 6/6 pass in Chrome 154: runtime
  tokenizing, the 512 KiB cap (measured in UTF-8 bytes, which a JS string's
  `.length` would miss for accented text), GIST pacing timings,
  grapheme-safe ORP, and performance.
- [x] **Performance:** 512 KiB (83k words) tokenizes in ~35 ms. Worst-case
  tick 0.94 ms (budget: 60 ms/word at 1000 WPM). A hand-ported JS pacing
  engine isn't needed.
- [x] **New finding: GIST's ORP can split a character.** `orp_index` works
  in code points and can land on a ZWJ (emoji families), the second
  regional indicator of a flag, or a combining mark. `Reader` snaps to the
  whole grapheme cluster. Reported upstream as
  [gist#78](https://github.com/BelongaGezza/gist/issues/78); when it's
  fixed (GIST #79, adopted 2026-10-01), `Reader`'s snapping is a no-op (kept
  as a defence, with its test).
- [x] **New finding: panics abort in WASM.** `catch_unwind` doesn't work on
  wasm32, so the reader page must recover from a `RuntimeError:
  unreachable` itself (Phase 1).

## Phase 1 — Minimum usable extension

- [x] `apps/chrome/manifest.json` (MV3): `contextMenus` permission only;
  CSP `extension_pages` with `'wasm-unsafe-eval'`; icons.
- [x] `background.js` service worker: menu item for `contexts:
  ["selection"]`; on click, stores the text in `Handoff` (in memory, random
  one-time id, 60 s expiry) and opens `reader.html#<id>` as a popup window.
  No `chrome.storage` at all (`storage.session` would need a `storage`
  permission). Only the extension's own reader page may claim text.
- [x] `reader.html/js/css` + `reader-core.js`: word display (monospace,
  `ch`-based ORP centring, reticle, red focus letter), progress, controls
  (back/play-pause/forward 5 words, WPM slider 100–1000), keyboard (space,
  arrows, Escape closes), light/dark, and states for loading, "too long",
  "no words", "expired" and "crashed". Play at the end restarts.
  `reader-core.js` has no extension-API dependency, so it's tested on a
  plain page; `reader.js` just claims the text.
- [x] **WASM panic recovery:** every `Reader` call goes through
  `ReaderView.guard`; a `WebAssembly.RuntimeError` drops the instance and
  shows an error. `Reader.panicForTest()` (Cargo feature `test-hooks`, only
  in test builds) proves it: the view recovers with no stray timers.
- [x] Extension icons (16/32/48/128) from `assets/gist-macos-app-icon.png`
  via `tools/gen-icons.sh`: transparent background with the glow kept,
  artwork in the central 96/128 per Chrome's guideline.
- [x] Tests: `tools/test-browser.sh` now also runs `tests/extension.html`
  (13 checks: handoff one-time claim and expiry, autoplay, pacing,
  pause/resume, skip, WPM, keyboard, end-of-text restart, too-long, empty,
  panic recovery, paragraph breaks). 19/19 browser checks pass; with the
  2026-10-01 additions (`background`, `manifest-policy`, `csp`) 39/39.
- [x] Visual check in a real Chrome (via `dev/preview.html` over
  localhost): ORP letter stays under the reticle; `👍🏽` shows whole.
- [ ] **Automated extension-level tests need Chrome for Testing.** Google
  Chrome ignores `--load-extension` ("not allowed in Google Chrome"), even
  with the feature override, so manifest/service-worker/CSP can't be
  checked headlessly with the installed browser. Chrome for Testing (a
  separate download) allows it; worth adding before Phase 3.
- [ ] Manual checks in a real Chrome profile (load unpacked): plain pages,
  text in inputs/textareas, iframes, **Chrome's PDF viewer**, and very long
  selections (truncation confirmed; see the security review). Record results
  in `docs/`.

## Phase 2 — Hardening, privacy, accessibility

- [x] chromeGIST security review (`docs/SECURITY_REVIEW.md`, 2026-10-01,
  from code): permissions, CSP, message-origin checks, where the text lives
  and when it's released, service-worker lifetime, the panic path, supply
  chain. **Follow-ups it found:** tighten the CSP (`default-src 'none'`,
  `connect-src 'self'`); open the reader in the clicking window when
  incognito (or set `"incognito": "not_allowed"`); make packaging reject `panicForTest`; clean
  contextGIST wording and the unused `MPL-2.0` from `deny.toml`. Re-verify
  the CSP and incognito behaviour in a real Chrome load.
- [x] **Security remediations (2026-10-01):** CSP tightened (`default-src
  'none'`, `connect-src 'self'`, ...) with `tests/manifest-policy.html` and
  `tests/csp.html`; incognito selections open the reader as a tab in the same incognito
  window (`tests/background.html`; a first attempt using
  `windows.create({incognito: true})` was blocked by Chrome, found in the
  manual pass); `tools/verify-release-build.sh` and a
  test build that never touches `apps/chrome/pkg/`; `deny.toml` cleaned.
  Decision: no selection-length guard in the service worker.
- [ ] **Manual real-Chrome checks for those fixes:** CSP blocks `fetch` and
  images in the reader page and the service worker (**done, passed
  2026-10-01**); incognito: the reader loads as a tab in the incognito window
  and a real selection from an incognito tab shows its text (**done,
  passed 2026-10-01**); `selectionText` truncation confirmed at about 7,500 words (**done**; the reader
  now ends every selection with a caution that Chrome may shorten very long
  selections; no limit is hard-coded).
- [x] Rewrite `docs/PRIVACY.md` for the extension (2026-10-01). It maps onto
  the Chrome Web Store privacy-practices form; re-check before submission.
- [ ] Accessibility: screen-reader labels (ChromeVox/VoiceOver), live
  region politeness during playback (don't announce every word), focus
  order, keyboard-only use, contrast of the focus letter in light/dark
  (`prefers-color-scheme`), `prefers-reduced-motion`.
- [ ] Popup window size/position behaviour; multiple readers at once.

## Phase 3 — Packaging and Chrome Web Store

- [x] `tools/package-extension.sh` (written 2026-10-25, allow-list, reproducible zip): `upstream-review.sh --check --strict`,
  both test suites, `cargo deny`, `tools/verify-release-build.sh`, then zip
  `apps/chrome` (excluding `tests/` and `dev/`) with
  `THIRD_PARTY_NOTICES.txt`.
- [x] Packaging rebuilds `pkg/` from scratch without features and writes a
  `BUILD_INFO` next to the zip: rustc version, wasm-bindgen version,
  `Cargo.lock` sha256 and the GIST rev (security review finding #7).
- [ ] Pre-submission manual checklist: load unpacked; context menu on plain
  pages, inputs, iframes and the PDF viewer; `fetch` blocked from reader and
  service-worker consoles; incognito behaviour; long-selection truncation;
  accessibility checks.
- [ ] Versioning (manifest `version`), changelog.
- [ ] Chrome Web Store: developer account (one-off fee), listing text,
  screenshots, privacy-practices answers ("no data collected"), single
  purpose description, permission justification for `contextMenus`.

## Phase 4 — Microsoft Edge (in scope), other browsers (not yet)

- [ ] **Microsoft Edge** (in scope, decided 2026-09-30): Chromium, so the
  same package should work unchanged. Test it in Edge (load unpacked),
  including Edge's own PDF viewer, then submit to Edge Add-ons (a separate
  Partner Center account).
- [ ] Firefox: not in scope for now. MV3 with small manifest differences
  (`browser_specific_settings`, background script vs service worker); WASM
  works the same.

## Cross-cutting

- [ ] **Upstream review** (GIST): at the start of each work session and
  whenever the build warns, run `tools/upstream-review.sh`, act, and
  `--record` it. See `docs/ARCHITECTURE.md` "Upstream baseline".
- [ ] **Sibling sync** (contextGIST): when contextGIST fixes something in a
  shared idea (cap, adversarial tests, deny policy, review tooling), `git
  fetch contextgist` and cherry-pick or port it.
- [ ] **Parity tests across GIST ports:** chromeGIST runs `gist-rsvp`
  directly, so its durations are the reference. A shared fixture of
  inputs → expected tokens/ORP/durations could also check contextGIST's
  hand-ported Swift `PacingEngine` against it.
- [ ] Security baseline on every change: no new permissions, no network,
  nothing persisted, input-only.

## Decisions (2026-09-30)

1. GIST's ORP grapheme issue: **reported upstream** as
   [gist#78](https://github.com/BelongaGezza/gist/issues/78).
2. **Context menu only, no keyboard shortcut.** A shortcut would need
   `activeTab` + `scripting` to read the selection; not worth the extra
   permission surface. `contextMenus` stays the only permission.
3. **Edge is in scope** (Phase 4). **Chrome Web Store developer account:
   deferred** until Phase 3; what it requires still needs looking into.

## Open questions

1. Chrome Web Store account: requirements, cost, publisher identity
   (Phase 3).
2. Does the context menu work in Chrome's (and Edge's) PDF viewer? (Phase 1
   manual checks.) *Resolved:* Chrome does truncate very long `selectionText`
   (about 7,500 words observed); the reader shows an end-of-selection
   caution.
