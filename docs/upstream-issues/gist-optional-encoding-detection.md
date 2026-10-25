# GIST issue draft: optional encoding detection in gist-parse-txt

Status: **filed 2026-10-25** as
<https://github.com/BelongaGezza/gist/issues/132>. Once GIST adopts it, move
chromeGIST's `gist-parse-txt` dependency to `default-features = false`.

**Title:** gist-parse-txt: make legacy-encoding detection an optional Cargo feature (WASM size)

## Problem

Since #102 (M8, SC-01), `gist-parse-txt::parse()` always goes through
`parse_with_encoding(.., EncodingChoice::Auto)`, which links `chardetng` and
the `encoding_rs` legacy code-page tables. For consumers that only ever hold
text already in memory as a UTF-8 string, this code can never matter, but it
can't be compiled out.

Measured in chromeGIST (a Chrome extension that compiles `gist-model`,
`gist-parse-txt` and `gist-rsvp` to `wasm32-unknown-unknown`), moving the pin
from `0293fee` to `9be1700`:

| | `.wasm` size |
|---|---|
| `0293fee` | 125 KB |
| `9be1700` | 394 KB (348 KB with `codegen-units=1` and `strip`) |

About 200 KB of the module's data section is the encoding tables. The same
change makes every WASM load and parse slower for no benefit.

## Proposal

Add a default-on feature to `gist-parse-txt`:

```toml
[features]
default = ["encoding-detection"]
encoding-detection = ["dep:encoding_rs", "dep:chardetng"]

[dependencies]
encoding_rs = { version = "0.8", optional = true }
chardetng   = { version = "1.0", optional = true }
```

With the feature **off**:

- `parse()` and `parse_with_encoding()` decode as UTF-8 only: strip a UTF-8
  BOM, and return `Utf8` if the bytes are invalid.
- `EncodingChoice::Named(..)` returns `UnknownEncoding`.
- UTF-16 sniffing and `chardetng` are not compiled.

With the feature **on** (the default), behaviour is unchanged, so the Apple,
Windows, Linux and `gist-web` clients need no changes. Their dependency
declarations in `gist-core` and `fuzz` stay as they are.

The one thing to watch is that `ParseError::Utf8` is currently reachable only
from the old path. Keep it as the error for invalid UTF-8 when the feature is
off. Tests that need detection (`tests/encodings.rs`) get
`#![cfg(feature = "encoding-detection")]`.

## Consumer side

chromeGIST would then use
`gist-parse-txt = { git = ..., rev = ..., default-features = false }`. Cargo
unifies features across the graph, so this only takes effect if nothing else
in its dependency tree enables the default. That holds for chromeGIST, which
doesn't use `gist-core`.

## Alternatives considered

- **A separate `gist-detect-encoding` crate** is cleaner, but a larger
  refactor.
- **A `[patch]` override in chromeGIST** is a maintenance burden and was
  rejected.

## Acceptance

- `cargo build -p gist-parse-txt --no-default-features --target wasm32-unknown-unknown`
  succeeds and drops `encoding_rs` and `chardetng` from `cargo tree`.
- Existing tests pass with default features. A UTF-8-only subset of the tests
  passes with `--no-default-features`.

## To verify before filing

- The "Consumer side" claim about `gist-core` is from reading the Cargo
  files; no graph was built with `default-features = false`.
- The `ParseError::Utf8` note is a reading of the code; the implementer
  should confirm it.
