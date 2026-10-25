# Security review — chromeGIST, 2026-10-01

Point-in-time manual review of the extension at commit `5262206` (v0.1.0,
unreleased, GIST pinned at `fb6946a`). Every file below was read in full:
`apps/chrome/{manifest.json,background.js,handoff.js,reader.js,reader-core.js,reader.html,reader.css}`,
`crates/chromegist-wasm/src/lib.rs`, `Cargo.toml`, `deny.toml`, and
`tools/build-wasm.sh`; the generated `pkg/*.js` glue was searched for
network, storage and eval use. GIST's crates were not re-audited (they are
covered by the adversarial tests and the upstream-review process).

This replaces the inherited contextGIST (macOS) review. That review's
size-cap and dependency-pinning findings carried over and are applied here
(findings #3 and #7); its macOS-specific ones (App Sandbox, signing,
`NSSendTypes`) don't apply. **Real-Chrome checks (2026-10-01, in progress):** the
context menu and reader work, and the CSP is enforced in both the reader page
and the service worker (see "Manual checks" below). Incognito behaviour was
observed and changed the fix for finding #2, which is now verified. Truncation of `selectionText` is
still to be measured. The remaining checks are listed below and in
`docs/DEVELOPMENT_PLAN.md`. Re-run this review before the first Web Store
submission and whenever permissions, the manifest or the messaging change.

## Manual checks (real Chrome profile, load unpacked)

Observed 2026-10-01 (Chrome version: record from `chrome://version`):

1. **Done, passed.** The reader opens and plays from the context menu.
2. **Done, passed.** CSP is enforced by Chrome in both contexts:
   - Reader page console: `fetch("https://example.com")` is refused
     (`connect-src 'self'`), `new Image().src = "https://example.com/x.png"` is
     refused (`img-src 'self'`), and `fetch(chrome.runtime.getURL("manifest.json"))`
     returns 200.
   - Service worker console: the same `fetch` is refused (`connect-src 'self'`)
     and the same-origin control returns 200. So the `extension_pages` policy
     does govern the worker.
3. **Done, changed the fix.** Incognito, with "Allow in Incognito" on
   (`chrome.extension.isAllowedIncognitoAccess()` returned `true`):
   - `chrome.windows.create({url: <reader.html>, type: "popup", incognito: true})`
     succeeds but the popup shows `ERR_BLOCKED_BY_CLIENT`.
   - The same call with `incognito: false` loads the page (in a regular
     window).
   - `chrome.tabs.create({windowId: <incognito window>, url: <reader.html>})`
     loads the page in the incognito window.
4. **Superseded 2026-10-25 (see finding #2).** With the tab-based path (fresh load, Allow in Incognito
   on), selecting text in an incognito tab opens the reader in the incognito
   window and it plays the text (not "expired"), so the claim message from
   the incognito tab reaches the spanning worker.
