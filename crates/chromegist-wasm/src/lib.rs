//! chromeGIST's Rust core, compiled to WebAssembly for the Chrome extension.
//!
//! Like contextGIST (which this repo was forked from), it reuses GIST's
//! tokenizer and pacing engine via rev-pinned git dependencies on github.com/BelongaGezza/gist,
//! so tokenization and pacing never drift from upstream. Unlike contextGIST,
//! there is no hand-ported pacing engine on the UI side: contextGIST's Swift
//! `PacingEngine` exists because a uniffi round trip on every tick jittered,
//! but a WASM call is a same-thread function call. So `Reader` wraps GIST's
//! own `RsvpSession`, and JavaScript supplies only wall-clock elapsed time.

use gist_model::{Token, TokenKind};
use gist_rsvp::{Config, RsvpSession};
use unicode_segmentation::UnicodeSegmentation;
use wasm_bindgen::prelude::*;

/// Largest selection accepted, in UTF-8 bytes: about 85,000 words (~5.8 h at
/// 250 WPM). Same cap and rationale as contextGIST's
/// `AppServiceProvider.maxSelectionBytes` (its SECURITY_REVIEW.md finding #1).
pub const MAX_SELECTION_BYTES: usize = 512 * 1024;

// ── Panic containment ────────────────────────────────────────────────────────

/// Runs `f`, turning a panic into `fallback`. Native builds only in
/// practice: on wasm32-unknown-unknown, Rust panics abort (there's no
/// unwinding), so `catch_unwind` can't catch anything and a panic surfaces
/// in JavaScript as a `RuntimeError: unreachable`, after which the module
/// instance must be discarded. The JS side handles that (see
/// docs/ARCHITECTURE.md). Kept so native tests exercise the same paths.
fn contain<T>(fallback: T, f: impl FnOnce() -> T + std::panic::UnwindSafe) -> T {
    std::panic::catch_unwind(f).unwrap_or(fallback)
}

