// Runs chromegist-wasm in a real browser: the checks native `cargo test`
// can't make (JS host, wasm32 clock/randomness, JsError, real timings).
import init, { Reader } from "../pkg/chromegist_wasm.js";

const out = [];
let failed = 0;
const log = (line) => { out.push(line); console.log(`[chromeGIST] ${line}`); };
function check(name, fn) {
  try {
    const detail = fn();
    log(`PASS ${name}${detail ? ` (${detail})` : ""}`);
  } catch (e) {
    failed++;
    log(`FAIL ${name}: ${e && e.message ? e.message : e}`);
  }
}
const eq = (a, b, what) => { if (a !== b) throw new Error(`${what}: got ${JSON.stringify(a)}, want ${JSON.stringify(b)}`); };

await init();

check("tokenize at runtime (uuid now_v7 clock + randomness on wasm32)", () => {
  const r = new Reader("Hello world. Second sentence.\n\nNew paragraph.");
  eq(r.wordCount(), 6, "words");
  eq(r.kind(4), 1, "paragraph break kind");
  eq(r.wordsThrough(4), 4, "words through the break");
  return `${r.tokenCount()} tokens`;
});

check("selection cap is enforced with a JS Error", () => {
  const max = Reader.maxSelectionBytes();
  new Reader("a".repeat(max)); // exactly at the cap: accepted
  try { new Reader("a".repeat(max + 1)); } catch (e) {
    eq(e instanceof Error, true, "Error instance");
    eq(e.message, "selection too long", "message");
    return `${max} bytes`;
  }
  throw new Error("over-cap selection was accepted");
});

check("cap counts UTF-8 bytes, not JS string length", () => {
  const max = Reader.maxSelectionBytes();
  const s = "é".repeat(max / 2 + 1); // 2 bytes each: over the cap, though .length < max
  try { new Reader(s); } catch (e) { return `${s.length} UTF-16 units rejected`; }
  throw new Error("accepted");
});

check("GIST pacing: 240 ms per plain word at 250 WPM", () => {
  const r = new Reader("a b c d e");
  r.play();
  eq(r.current(0), 0, "t=0");
  eq(r.current(239.4), 0, "t=239.4 (rounds to 239)");
  eq(r.current(239.6), 1, "t=239.6 (rounds to 240)");
  eq(r.remainingMs(100), 140, "remaining at 100");
  r.pause(600);
  eq(r.current(99999), 2, "paused holds position");
  r.setWpm(5000, 0);
  eq(r.wpm(), 1000, "clamped");
});

check("focus letter is one whole grapheme (flag, ZWJ family)", () => {
  const r = new Reader("🇬🇧 👨‍👩x");
  const seg = new Intl.Segmenter();
  for (let i = 0; i < r.tokenCount(); i++) {
    eq([...seg.segment(r.focus(i))].length, 1, `token ${i} focus graphemes`);
  }
  return `🇬🇧 → [${r.prefix(0)}|${r.focus(0)}|${r.suffix(0)}]`;
});

check("512 KiB selection: construction time", () => {
  const para = "The quick brown fox, having considered its options carefully, jumped over 42 lazy dogs. ";
  let text = "";
  while (text.length < 512 * 1024 - para.length) text += para;
  const t0 = performance.now();
  const r = new Reader(text);
  const ms = performance.now() - t0;
  if (ms > 1000) throw new Error(`${ms.toFixed(0)} ms`);
  // Worst-case tick: token_at_elapsed walks from the cursor, so near the end
  // of an unpaused 5.8 h session it walks ~87k tokens per call.
  r.play();
  const far = 6 * 3600 * 1000;
  const t1 = performance.now();
  const N = 20;
  for (let i = 0; i < N; i++) r.current(far + i);
  const tick = (performance.now() - t1) / N;
  globalThis.__worstTickMs = tick;
  return `${r.wordCount()} words in ${ms.toFixed(0)} ms; worst-case tick ${tick.toFixed(2)} ms`;
});

log(failed ? `DONE: ${failed} failed` : "DONE: all passed");
document.getElementById("results").textContent = out.join("\n");