5. **Done, truncation confirmed.** With a very long selection Chrome passed
   the reader only part of it: about 7,459 words of test text (not measured
   precisely; the limit is Chrome's and may change between versions).
   Decision: don't try to detect or track the limit; the reader shows a
   standing caution at the end of every selection (finding #3).
6. Optional: text in `<textarea>`, iframes and Chrome's PDF viewer.

## Summary

The attack surface is small. The extension has one permission
(`contextMenus`), no host permissions, no content scripts, no
`web_accessible_resources`, no `externally_connectable`, and no storage. The
only input is the selection string Chrome hands the service worker, and the
only consumer is the extension's own reader page. No injection or memory-
safety issue was found: the reader renders text only through `textContent`
and `aria-label` (never `innerHTML`), there's no `eval`, and the first-party
Rust has no `unsafe`. There is no remote-exploitable finding. The findings
below are hardening and privacy-hygiene gaps, ranked by what could go wrong.

| # | Severity | Finding | Status |
|---|---|---|---|
| 1 | Medium | CSP doesn't enforce "no network" | Fixed and verified in real Chrome 2026-10-01 (reader page and service worker both block remote `fetch`/images) |
| 2 | Low–Medium | Incognito: reader may open outside the incognito window | **Reopened 2026-10-25** (the 2026-10-01 fix opened a regular-window tab); now `"incognito": "split"`, verified in real Chrome 2026-10-25. Previously: fixed and verified 2026-10-01 (a first attempt failed there; see finding) |
| 3 | Medium | Oversized selection and panics (DoS, crash-report leak) | Mitigated; residual noted; no length guard (decision 2026-10-01) |
| 4 | Low | No memory scrubbing | Decision recorded |
| 5 | Low | Test-only `panicForTest` export could ship | Fixed 2026-10-01 (`tools/verify-release-build.sh`); packaging must call it |
| 6 | Low | Stale contextGIST text in `deny.toml` | Fixed 2026-10-01 |
| 7 | Low | Supply chain: GIST pin, wasm-bindgen, build reproducibility | Mitigated; packaging TBD |

## Findings

### 1. [Medium → fixed] The CSP didn't enforce "no network"

**Status (2026-10-01): fixed.** `manifest.json` `extension_pages` is now
`default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'`
(`frame-ancestors` omitted: `reader.html` isn't web-accessible).
Evidence: `tests/manifest-policy.html` pins the manifest (permissions,
allowed keys, CSP tokens) and lints `reader.html`/`reader.css` for inline
script/style, `on*=`, `url(` and `@import`; `tests/csp.html` applies the
manifest's policy as a `<meta>` CSP in headless Chrome and shows a remote
`fetch` and `<img>` are blocked (`securitypolicyviolation`), while WASM
instantiates, a `ReaderView` runs and `style.setProperty("--orp-offset")`
raises no violation. The headless test uses a meta-CSP, which enforces the
same directives but isn't Chrome's extension-page CSP, so it was also
**verified in a real Chrome profile (2026-10-01)**: in the reader page and in
the service worker, `fetch("https://example.com")` is refused
(`connect-src 'self'`), a remote image is refused (`img-src 'self'`), and the
extension's own `manifest.json` still fetches (manual checks 1-2 below). The
`extension_pages` policy therefore does govern the service worker.

Original finding:

`manifest.json` sets only
`script-src 'self' 'wasm-unsafe-eval'; object-src 'self'`. That stops
inline and remote *scripts*, but there is no `default-src` or `connect-src`,
so a `fetch()` or `<img src>` from an extension page would not be blocked by
policy. Today none exists (verified by search, `docs/PRIVACY.md` §7), so the
claim "chromeGIST makes no network requests" rests on code review and
`cargo deny`'s ban on networking crates, not on a browser-enforced
guarantee. Contrast contextGIST, where the App Sandbox enforced it.

**Recommendation:** tighten `extension_pages` to something like
`default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'`
(`connect-src 'self'` is needed for the WASM loader's `fetch` of its own
file), then add an assertion to `tests/extension.html` that a cross-origin
`fetch` is rejected. Confirm in a real extension load that the WASM still
instantiates. The browser test pages are served over localhost and don't
exercise the manifest CSP, so this needs the Chrome-for-Testing end-to-end
step.

### 2. [Low–Medium → fixed with "split", verified] Incognito: reader window may open as a regular window

**Correction (2026-10-25): the fix described below did not work.** Testing
the F7 change in a real Chrome (incognito allowed) showed that
`chrome.tabs.create({url, windowId: <incognito window>})` from the spanning
worker returned a tab in a **regular** window (it asked for the incognito
window and got a tab in a regular window, `incognito: false`). The 2026-10-01 "verified" result (manual
check 4) only showed that the reader displayed the text; before the F7
handoff check there was nothing that would fail if the window was a regular
one, so that check could not tell the difference. The F7 check (an incognito
selection refused to a non-incognito reader) is what exposed it: the reader
said "This selection has expired." Lesson: verify the *window kind*, not just
that text appears.

**Fix (2026-10-25): `"incognito": "split"`.** Chrome runs a second instance
of the service worker inside incognito, with its own in-memory `Handoff`, and
that instance opens the reader (`background.js`). It creates its own context
menu at startup (`chrome.extension.inIncognitoContext`) rather than relying
on `onInstalled`. `tests/manifest-policy.js` now rejects `spanning` and
requires `split` or `not_allowed`. The F7 check stays as defence in depth.
**Verified in real Chrome (2026-10-25):** with "Allow in Incognito" on, the
menu item appears in incognito and the reader opens in the incognito window
with the text. (Recorded from the user's manual test.)

If "split" doesn't work, the safe fallback is `"incognito": "not_allowed"`
(the extension is then unavailable in incognito).

The remainder of this section is the original 2026-10-01 write-up, kept for
history; its "spanning" and "verified" statements are superseded.

**Status (2026-10-01): fixed and verified in real Chrome.**
`background.js` now checks `tab?.incognito === true`: for an incognito tab it
opens the reader with `chrome.tabs.create({url, windowId: tab.windowId})`, a
tab in the same incognito window; otherwise it opens the usual popup (and
never passes an `incognito` flag). Both calls are in a try/catch (a failed
open leaves the text to expire via the 60 s TTL). The manifest states
`"incognito": "spanning"` explicitly (the default; "split" can't share the
in-memory handoff). Only `tab.incognito` and `tab.windowId` are read from
`tab`; neither needs the `tabs` permission.

**What went wrong first:** the first fix passed `incognito: true` to
`chrome.windows.create`. It passed the unit test (which only checked the
flag), but in a real Chrome the popup was blocked
(`ERR_BLOCKED_BY_CLIENT`). Observed results are in the manual-checks list
above: an incognito popup of an extension page is blocked, a regular popup
loads, and an extension tab inside the incognito window loads. Lesson: the
stubbed test can't tell what Chrome allows; real-Chrome verification is
required for anything involving window or profile behaviour.

Evidence: `tests/background.html` (stubbed `chrome`: incognito tab opens a tab
in the same window; normal, missing and windowless tabs open a popup with no
`incognito` flag; wrong menu id or empty selection; URL shape; one-time
claim; foreign senders refused; failed open doesn't throw).
**Verified in a real Chrome profile:** selecting text in an incognito tab
opens the reader in that window and shows the text (manual check 4).

Original finding:

The manifest has no `incognito` key, so the default (`spanning`) applies:
if the user turns on "Allow in Incognito", the one extension process serves
both profiles. `background.js` calls `chrome.windows.create({type: "popup"})`
without an `incognito` flag, and Chrome's documented default for that is a
non-incognito window. Text selected in an incognito tab would then open in a
regular-profile window. Nothing is stored either way, so the leak is
limited to window placement and anything Chrome records about a regular
window (session restore of a popup is the case to check), but it undermines
the expectation that incognito reading stays in incognito.

**Recommendation:** pass `incognito: tab.incognito` (the click handler
already receives `tab`; this reads one boolean, not page data), then confirm
in Chrome. Alternatively set `"incognito": "not_allowed"` if reading in
incognito isn't a goal; that is the safest default, and the user can't enable
it by mistake. **Unverified** until tried in a real profile.

### 3. [Medium → mitigated] Unbounded selection and panics

Same finding as contextGIST #1: a huge selection costs time and memory, and
a crash while text is in memory could put it in a crash report.

- `Reader::new` rejects selections over 512 KiB of UTF-8
  (`MAX_SELECTION_BYTES`, `lib.rs`), measured in bytes, not JS string length
  (tested). A 512 KiB selection tokenizes in about 44 ms; the worst-case tick
  is 0.95 ms (re-measured 2026-10-25 on GIST `9be1700`: construction 19-53 ms
  and 200 ticks under 0.2 ms, 11 ms for combining-mark abuse; see the
  addendum for the long-word display bug found then).
- Panics **abort** in WASM (there's no unwinding, so contextGIST's
  `catch_unwind` containment can't work). Instead `ReaderView.guard` turns
  the resulting `WebAssembly.RuntimeError` into an error message, drops the
  dead instance and stops all timers (`reader-core.js`). `panicForTest` and
  `tests/extension.html` prove it. The adversarial-input tests (long words,
  bidi, ZWJ, degenerate whitespace, control characters, seeded pseudo-fuzz)
  found no panics in GIST's tokenizer or ORP code.
- A WASM trap doesn't crash the renderer, and no panic hook is installed,
  so the panic message (which can quote input in some std panics) is never
  written anywhere.

**Decision (2026-10-01): no length guard in the service worker.** The reader
page remains the authoritative, byte-accurate cap; a `.length` check in the
worker would add a second, UTF-16-based limit for negligible gain.

**Chrome truncates `info.selectionText` (observed 2026-10-01).** A very long
selection arrived cut at roughly 7,500 words, far below the 512 KiB cap, so
the size cap is effectively never reached and the denial-of-service risk
above is smaller than assumed. The cost is a *silent partial read*: the user
sees the first part of their selection and may think it was all of it.
Because the extension only sees the shortened string, it can't tell that a
cut happened, and the cut-off may change with Chrome versions, so no
threshold is hard-coded. **Decision:** the reader shows a standing caution
whenever playback reaches the end of a selection ("End of selection. Chrome
may shorten very long selections, so if you selected a lot of text, some may
not have been shown."; `END_NOTE` in `reader-core.js`, covered by
`tests/extension.js`). It is cleared when playback restarts or the reader
skips, and is not shown on error or empty-selection messages. Reading the
full selection from the page would need `activeTab` and `scripting` and was
rejected to keep the one-permission, no-page-access model. A
page that doesn't support selecting that much text is a poor fit for this tool
anyway.

Residual: (a) the cap is enforced in the reader page, after the service
worker has already received the text, so the worker holds up to whatever
Chrome supplies for at most 60 s. That is bounded and negligible. (b) Chrome
truncates `selectionText` for very long selections (confirmed above); the
end-of-selection caution is the only mitigation. (c) A crash for any other reason (a browser
bug, or OOM on a very constrained machine) could still yield a crash report
containing text if the user has enabled crash-report sharing.

### 4. [Low] No explicit memory scrubbing

JavaScript strings and WASM linear memory aren't zeroed when dropped, and
there's no API to do it. The handoff deletes its reference on claim or expiry
and the reader drops its copy after tokenizing, but copies exist outside
chromeGIST's control: Chrome's own `selectionText` construction, the page,
the IPC to the worker, rendered glyph caches and the accessibility tree
(`aria-label` carries the current word). Zeroing chromeGIST's buffers would
not make "wiped from memory" true.

**Decision (2026-10-01): no explicit zeroing**, as for contextGIST. The claim
is "we never write it anywhere". Closing the reader window destroys its
page, and the service worker is terminated by Chrome when idle. Revisit only
if the product wants a stronger claim. (Unlike contextGIST's process-per-use
app, Chrome may keep the renderer process around, so process exit is not
the wipe here.)

### 5. [Low → fixed] `panicForTest` must never ship

**Status (2026-10-01): fixed.** `tools/build-wasm.sh` takes `OUT_DIR`;
`tools/test-browser.sh` now builds the test-hooks WASM into a staged copy
of the extension in its temp dir, so the real `apps/chrome/pkg/` is never a
test build. `tools/verify-release-build.sh` builds a release into a temp dir
with `FEATURES` unset, fails if `*.js`/`*.wasm` match `panic_?for_?test`, and
runs a positive control (a `test-hooks` build must match). Phase 3 packaging
must run it (see the plan). Original finding:

`Reader.panicForTest` exists only under the Cargo feature `test-hooks`
(`lib.rs`), which `tools/test-browser.sh` sets. `pkg/` is gitignored and
regenerated by `tools/build-wasm.sh`, whose default `FEATURES` is empty, so a
default build is clean. But a stale `pkg/` from a test run could be zipped by
mistake.

**Recommendation (Phase 3):** `tools/package-extension.sh` should always
rebuild `pkg/` from scratch without features and fail if the glue contains
`panicForTest`. The `tests/` and `dev/` folders must be excluded.

### 6. [Low → fixed] `deny.toml` still carried contextGIST wording

**Status (2026-10-01): fixed.** Removed `MPL-2.0` and
`Apache-2.0 WITH LLVM-exception` (neither is in the graph), rewrote the
header, licence comments and ban comment (now cites the CSP and review).
`cargo deny --exclude-dev check` is warning-free;
`tools/gen-third-party.sh` produces no diff. Original finding:

The policy passes (`cargo deny --exclude-dev check`: advisories, bans,
licences, sources ok), but it has a stale unused allowance (`MPL-2.0`,
"uniffi", which chromeGIST doesn't use, so `cargo deny` warns
`unmatched license allowance`), and the networking-ban comment still cites
the App Sandbox. These are cosmetic but misleading in a security policy.
The ban list itself (`openssl`, `rustls`, `ureq`, `reqwest`, `hyper`,
`tokio`) is correct, and `unknown-git`/`unknown-registry` are denied with
only the GIST repo allowed.

**Recommendation:** drop `MPL-2.0` and the uniffi/App-Sandbox comments, and
check that `docs/THIRD-PARTY.md` doesn't claim an MPL obligation.

### 7. [Low → mitigated] Supply chain

- **GIST** is pinned by commit `rev` and hash-locked in `Cargo.lock`, the
  source is allow-listed in `deny.toml`, and a local checkout can't influence
  the build. Moving the pin requires `tools/upstream-review.sh --record`
  (tests + review log). This resolves contextGIST's path-dependency finding.
- **wasm-bindgen:** the CLI version must equal the `wasm-bindgen` crate in
  `Cargo.lock`; `tools/build-wasm.sh` enforces that. The generated glue
  contains `fetch(module_or_path)` (loading the extension's own `.wasm`),
  `crypto.getRandomValues` and `Date.now` (for uuid on wasm32), and
  `console.warn` deprecation notices. No eval, storage or other network APIs.
- **JavaScript dependencies: none.** The extension has no npm packages, no
  CDN scripts and no bundler.
- **Open (Phase 3):** the build isn't yet reproducible-by-script end to end
  (`pkg/` is built on the developer's machine). Packaging should record the
  toolchain and `Cargo.lock` hash, and run `upstream-review.sh --check
  --strict` and `cargo deny`.

## Message handling and the handoff (checked, no finding)

- A web page can't message the extension: there is no
  `externally_connectable`, and no content scripts exist to relay messages.
  `onMessage` additionally requires `sender.id === chrome.runtime.id` and a
  sender URL under `reader.html` (`background.js`), so even another
  extension page would be refused.
- `reader.html` isn't in `web_accessible_resources`, so a web page can't
  open or frame it.
- The handoff id is `crypto.randomUUID()` (unguessable), single-use, expires
  after 60 s, and is removed from the reader's address bar on load. It lives
  in the URL fragment, which is never sent over a network. A *failed* claim
  (wrong id) also deletes nothing it shouldn't: `take` deletes only the id it
  was given.
- Unclaimed text can't accumulate: each `put` also schedules its own
  deletion, and the map is swept on every call.
- If the worker is killed between click and claim, the reader shows the
  "expired" message and the text is simply lost: safe, if slightly
  inconvenient. Unverified in practice because the 60 s expiry sits well
  inside Chrome's idle limits for a worker with a pending window.

## Addendum 2026-10-25: re-review at GIST `9be1700`

An independent read-only review (subagent) re-verified findings #1, #2, #5,
#6 and #7 as still holding, and found the following after the pin moved.
`cargo test` and `cargo deny` passed throughout. Not run in a real Chrome
profile.

| ID | Severity | Finding | Status |
|---|---|---|---|
| F1 | Medium | `Reader` built its display tables from the unsplit tokens, but GIST now splits words over 256 bytes inside `RsvpSession::new`. Any such word (URL, base64) made the display show wrong words, blank frames and wrong progress, and let a 512 KiB word render unsplit. | Fixed 2026-10-25: tables are built from `session.tokens`; tests `display_matches_session_for_oversized_words` |
| F2 | Low | `tokenize` re-decodes the text's UTF-8 through GIST's encoding sniffing, so a page planting NULs could make it guess UTF-16 and show other characters. | Fixed 2026-10-25: U+0000 removed first; test `nul_cannot_trigger_utf16_misdetection`. GIST #132 would remove the detector |
| F3 | Low | Bidi controls rendered raw (reversed words); zero-width-only tokens showed blank frames. | Fixed 2026-10-25: bidi embedding/override/isolate controls stripped, invisible-only tokens dropped, `.word` has `unicode-bidi: isolate` |
| F4 | Info | `tools/package-extension.sh` doesn't exist, so nothing excludes `tests/` and `dev/` yet. | Fixed 2026-10-25: `tools/package-extension.sh` ships an allow-list and refuses unlisted files |
| F5 | Info | `WASM_OPT=1` output isn't covered by `test-browser.sh` by default; cargo runs without `--locked`. | Browser tests passed on the `WASM_OPT=1` build 2026-10-25; `--locked` added to `build-wasm.sh`; `BUILD_INFO` records the wasm-opt version |
| F6 | Info | `gen-icons.sh --refresh-source` downloads unpinned from GitHub `main`. | Fixed 2026-10-25: `--refresh-source` downloads at a pinned GIST commit (`ICON_REF`, 40-hex only); the download matched the committed artwork byte for byte |
| F7 | Info | Incognito and normal selections share one service worker's memory for up to 60 s; `take` doesn't compare `incognito`. Not exploitable. | Fixed 2026-10-25, and it caught the finding #2 regression the same day: `Handoff.put/take` carry the incognito state and `take` releases text only to a reader in the same state (`sender.tab.incognito`); tests in `tests/extension.js` and `tests/background.js`. Verified in real Chrome 2026-10-25 as part of finding #2: an incognito selection reaches its reader |
| F8 | Info | Space `keydown` is prevented, but a focused button may still activate on keyup. | Fixed 2026-10-25 in code: the global handler ignores Space when a button has focus (the button activates itself); test added. Verified in real Chrome 2026-10-25: Space with a button focused toggles play/pause once |
| F9 | Low | Found 2026-10-25 while preparing the public release: the built `.wasm` embedded the builder's home-directory paths (`/Users/<name>/.cargo/...`, `.rustup/...`) in panic-location strings, so a shipped package would have published the builder's username. | Fixed: `tools/build-wasm.sh` remaps CARGO_HOME, the Rust sysroot and the repo root with `--remap-path-prefix`, and `tools/package-extension.sh` fails if the package contains `$HOME`, the repo path or the user name (tested with a planted path). No package had been published. |

Documentation claims corrected the same day: the `console` calls in
`docs/PRIVACY.md` section 4, the truncation wording in `CHROMEWEBSTORE.md`,
and the third-party description in `docs/PRIVACY.md` section 6.

## Strengths worth preserving

Hold every future change (and the Edge port) to these:

- One permission, `contextMenus`; no host permissions or content scripts.
  Adding any permission needs a note here and a privacy-doc update.
- No storage of any kind, no network calls, no analytics, no remote code.
- No logging of selected text or anything derived from it.
- No `innerHTML`, `eval` or inline script in the extension; text reaches the
  DOM only via `textContent` and `aria-label`.
- No `unsafe` in first-party Rust (`crates/chromegist-wasm`); GIST pinned and
  hash-locked; `cargo deny` policy with a networking-crate ban.
- Display tables are built from the pacing session's own tokens, and the
  text is stripped of NULs and bidi controls before tokenizing (tested).
- Panics are contained and tested (`ReaderView.guard`, `panicForTest`).
- Input-only: the extension can't write to pages, the clipboard or files.
