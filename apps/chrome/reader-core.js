// The reader: word display, controls and playback, independent of extension
// APIs so it can be tested on a plain page (tests/reader-core.html).
//
// Pacing is GIST's own session inside the WASM `Reader`; this file only
// supplies wall-clock time (docs/ARCHITECTURE.md, "Time model"): while
// playing, `resumedAt` is the performance.now() of the last play/seek/wpm
// change, and every Reader call gets `elapsed = now - resumedAt`.

const SKIP_WORDS = 5;

// Shown when playback reaches the end. Chrome may shorten very long
// selections before the extension sees them (observed 2026-10-01), and the
// extension can't tell, so this is a standing caution, not a detection.
const END_NOTE = "End of selection. Chrome may shorten very long selections, so if you selected a lot of text, some may not have been shown.";

export class ReaderView {
  reader = null;
  crashed = false;
  #root;
  #onClose;
  #resumedAt = 0;
  #timer = null;
  #els = {};
  #onKey = (e) => this.#handleKey(e);

  constructor(root, { onClose = () => {} } = {}) {
    this.#root = root;
    this.#onClose = onClose;
    this.#build();
    document.addEventListener("keydown", this.#onKey);
  }

  // ── States ───────────────────────────────────────────────────────────────

  showLoading() {
    this.#setMessage("");
    this.#els.stage.dataset.state = "loading";
    this.#setControlsEnabled(false);
  }

  showMessage(text) {
    this.#stop();
    this.#setNote(false);
    this.#els.stage.dataset.state = "message";
    this.#setMessage(text);
    this.#setControlsEnabled(false);
  }

  /** Tokenizes `text` with `ReaderClass` (the WASM Reader) and starts playing. */
  load(ReaderClass, text) {
    let reader;
    try {
      reader = new ReaderClass(text);
    } catch (e) {
      if (e instanceof WebAssembly.RuntimeError) return this.#crash();
      if (e && e.message === "selection too long") {
        const kib = Math.round(ReaderClass.maxSelectionBytes() / 1024);
        return this.showMessage(
          `This selection is too long to speed-read. chromeGIST reads up to ${kib} KB of text (about 85,000 words). Select a shorter passage and try again.`,
        );
      }
      throw e;
    }
    this.reader = reader;
    if (this.guard(() => reader.wordCount()) === 0) {
      return this.showMessage("No words to read in this selection.");
    }
    this.#els.stage.dataset.state = "reading";
    this.#setMessage("");
    this.#setControlsEnabled(true);
    this.#render();
    this.play();
  }

  /**
   * Runs a Reader call. Rust panics abort in WASM and surface as
   * WebAssembly.RuntimeError; after one, the module instance is unusable,
   * so drop it and show an error rather than freezing (ARCHITECTURE.md,
   * "Panics abort in WASM").
   */
  guard(fn) {
    if (this.crashed || !this.reader) return undefined;
    try {
      return fn();
    } catch (e) {
      if (e instanceof WebAssembly.RuntimeError) {
        this.#crash();
        return undefined;
      }
      throw e;
    }
  }

  // ── Playback ─────────────────────────────────────────────────────────────

  get playing() {
    return !!this.guard(() => this.reader.isPlaying());
  }

  play() {
    if (this.playing) return;
    this.#setNote(false);
    if (this.guard(() => this.reader.isAtEnd(0))) this.guard(() => this.reader.seek(0));
    this.guard(() => this.reader.play());
    this.#resumedAt = performance.now();
    this.#tick();
  }

  pause() {
    if (!this.playing) return;
    const elapsed = this.#elapsed();
    this.guard(() => this.reader.pause(elapsed));
    this.#stop();
    this.#render();
  }

  togglePlay() {
    this.playing ? this.pause() : this.play();
  }

  back(n = SKIP_WORDS) {
    this.#reposition(() => this.reader.back(n, this.#elapsed()));
  }

  forward(n = SKIP_WORDS) {
    this.#reposition(() => this.reader.forward(n, this.#elapsed()));
  }

  setWpm(wpm) {
    this.#reposition(() => this.reader.setWpm(wpm, this.#elapsed()));
  }

  /** What the view is showing, for tests and debugging. */
  state() {
    const index = this.guard(() => this.reader.current(this.#elapsed()));
    return {
      state: this.#els.stage.dataset.state,
      message: this.#els.message.textContent,
      note: this.#els.note.textContent,
      crashed: this.crashed,
      playing: this.playing,
      index,
      word: this.#els.prefix.textContent + this.#els.focus.textContent + this.#els.suffix.textContent,
      focus: this.#els.focus.textContent,
      offset: this.#els.word.style.getPropertyValue("--orp-offset"),
      progress: this.#els.progress.textContent,
      wpm: this.guard(() => this.reader.wpm()),
    };
  }

  destroy() {
    this.#stop();
    document.removeEventListener("keydown", this.#onKey);
    this.reader = null;
    this.#root.replaceChildren();
  }

  // ── Internals ────────────────────────────────────────────────────────────

  #elapsed() {
    return this.playing ? performance.now() - this.#resumedAt : 0;
  }

  // back/forward/setWpm all move GIST's cursor to "now" and require the
  // clock to restart from there.
  #reposition(mutate) {
    this.#setNote(false);
    const wasPlaying = this.playing;
    this.guard(mutate);
    if (this.crashed) return;
    this.#resumedAt = performance.now();
    this.#render();
    if (wasPlaying) this.#tick();
  }

  #tick() {
    this.#stop();
    this.#render();
    if (!this.playing || this.crashed) return;
    const elapsed = this.#elapsed();
    if (this.guard(() => this.reader.isAtEnd(elapsed))) {
      // The last word stays on screen; playback stops.
      this.guard(() => this.reader.pause(elapsed));
      this.#render();
      this.#setNote(true);
      return;
    }
    const wait = this.guard(() => this.reader.remainingMs(elapsed));
    if (wait === undefined) return;
    this.#timer = setTimeout(() => this.#tick(), Math.max(wait, 1));
  }

  #stop() {
    clearTimeout(this.#timer);
    this.#timer = null;
  }

  #crash() {
    this.#stop();
    this.#setNote(false);
    this.crashed = true;
    this.reader = null; // the WASM instance is unusable after a panic
    this.#els.stage.dataset.state = "message";
    this.#setMessage("Something went wrong reading this selection. Close this window and try again.");
    this.#setControlsEnabled(false);
  }