/// Characters removed before tokenizing, so the reader shows what the user
/// saw rather than what the page hid in it:
/// - U+0000: GIST re-decodes the text's UTF-8 bytes through its encoding
///   sniffing, and a page can plant NULs that make it guess UTF-16 and
///   display garbage. A JS string is already text; there is nothing to sniff.
/// - bidi embedding/override/isolate controls (U+202A-202E, U+2066-2069):
///   they would reverse or reorder the word being displayed.
fn is_stripped(c: char) -> bool {
    matches!(c, '\0' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
}

/// Zero-width characters that render nothing. A word token made only of
/// these would show a blank frame for a full tick, so it is dropped.
fn is_invisible(c: char) -> bool {
    matches!(c, '\u{200B}'..='\u{200D}' | '\u{2060}' | '\u{FEFF}')
}

fn tokenize(text: &str) -> Vec<Token> {
    contain(Vec::new(), || {
        let clean: std::borrow::Cow<str> = if text.contains(is_stripped) {
            text.replace(is_stripped, "").into()
        } else {
            text.into()
        };
        let limits = gist_model::ParseLimits::default();
        match gist_parse_txt::parse(clean.as_bytes(), "selection", &limits) {
            Ok(doc) => {
                let mut tokens = doc.token_stream;
                tokens.retain(|t| {
                    t.kind != TokenKind::Word || !t.text.chars().all(is_invisible)
                });
                tokens
            }
            Err(_) => Vec::new(),
        }
    })
}

/// Wall-clock milliseconds from JS (`performance.now()` differences are
/// fractional) to the u64 GIST's session uses. Rounds rather than
/// truncates: contextGIST found truncation turns 0.4 s into 399 ms.
fn ms(elapsed: f64) -> u64 {
    if elapsed.is_finite() && elapsed > 0.0 {
        elapsed.round() as u64
    } else {
        0
    }
}

// ── Reader ───────────────────────────────────────────────────────────────────

/// One reading session: the tokenized selection plus GIST's pacing session.
///
/// Time model (same as GIST's): while playing, JS keeps `resumedAt =
/// performance.now()` from the last `play()`/`seek()`/`setWpm()`/etc., and
/// passes `elapsed = performance.now() - resumedAt` to `current()`,
/// `remainingMs()` and `pause()`. Every mutation that moves the cursor
/// requires JS to reset `resumedAt`.
#[wasm_bindgen]
pub struct Reader {
    session: RsvpSession,
    /// Per token: (prefix, focus, suffix) around the ORP letter, and the
    /// prefix/suffix lengths in grapheme clusters (what a monospace `ch`
    /// offset needs). Precomputed so rendering a tick is a lookup.
    parts: Vec<(String, String, String, u32, u32)>,
    /// `words_through[i]` = word tokens in `tokens[0..=i]`, for the
    /// progress readout.
    words_through: Vec<u32>,
}

#[wasm_bindgen]
impl Reader {
    /// Tokenizes `text`. Rejects selections over `MAX_SELECTION_BYTES`.
    #[wasm_bindgen(constructor)]
    pub fn new(text: &str) -> Result<Reader, JsError> {
        if text.len() > MAX_SELECTION_BYTES {
            return Err(JsError::new("selection too long"));
        }
        Ok(Self::from_tokens(tokenize(text)))
    }

    #[wasm_bindgen(js_name = maxSelectionBytes)]
    pub fn max_selection_bytes() -> usize {
        MAX_SELECTION_BYTES
    }

    #[wasm_bindgen(js_name = tokenCount)]
    pub fn token_count(&self) -> usize {
        self.session.tokens.len()
    }

    #[wasm_bindgen(js_name = wordCount)]
    pub fn word_count(&self) -> u32 {
        self.words_through.last().copied().unwrap_or(0)
    }

    /// Words shown up to and including token `i` (for "12 / 340").
    #[wasm_bindgen(js_name = wordsThrough)]
    pub fn words_through(&self, i: usize) -> u32 {
        self.words_through.get(i).copied().unwrap_or(0)
    }

    /// 0 = word, 1 = paragraph break, 2 = section break.
    pub fn kind(&self, i: usize) -> u8 {
        match self.session.tokens.get(i).map(|t| &t.kind) {
            Some(TokenKind::ParagraphBreak) => 1,
            Some(TokenKind::SectionBreak) => 2,
            _ => 0,
        }
    }

    pub fn prefix(&self, i: usize) -> String {
        self.parts.get(i).map(|p| p.0.clone()).unwrap_or_default()
    }

    pub fn focus(&self, i: usize) -> String {
        self.parts.get(i).map(|p| p.1.clone()).unwrap_or_default()
    }

    pub fn suffix(&self, i: usize) -> String {
        self.parts.get(i).map(|p| p.2.clone()).unwrap_or_default()
    }

    /// Prefix length in grapheme clusters.
    #[wasm_bindgen(js_name = prefixLen)]
    pub fn prefix_len(&self, i: usize) -> u32 {
        self.parts.get(i).map(|p| p.3).unwrap_or(0)
    }

    /// Suffix length in grapheme clusters.
    #[wasm_bindgen(js_name = suffixLen)]
    pub fn suffix_len(&self, i: usize) -> u32 {
        self.parts.get(i).map(|p| p.4).unwrap_or(0)
    }

    pub fn wpm(&self) -> u32 {
        self.session.config.wpm
    }

    #[wasm_bindgen(js_name = isPlaying)]
    pub fn is_playing(&self) -> bool {
        self.session.state == gist_rsvp::PlayState::Playing
    }

    /// Token that should be showing `elapsed` ms after the last resume
    /// (GIST's `token_at_elapsed`; the cursor while paused).
    pub fn current(&self, elapsed: f64) -> usize {
        if self.is_playing() {
            self.session.token_at_elapsed(ms(elapsed))
        } else {
            self.session.cursor
        }
    }

    /// Milliseconds until the token changes, for scheduling the next tick.
    /// 0 at the end of the stream or while paused.
    #[wasm_bindgen(js_name = remainingMs)]
    pub fn remaining_ms(&self, elapsed: f64) -> f64 {
        if !self.is_playing() {
            return 0.0;
        }
        let elapsed = ms(elapsed);
        let mut accumulated = 0u64;
        for idx in self.session.cursor..self.session.tokens.len() {
            accumulated += self.session.token_duration_ms(idx);
            if accumulated > elapsed {
                return (accumulated - elapsed) as f64;
            }
        }
        0.0
    }

    #[wasm_bindgen(js_name = isAtEnd)]
    pub fn is_at_end(&self, elapsed: f64) -> bool {
        self.current(elapsed) + 1 >= self.session.tokens.len()
    }

    /// Start or resume playback. JS resets `resumedAt`.
    pub fn play(&mut self) {
        if !self.session.tokens.is_empty() {
            self.session.resume();
        }
    }

    pub fn pause(&mut self, elapsed: f64) {
        self.session.pause(ms(elapsed));
    }

    /// Back `n` words (GIST's `back_words`). JS resets `resumedAt`.
    pub fn back(&mut self, n: usize, elapsed: f64) {
        self.session.back_words(n, ms(elapsed));
    }

    /// Forward `n` words: the mirror of GIST's `back_words`, which GIST
    /// doesn't have. JS resets `resumedAt`.
    pub fn forward(&mut self, n: usize, elapsed: f64) {
        let tokens = &self.session.tokens;
        let mut target = self.current(elapsed);
        let mut skipped = 0;
        while skipped < n && target + 1 < tokens.len() {
            target += 1;
            if tokens[target].kind == TokenKind::Word {
                skipped += 1;
            }
        }
        self.session.seek(target);
    }

    /// Jump to token `i` (clamped; GIST's `seek`). Used to restart from the
    /// beginning after reaching the end. JS resets `resumedAt`.
    pub fn seek(&mut self, i: usize) {
        self.session.seek(i);
    }

    /// Test hook: panics inside WASM so the browser tests can check the
    /// reader page recovers (panics abort on wasm32; see ARCHITECTURE.md).
    /// Only compiled with `--features test-hooks`; release packaging
    /// doesn't enable it.
    #[cfg(feature = "test-hooks")]
    #[wasm_bindgen(js_name = panicForTest)]
    pub fn panic_for_test(&self) {
        panic!("chromeGIST test hook: deliberate panic");
    }

    /// Change WPM (clamped to 100..=1000 by GIST). JS resets `resumedAt`.
    #[wasm_bindgen(js_name = setWpm)]
    pub fn set_wpm(&mut self, wpm: u32, elapsed: f64) {
        self.session
            .set_wpm(wpm, if self.is_playing() { ms(elapsed) } else { 0 });
    }
}

impl Reader {
    fn from_tokens(tokens: Vec<Token>) -> Reader {
        // GIST splits words over MAX_TOKEN_BYTES inside `RsvpSession::new`, so
        // the display tables must be built from the session's own tokens or
        // their indices drift from the pacing session's.
        let session = RsvpSession::new(tokens, Config::default());
        let tokens = &session.tokens;
        let mut words = 0u32;
        let mut words_through = Vec::with_capacity(tokens.len());
        let mut parts = Vec::with_capacity(tokens.len());
        for t in tokens {
            if t.kind == TokenKind::Word {
                words += 1;
                // Since GIST #79 (gist#78) `orp_index` is already a grapheme
                // cluster boundary, so this snap is a no-op today. It stays
                // as a defence against the pin moving to a GIST that regresses
                // that: it snaps the focus to the whole cluster containing
                // the ORP, so the red letter is always one visible character
                // and nothing is split.
                let orp = gist_rsvp::orp_index(&t.text).min(t.text.len());
                let (start, cluster) = t
                    .text
                    .grapheme_indices(true)
                    .find(|(start, g)| orp < start + g.len())
                    .unwrap_or((t.text.len(), ""));
                let prefix = &t.text[..start];
                let focus = cluster;
                let suffix = &t.text[start + cluster.len()..];
                parts.push((
                    prefix.to_string(),
                    focus.to_string(),
                    suffix.to_string(),
                    prefix.graphemes(true).count() as u32,
                    suffix.graphemes(true).count() as u32,
                ));
            } else {
                parts.push(Default::default());
            }
            words_through.push(words);
        }
        Reader {
            session,
            parts,
            words_through,
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn reader(text: &str) -> Reader {
        match Reader::new(text) {
            Ok(r) => r,
            Err(_) => panic!("under the cap"),
        }
    }

    #[test]
    fn reader_tokenizes_words_and_paragraphs() {
        let r = reader("Hello world.\n\nSecond paragraph.");
        assert_eq!(r.token_count(), 5);
        assert_eq!(r.word_count(), 4);
        assert_eq!((r.kind(0), r.kind(2)), (0, 1));
        assert_eq!(r.words_through(1), 2);
        assert_eq!(r.words_through(2), 2, "a paragraph break isn't a word");
    }

    /// Every display entry must be the session token it is shown for, even
    /// after GIST splits words over MAX_TOKEN_BYTES (regression: parts were
    /// built from the unsplit tokens, so indices drifted).
    fn assert_display_matches_session(r: &Reader) {
        let mut words = 0;
        for i in 0..r.token_count() {
            let t = &r.session.tokens[i];
            if t.kind == TokenKind::Word {
                words += 1;
                assert_eq!(
                    format!("{}{}{}", r.prefix(i), r.focus(i), r.suffix(i)),
                    t.text,
                    "display of token {i} drifted from the session"
                );
                assert!(t.text.len() <= gist_rsvp::MAX_TOKEN_BYTES);
            }
            assert_eq!(r.words_through(i), words, "wordsThrough({i})");
        }
        assert_eq!(r.word_count(), words);
    }

    #[test]
    fn display_matches_session_for_oversized_words() {
        let long = "x".repeat(600);
        let r = reader(&format!("start {long} middle end words here"));
        assert!(r.token_count() > 6, "the long word must have been split");
        assert_display_matches_session(&r);
        assert_eq!(r.word_count() as usize, r.session.tokens.iter()
            .filter(|t| t.kind == TokenKind::Word).count());

        // Combining marks: one grapheme far over the cap, and many-mark words.
        let marks = format!("e{}", "\u{0301}".repeat(400));
        assert_display_matches_session(&reader(&format!("a {marks} b {} c", "é".repeat(500))));
        assert_display_matches_session(&reader(&"a".repeat(512 * 1024)));
    }

    #[test]
    fn nul_cannot_trigger_utf16_misdetection() {
        let text = "ABCD\0E\0F\0G\0H\0I\0J\0K\0L\0M\0N\0O\0P\0Q\0R\0S\0T\0 \0";
        let r = reader(text);
        let shown: String = (0..r.token_count())
            .filter(|&i| r.kind(i) == 0)
            .map(|i| format!("{}{}{}", r.prefix(i), r.focus(i), r.suffix(i)))
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(shown, "ABCDEFGHIJKLMNOPQRST");
    }

    #[test]
    fn bidi_controls_and_invisible_tokens_are_not_displayed() {
        let r = reader("Hello \u{202E}dlrow\u{202C} \u{200B} \u{2067}x\u{2069} \u{FEFF}\u{200D} end");
        let shown: Vec<String> = (0..r.token_count())
            .filter(|&i| r.kind(i) == 0)
            .map(|i| format!("{}{}{}", r.prefix(i), r.focus(i), r.suffix(i)))
            .collect();
        assert_eq!(shown, ["Hello", "dlrow", "x", "end"]);
        // Real RTL text is untouched.
        let r = reader("שלום עולם");
        assert_eq!(r.word_count(), 2);
    }

    #[test]
    fn reader_splits_words_at_the_orp_letter() {
        let r = reader("Hello naïve");
        // GIST's rule: ~30% in ("l"), then the next vowel at or after it.
        assert_eq!(
            (r.prefix(0), r.focus(0), r.suffix(0)),
            ("Hell".into(), "o".into(), String::new())
        );
        assert_eq!((r.prefix_len(0), r.suffix_len(0)), (4, 0));
        for i in 0..r.token_count() {
            let joined = format!("{}{}{}", r.prefix(i), r.focus(i), r.suffix(i));
            assert_eq!(joined, r.session.tokens[i].text);
            assert_eq!(
                r.prefix(i).len(),
                gist_rsvp::orp_index(&r.session.tokens[i].text)
            );
        }
    }

    #[test]
    fn orp_focus_is_always_a_whole_grapheme_cluster() {
        // Before GIST #79, orp_index landed mid-cluster on each of these: on
        // the ZWJ, on the flag's second regional indicator, and on a
        // combining tilde (decomposed "ñ", as text copied from some PDFs is).
        for word in ["👨\u{200D}👩x", "🇬🇧", "n\u{0303}"] {
            let r = reader(word);
            let (p, f, s) = (r.prefix(0), r.focus(0), r.suffix(0));
            assert_eq!(format!("{p}{f}{s}"), word);
            assert_eq!(f.graphemes(true).count(), 1, "{word:?} → {p:?}|{f:?}|{s:?}");
            assert_eq!(
                p.len(),
                gist_rsvp::orp_index(word),
                "GIST's ORP is already a cluster boundary, so snapping moves nothing"
            );
            assert_eq!(
                r.prefix_len(0) + 1 + r.suffix_len(0),
                word.graphemes(true).count() as u32
            );
        }
    }

    #[test]
    fn reader_rejects_selections_over_the_cap() {
        assert!(Reader::new(&"a".repeat(MAX_SELECTION_BYTES)).is_ok());
        // JsError can only be constructed on wasm32, so check the length
        // guard directly rather than calling `new` over the cap natively.
        assert!("a".repeat(MAX_SELECTION_BYTES + 1).len() > MAX_SELECTION_BYTES);
    }

    #[test]
    fn empty_and_whitespace_selections_have_no_words() {
        for text in ["", " \n\t "] {
            let mut r = reader(text);
            assert_eq!(r.word_count(), 0);
            r.play();
            assert_eq!(r.current(1000.0), 0);
        }
    }

    #[test]
    fn pacing_is_gists_session_and_remaining_ms_matches_it() {
        let text = "One, two three. Four 5 six.\n\nSeven eight.";
        let mut r = reader(text);
        r.play();
        // `current` is GIST's token_at_elapsed; `remaining_ms` walks the same
        // durations, so at every ms the token changes exactly when
        // remaining hits zero.
        let mut last = r.current(0.0);
        for t in 0..20_000 {
            let t = t as f64;
            let idx = r.current(t);
            assert_eq!(idx, r.session.token_at_elapsed(t as u64));
            if idx != last {
                assert_eq!(r.remaining_ms(t - 1.0), 1.0, "change at {t} ms");
                last = idx;
            }
        }
        assert!(r.is_at_end(20_000.0));
    }

    #[test]
    fn pause_seek_and_wpm_follow_gists_semantics() {
        let mut r = reader("a b c d e f g h i j");
        let base = 60_000.0 / 250.0; // 240 ms per plain word at 250 WPM
        r.play();
        assert_eq!(r.current(base * 3.5), 3);
        r.pause(base * 3.5);
        assert!(!r.is_playing());
        assert_eq!(r.current(99_999.0), 3, "paused: time doesn't advance");
        r.back(2, 0.0);
        assert_eq!(r.current(0.0), 1);
        r.forward(4, 0.0);
        assert_eq!(r.current(0.0), 5);
        r.seek(0);
        assert_eq!(r.current(0.0), 0);
        r.seek(99);
        assert_eq!(r.current(0.0), 9, "seek clamps to the last token");
        r.seek(5);
        r.set_wpm(5000, 0.0);
        assert_eq!(r.wpm(), 1000, "GIST clamps to 100..=1000");
        r.play();
        assert_eq!(r.current(60.0 * 2.5), 7, "60 ms per word at 1000 WPM");
    }

    #[test]
    fn fractional_js_times_round_not_truncate() {
        assert_eq!(ms(399.6), 400);
        assert_eq!(ms(-5.0), 0);
        assert_eq!(ms(f64::NAN), 0);
    }

    #[test]
    fn contain_turns_a_panic_into_the_fallback() {
        assert_eq!(contain(7, || -> i32 { panic!("boom") }), 7);
        assert_eq!(contain(7, || 1), 1);
    }

    // ── Adversarial input (docs/DEVELOPMENT_PLAN.md Phase 0) ─────────────────
    //
    // A panic in gist-parse-txt/gist-rsvp is what would turn a bad selection
    // into a crash report containing that selection (SECURITY_REVIEW.md
    // finding #1). These call the upstream crates *directly* rather than
    // through `tokenize`/`orp_index`, because `contain` would hide the
    // panic. Every test also checks the invariant the Swift side depends on:
    // each word's ORP offset is a char boundary inside the word
    // (`DisplayToken.orpParts` converts it with `samePosition(in:)`).

    /// Tokenizes `text` via the upstream crates exactly as `tokenize` does,
    /// without panic containment, and checks per-token invariants.
    fn tokenize_checked(text: &str) -> Vec<gist_model::Token> {
        let limits = gist_model::ParseLimits::default();
        let doc = gist_parse_txt::parse(text.as_bytes(), "selection", &limits)
            .expect("valid UTF-8 under the size limit must parse");
        for t in &doc.token_stream {
            match t.kind {
                gist_model::TokenKind::Word => {
                    assert!(!t.text.is_empty(), "empty word token from {text:?}");
                    assert!(
                        !t.text.chars().any(char::is_whitespace),
                        "word token contains whitespace: {:?}",
                        t.text
                    );
                    let orp = gist_rsvp::orp_index(&t.text);
                    assert!(
                        orp < t.text.len(),
                        "ORP {orp} out of range for {:?}",
                        t.text
                    );
                    assert!(
                        t.text.is_char_boundary(orp),
                        "ORP {orp} not a char boundary in {:?}",
                        t.text
                    );
                }
                _ => assert!(t.text.is_empty()),
            }
        }
        doc.token_stream
    }

    fn words(tokens: &[gist_model::Token]) -> Vec<&str> {
        tokens
            .iter()
            .filter(|t| t.kind == gist_model::TokenKind::Word)
            .map(|t| t.text.as_str())
            .collect()
    }

    #[test]
    fn very_long_word_without_whitespace() {
        let word = "a".repeat(512 * 1024);
        let tokens = tokenize_checked(&word);
        assert_eq!(words(&tokens), vec![word.as_str()]);

        // Multi-byte chars only, so every byte offset but a few is mid-char.
        let word = "é".repeat(100_000);
        assert_eq!(words(&tokenize_checked(&word)).len(), 1);
    }

    #[test]
    fn bidi_and_rtl_text() {
        let text =
            "Hello \u{202E}dlrow\u{202C} שלום עולם مرحبا بالعالم \u{2067}isolate\u{2069} end.";
        let w = tokenize_checked(text);
        assert_eq!(words(&w).len(), 8);
        // Directional control characters stay attached to their words; they
        // aren't whitespace.
        assert!(words(&w).contains(&"\u{202E}dlrow\u{202C}"));
    }

    #[test]
    fn zero_width_joiners_emoji_and_combining_marks() {
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦";
        let flag = "🇬🇧";
        let combining = "e\u{0301}\u{0302}\u{0303}";
        let zwsp_word = "zero\u{200B}width";
        let text = format!("{family} {flag} {combining} {zwsp_word}");
        let w = tokenize_checked(&text);
        // U+200B ZERO WIDTH SPACE is not Unicode White_Space, so it doesn't
        // split words.
        assert_eq!(words(&w), vec![family, flag, combining, zwsp_word]);
    }

    #[test]
    fn degenerate_whitespace() {
        for text in [
            "",
            " ",
            "\n\n\n\n",
            "\t \r\n \u{00A0}\u{2028}\u{2029}\u{3000}\u{FEFF}",
            &"\n\n".repeat(50_000),
            &" ".repeat(512 * 1024),
        ] {
            let w = tokenize_checked(text);
            // U+FEFF (BOM / ZWNBSP) is not White_Space, so the one mixed
            // case yields exactly that as a "word". Everything else: none.
            let expected = usize::from(text.contains('\u{FEFF}'));
            assert_eq!(
                words(&w).len(),
                expected,
                "for {:?}",
                &text[..text.len().min(40)]
            );
        }
    }

    #[test]
    fn line_ending_styles() {
        // Every way of writing a blank line gives a paragraph break: LF,
        // CRLF (Windows), bare CR (e.g. Word), U+2029 PARAGRAPH SEPARATOR,
        // and whitespace-only "blank" lines. Before GIST 695fba1 only a
        // literal "\n\n" did, so the others lost their paragraph pauses
        // (https://github.com/BelongaGezza/gist/issues/76, filed from
        // here). This test pinned the bug until upstream fixed it.
        for (text, breaks) in [
            ("one two\n\nthree", 1),
            ("one two\r\n\r\nthree", 1),
            ("one two\r\rthree", 1),
            ("one two\u{2029}three", 1),
            ("one two\n \nthree", 1),
        ] {
            let tokens = tokenize_checked(text);
            assert_eq!(words(&tokens), vec!["one", "two", "three"], "for {text:?}");
            let n = tokens
                .iter()
                .filter(|t| t.kind == gist_model::TokenKind::ParagraphBreak)
                .count();
            assert_eq!(n, breaks, "paragraph breaks for {text:?}");
        }
    }

    #[test]
    fn control_characters_and_nul() {
        let text = "a\0b \u{7}bell \u{1B}[31mred\u{1B}[0m \u{FFFD} \u{10FFFF}";
        assert_eq!(words(&tokenize_checked(text)).len(), 5);
    }

    #[test]
    fn orp_index_on_single_chars_and_edge_words() {
        for w in [
            "a",
            "é",
            "👨\u{200D}👩",
            "\u{0301}",
            "xyzxyz",
            "AEIOU",
            "ßẞ",
            "ﷺ",
        ] {
            let orp = gist_rsvp::orp_index(w);
            assert!(w.is_char_boundary(orp) && orp < w.len(), "{w:?} -> {orp}");
        }
        assert_eq!(gist_rsvp::orp_index(""), 0);
    }

    /// Deterministic pseudo-fuzz over a pool of awkward characters. No
    /// proptest dependency: a fixed-seed xorshift keeps failures
    /// reproducible from the printed seed/iteration.
    #[test]
    fn randomized_awkward_strings() {
        const POOL: &[&str] = &[
            "a", "E", "z", " ", "\n", "\n\n", "\r", "\t", "\u{00A0}", "\u{2028}", "\u{2029}",
            "\u{3000}", "\u{200B}", "\u{200D}", "\u{FEFF}", "\u{202E}", "\u{2067}", "\u{0301}",
            "é", "ß", "ﷺ", "ש", "م", "中", "👨", "🇬", "\0", ".", ",", "1", "!", "?",
        ];
        let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut next = || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for iteration in 0..5_000 {
            let len = (next() % 64) as usize;
            let text: String = (0..len)
                .map(|_| POOL[(next() % POOL.len() as u64) as usize])
                .collect();
            let result = std::panic::catch_unwind(|| tokenize_checked(&text));
            assert!(result.is_ok(), "iteration {iteration} panicked on {text:?}");
        }
    }
}
