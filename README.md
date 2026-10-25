# chromeGIST

A Chrome extension that speed-reads the text you've selected on a web
page. Select text, right-click, choose **Speed Read with chromeGIST**, and a
small popup window shows it RSVP-style ("rapid serial visual
presentation"): one word at a time, paced, with play/pause, rewind,
fast-forward and speed controls. Close the window and the text is gone. No
library, no history, no account, no network access.

chromeGIST is a fork of [contextGIST](https://github.com/BelongaGezza/contextGIST) (the same idea as a
macOS Services-menu item), and like it reuses [GIST](https://github.com/BelongaGezza/gist)'s
tokenizer and RSVP pacing engine unchanged, compiled to WebAssembly. See
[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) for the design and
[`CLAUDE.md`](./CLAUDE.md) for build and test commands.

## Status

Pre-release (v0.1.0), not yet on the Chrome Web Store. The extension works
when loaded unpacked (`tools/build-wasm.sh`, then `chrome://extensions` →
Developer mode → Load unpacked → `apps/chrome`). See
[`docs/DEVELOPMENT_PLAN.md`](./docs/DEVELOPMENT_PLAN.md).

## Requirements

- Network access on the first build: the Rust core depends on GIST's crates
  as git dependencies pinned by commit on GitHub (no local GIST checkout).
- Rust (pinned by `rust-toolchain.toml`; rustup installs the wasm32 target).
- `wasm-bindgen-cli` at the version in `Cargo.lock` (see
  `tools/build-wasm.sh`).
- Google Chrome, for the browser tests.

## Licence

MIT. Third-party notices: [`docs/THIRD-PARTY.md`](./docs/THIRD-PARTY.md).
