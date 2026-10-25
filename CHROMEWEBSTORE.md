# CHROMEWEBSTORE.md — Chrome Web Store submission notes

**Status:** draft, drafted 2026-10-25 for extension v0.1.0 (unreleased). Not
submitted; no developer account yet (`docs/DEVELOPMENT_PLAN.md` Phase 3).

This file holds the answers the Chrome Web Store dashboard asks for, so they
are written once and kept in step with the code. It is derived from
`apps/chrome/manifest.json`, `docs/PRIVACY.md` and `docs/SECURITY_REVIEW.md`;
those remain the source of truth, and each claim here should be re-checked
against them before submission.

**Update this file whenever** the manifest, permissions, CSP, messaging or
storage change, when the GIST pin changes behaviour users can see, or when a
submission is rejected (record the reason and the fix under "Review history").

## Listing

- **Name:** chromeGIST
- **Short description** (manifest `description`, 132 characters max):
  "Speed-read selected text, one word at a time. Nothing is stored or sent anywhere."
- **Category:** Productivity (alternative: Accessibility; decide at submission).
- **Detailed description (draft):**

  > Select text on any web page, right-click, and choose **Speed Read with
  > chromeGIST**. A small window shows the text one word at a time at a pace
  > you control, with a focus letter to anchor your eye. Play, pause, rewind,
  > fast-forward and change speed from the window or the keyboard.
  >
  > Private by design: chromeGIST reads only the text you select, only when
  > you ask. It has no accounts, no analytics and no network access, and it
  > stores nothing. When you close the window, the text is gone.
  >
  > Very long selections may be shortened by Chrome before chromeGIST sees
  > them (about 7,500 words), so the reader reminds you of that at the
  > end of a selection.

- **Screenshots / promo images:** not made yet. Take them from the reader
  window (light and dark).
- **Icon:** `apps/chrome/icons/icon128.png` (GIST artwork; see
  `tools/gen-icons.sh`).

## Single purpose

> Display text the user has selected on a web page as a paced, one-word-at-a-time
> speed reader in a separate window.

## Permission justification

| Permission | Justification (paste into the dashboard) |
|---|---|
| `contextMenus` | "Adds the single right-click menu item, shown only when text is selected, that opens the selected text in the reader window. It is the extension's only entry point." |

That is the only permission. There are **no host permissions, no content
scripts, and no `activeTab`, `scripting`, `tabs`, `storage`, `history` or
`clipboard*`** permissions. Chrome therefore does not let the extension read
page contents, other tabs, history or the clipboard. The selection arrives
only as `info.selectionText` in the context-menu click event.

Other manifest points a reviewer may ask about:

- **`wasm-unsafe-eval` in the CSP** (`script-src 'self' 'wasm-unsafe-eval'`):
  required to instantiate the extension's own bundled WebAssembly module (the
  Rust reading engine). It does not allow `eval()` or string-to-code. No
  remote code is loaded.
- **`incognito: "split"`:** the extension runs in Incognito only if the
  user enables it in Chrome. Chrome then runs a separate instance inside
  incognito, and text selected in an incognito tab opens the reader as a tab
  in that incognito window. Nothing is stored either way. (`"spanning"` was
  tried and Chrome opened the reader in a regular window.) Verified in real
  Chrome 2026-10-25; re-check at submission.
- **`minimum_chrome_version: "120"`.**

Full CSP, for reference:

```
default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'none'
```

## Privacy practices tab

- **Does the extension collect or use user data?** The extension handles the
  text the user selects, only in memory and only on the user's action, and
  does not collect, store or transmit it. Answer each data-type checkbox as
  **not collected**. *Confirm the dashboard's wording at submission;
  "website content" is the category the selection falls under.*
- **Data sold or transferred to third parties:** no.
- **Data used for purposes unrelated to the single purpose, or for
  creditworthiness/lending:** no.
- **Remote code:** no. All scripts and the `.wasm` are in the package.
- **Privacy policy URL:** needed. The public page is `docs/site/privacy.html`
  (plain-language, self-contained, no external resources), written from
  `docs/PRIVACY.md`. It must be hosted at a public URL (for example GitHub
  Pages from this repo once it is public). **Open items:** host it, and re-check it against
  `docs/PRIVACY.md` whenever that changes. Its contact is the repo's GitHub
  issues page and its publisher is BelongaGezza; change both if the listing
  differs.

Claims this rests on, and where they are verified:

| Claim | Backing |
|---|---|
| No network | No `fetch`/XHR/WebSocket/beacon in the code except the WASM loader; CSP `connect-src 'self'`; `deny.toml` bans networking crates. `docs/PRIVACY.md` §3 |
| Nothing stored | No storage API or files used. `docs/PRIVACY.md` §2 |
| One permission | `apps/chrome/manifest.json` |
| No logging of text | `docs/PRIVACY.md` §4 |
| CSP enforced by Chrome | Verified in a real Chrome profile 2026-10-01 (`docs/SECURITY_REVIEW.md` finding #1) |

Known limits, stated honestly in the privacy text: memory is not explicitly
zeroed (finding #4); a browser crash with crash-report sharing enabled could
include selected text in the report (`docs/PRIVACY.md` §5).

## Instructions for reviewers (test notes)

1. Open any page with text, for example a news article.
2. Select a few sentences, right-click, choose **Speed Read with chromeGIST**.
3. A window opens showing the words one at a time. Use play/pause, rewind,
   fast-forward and the speed control.
4. No sign-in, account or test credentials are needed.

## Package

- Built by `tools/package-extension.sh` into `dist/chromegist-<version>.zip`
  with a `BUILD_INFO` file. It ships an explicit allow-list (so `tests/` and
  `dev/` cannot ship), includes `THIRD_PARTY_NOTICES.txt`, and builds without
  the `test-hooks` feature (`docs/SECURITY_REVIEW.md` finding #5).
- Current `.wasm` size: about 328-348 KB (`docs/ARCHITECTURE.md`, "WASM size").

## Open items before submission

- [ ] Developer account (one-off fee) and publisher identity.
- [ ] Host `docs/site/privacy.html` and paste its URL.
- [ ] Screenshots and optional promo tile.
- [ ] The pre-submission manual checklist
  (`docs/DEVELOPMENT_PLAN.md` Phase 3).
- [ ] Re-check every claim above against `docs/PRIVACY.md` and the manifest
  at submission time.
- [ ] Accessibility pass (screen reader labels, reduced motion) so the
  listing can say what it supports.
- [ ] Edge Add-ons listing reuses most of this (Phase 4).

## Review history

None yet.
