# chromeGIST — Privacy

**Status:** written 2026-10-01 and re-checked 2026-10-25 against GIST
`9be1700` (extension v0.1.0, unreleased). This
describes what the code in this repository does today, following the format
of GIST's `docs/PRIVACY.md`. Each claim cites the file that backs it, so it
can be re-verified. Re-check this document whenever `apps/chrome/`
(especially `manifest.json`, `background.js`, `handoff.js`, `reader.js`) or
`crates/chromegist-wasm` change, and whenever the GIST pin moves. It maps
onto the Chrome Web Store "privacy practices" form: **no user data
collected, no data sold or shared, no remote code.**

chromeGIST has no server, no accounts, no analytics, and no code that makes
network requests. Everything below happens in memory in your browser.

Claims fall into two kinds, and this document says which is which:

- **Enforced by Chrome**: the extension can't do it because the browser
  doesn't allow it (e.g. it has no permission to read page contents).
- **Absent from the code**: the extension doesn't do it because nobody wrote
  that code, checked by review and by `cargo deny`.

"No network" is now both: the code has none, and the manifest's
Content-Security-Policy (`default-src 'none'; connect-src 'self'`) tells
Chrome to block any request to another origin. The policy is checked in
headless tests as a meta-CSP; confirming it under Chrome's real extension
load is still on the manual checklist (`docs/SECURITY_REVIEW.md` finding #1).

## 1. What chromeGIST receives

Only the text you selected, and only when you choose **Speed Read with
chromeGIST** from the right-click menu. Chrome passes the selection to the
extension's service worker as `info.selectionText` (`apps/chrome/background.js`).

chromeGIST asks for one permission, **`contextMenus`**
(`apps/chrome/manifest.json`). It has no host permissions, no content
scripts, and no `activeTab`, `scripting`, `tabs`, `storage`, `history` or
`clipboard*` permission. Chrome enforces this: the extension **cannot** read
page contents, other tabs, your browsing history, form fields, or the
clipboard. It never learns the page's URL or title either; the only fields the code
reads from the `tab` Chrome supplies with the click are `tab.incognito` and
`tab.windowId`, used to open the reader in the matching window. The menu
item appears only when text is selected (`contexts: ["selection"]`).

The text you read is whatever Chrome supplies. Chrome may shorten very long
selections before the extension sees them (about 7,500 words observed), which
chromeGIST can't detect, so the reader ends every selection with a notice to
that effect. This affects completeness only, not privacy.

## 2. What chromeGIST stores

**Nothing on disk.** No code in `apps/chrome/` or `crates/chromegist-wasm/`
uses `chrome.storage`, `localStorage`, `sessionStorage`, IndexedDB, cookies,
the Cache API or files. There is no library, history, cache or settings
(your reading speed is not remembered either).

In memory, the selection lives in two places for a short time:

1. **The service worker** holds it from the click until the reader window
   claims it. It's kept under a random one-time id, deleted the moment it's
   claimed, and deleted after 60 seconds if nobody claims it
   (`apps/chrome/handoff.js`). If Chrome stops the idle service worker first,
   the text is simply gone (the reader then shows "This selection has
   expired").
2. **The reader window** (`reader.html`) holds the text and the word list
   made from it while the window is open. Closing the window ends that page.
   The reader doesn't keep a copy after tokenizing (`reader.js` drops its
   reference), and the page's address is rewritten to remove the handoff id
   as soon as it loads.

chromeGIST doesn't explicitly wipe that memory; see
`docs/SECURITY_REVIEW.md` finding #4 for why. The claim is "we never write it
anywhere", not "we scrub it from RAM".

## 3. What ever leaves your computer

**Nothing sent by chromeGIST.** The extension contains no `fetch`,
`XMLHttpRequest`, WebSocket, beacon or analytics call; its only `fetch` is
the WASM loader reading the extension's own `.wasm` file
(`apps/chrome/pkg/`). The Rust side has no networking crates, and
`deny.toml` bans `reqwest`, `hyper`, `ureq`, `tokio`, `openssl` and `rustls`
(`cargo deny --exclude-dev check`). All reading logic runs locally in
WebAssembly.

No remote code is loaded: scripts come from the extension package only
(`script-src 'self' 'wasm-unsafe-eval'`). Beyond that, the policy
`default-src 'none'; connect-src 'self'; img-src 'self'; style-src 'self'`
makes Chrome refuse requests to any other origin from extension pages
(including the service worker), so the no-network claim doesn't rest on code
review alone. Verified in headless Chrome with the policy applied as a
meta-CSP (`apps/chrome/tests/csp.html`); not yet observed under a real
extension load.

chromeGIST also never writes back to the page, the clipboard or the source
document.

## 4. Logging

chromeGIST doesn't log the selected text or anything derived from it. There
are two `console` calls. `console.error` in `apps/chrome/reader.js` logs a
start-up failure from loading the WASM, which doesn't involve the text.
`console.warn` in `apps/chrome/background.js` logs only the error message
when Chrome fails to open the reader window, never the selection. The Rust code has no
logging, and no panic hook is installed, so a panic message isn't written
anywhere.

## 5. What Chrome and your system may do

Outside chromeGIST's control, and true of any extension:

- **Other software sees your selection first.** The page, other extensions
  with access to that page, screen readers and the clipboard manager of your
  OS are all outside chromeGIST. Chrome itself builds `selectionText`.
- **Crash reports.** If the browser or renderer crashes while text is in
  memory, and you have enabled Chrome's usage-statistics and crash-report
  sharing, a crash report could contain some of that text. This is the one
  known path by which selected text could outlive the window. chromeGIST
  limits selections to 512 KiB, and a bug in the reading code surfaces as a
  contained error rather than a crash (`docs/SECURITY_REVIEW.md` finding #3),
  but it can't rule out every crash.
- **Operating-system swap** may write browser memory to disk; this is
  standard and, on current macOS, encrypted.
- **Incognito.** Extensions are off in Incognito unless you enable them. If
  you do, the manifest's `"incognito": "split"` makes Chrome run a separate
  instance of the extension inside incognito, and text selected in an
  incognito tab opens the reader as a tab in that incognito window
  (`background.js`; finding #2). The incognito instance has its own memory,
  and the handoff also records that the text came from incognito and releases
  it only to an incognito reader (finding F7). Verified in a real profile on
  2026-10-25: the incognito reader opens in the incognito window. The earlier
  `"spanning"` design was found to open the reader in a regular window, which
  would have put incognito text in a non-incognito window. Nothing is stored either way.
- **Chrome Sync.** chromeGIST syncs nothing; it has no data to sync.

## 6. Third-party code

The only third-party code is the Rust crates compiled into the WASM module
and `wasm-bindgen`'s generated glue, listed in `docs/THIRD-PARTY.md` and
`apps/chrome/THIRD_PARTY_NOTICES.txt`. They parse text and compute pacing;
none makes network requests or writes files in chromeGIST's use. Since GIST
`9be1700` they include `encoding_rs` and `chardetng` (text encoding
detection, linked by `gist-parse-txt`). chromeGIST's text is already a
JavaScript string, so `Reader` removes U+0000 and bidi control characters
before tokenizing to stop the detector misreading it. Dropping the detector
is tracked in GIST #132. The Rust
surface is `crates/chromegist-wasm/src/lib.rs`, a single `Reader` class with
no I/O. The GIST crates are pinned to a reviewed commit and hash-locked
(`Cargo.toml`, `Cargo.lock`, `UPSTREAM_BASELINE`).

## 7. Verifying these claims

```bash
grep -rnE "chrome\.storage|localStorage|sessionStorage|indexedDB|fetch\(|XMLHttpRequest|WebSocket|sendBeacon" apps/chrome --include=*.js --exclude-dir=pkg --exclude-dir=tests --exclude-dir=dev
cargo deny --exclude-dev check
grep -rnE "console\." apps/chrome --include=*.js --exclude-dir=pkg --exclude-dir=tests --exclude-dir=dev
```

The first command should list only comments in `handoff.js`; the third
should list only the two calls described in section 4. After
`tools/build-wasm.sh`, the same search over `apps/chrome/pkg/` should show
only the WASM loader's `fetch`.