  #render() {
    const e = this.#els;
    const playing = this.playing;
    e.play.textContent = playing ? "⏸" : "▶";
    e.play.setAttribute("aria-label", playing ? "Pause" : "Play");
    if (!this.reader) return;
    const i = this.guard(() => this.reader.current(this.#elapsed()));
    if (i === undefined) return;
    const r = this.reader;
    const parts = this.guard(() => [r.prefix(i), r.focus(i), r.suffix(i), r.prefixLen(i), r.suffixLen(i)]);
    if (!parts) return;
    const [prefix, focus, suffix, prefixLen, suffixLen] = parts;
    e.prefix.textContent = prefix;
    e.focus.textContent = focus;
    e.suffix.textContent = suffix;
    // contextGIST's reticle offset, in monospace character widths: shifting
    // by (suffix - prefix) / 2 characters keeps the focus letter's centre
    // fixed. Computed from counts, not measured, so it can't lag a frame.
    e.word.style.setProperty("--orp-offset", String((suffixLen - prefixLen) / 2));
    e.word.setAttribute("aria-label", prefix + focus + suffix);
    const total = this.guard(() => r.wordCount());
    const shown = this.guard(() => r.wordsThrough(i));
    e.progress.textContent = `${shown} / ${total}`;
    e.progress.setAttribute("aria-label", `Word ${shown} of ${total}`);
    const wpm = this.guard(() => r.wpm());
    e.wpmLabel.textContent = `${wpm} WPM`;
    if (Number(e.wpm.value) !== wpm) e.wpm.value = String(wpm);
    e.wpm.setAttribute("aria-valuetext", `${wpm} words per minute`);
  }

  #setMessage(text) {
    this.#els.message.textContent = text;
  }

  #setNote(visible) {
    this.#els.note.textContent = visible ? END_NOTE : "";
  }

  #setControlsEnabled(enabled) {
    for (const el of [this.#els.back, this.#els.play, this.#els.forward, this.#els.wpm]) el.disabled = !enabled;
  }

  #handleKey(e) {
    if (e.key === "Escape") return this.#onClose();
    if (e.target instanceof HTMLInputElement && e.target.type === "range" && e.key.startsWith("Arrow")) return;
    if (!this.reader || this.crashed) return;
    // A focused button activates itself on Space; handling it here too would
    // toggle twice (keydown here, click on keyup).
    if (e.key === " " && e.target instanceof HTMLButtonElement) return;
    if (e.key === " ") this.togglePlay();
    else if (e.key === "ArrowLeft") this.back();
    else if (e.key === "ArrowRight") this.forward();
    else return;
    e.preventDefault();
  }

  #build() {
    const h = (tag, props = {}, ...children) => {
      const el = Object.assign(document.createElement(tag), props);
      el.append(...children);
      return el;
    };
    const e = this.#els;
    e.prefix = h("span", { className: "prefix" });
    e.focus = h("span", { className: "focus" });
    e.suffix = h("span", { className: "suffix" });
    e.word = h("div", { className: "word", role: "img" }, e.prefix, e.focus, e.suffix);
    e.word.setAttribute("aria-live", "off");
    e.progress = h("div", { className: "progress" });
    e.message = h("p", { className: "message", role: "status" });
    e.note = h("p", { className: "note", role: "status" });
    const spinner = h("div", { className: "spinner", role: "status" });
    spinner.setAttribute("aria-label", "Preparing text");
    const reticle = h("div", { className: "reticle", textContent: "▾" });
    reticle.setAttribute("aria-hidden", "true");
    e.stage = h("div", { className: "stage" }, reticle, e.word, spinner, e.message, e.progress, e.note);
    const button = (label, text, onclick) => {
      const b = h("button", { type: "button", textContent: text, onclick, title: label });
      b.setAttribute("aria-label", label);
      return b;
    };
    e.back = button(`Back ${SKIP_WORDS} words`, "↺5", () => this.back());
    e.play = button("Play", "▶", () => this.togglePlay());
    e.forward = button(`Forward ${SKIP_WORDS} words`, "5↻", () => this.forward());
    e.wpm = h("input", { type: "range", min: "100", max: "1000", step: "10", value: "250" });
    e.wpm.setAttribute("aria-label", "Reading speed");
    e.wpm.addEventListener("input", () => this.setWpm(Number(e.wpm.value)));
    e.wpmLabel = h("div", { className: "wpm-label" });
    e.wpmLabel.setAttribute("aria-hidden", "true");
    const controls = h("div", { className: "controls" }, e.back, e.play, e.forward);
    const speed = h("div", { className: "speed" }, e.wpmLabel, e.wpm);
    this.#root.replaceChildren(e.stage, controls, speed);
  }
}
