import init, { Reader } from "../pkg/chromegist_wasm.js";
import { ReaderView } from "../reader-core.js";
import { Handoff } from "../handoff.js";
import { test, eq, ok, sleep, done } from "./harness.js";

await init();
const root = document.getElementById("app");
const TEN = "one two three four five six seven eight nine ten";
const key = (k) => document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true }));
function view(text, opts) {
  const v = new ReaderView(root, opts);
  if (text !== undefined) v.load(Reader, text);
  return v;
}

// ── Handoff ─────────────────────────────────────────────────────────────────

await test("handoff: text can be claimed exactly once", () => {
  const h = new Handoff();
  const id = h.put("hello");
  ok(/^[0-9a-f-]{36}$/.test(id), `id looks like a UUID: ${id}`);
  eq(h.take(id), "hello", "first take");
  eq(h.take(id), null, "second take");
  eq(h.take("not-an-id"), null, "unknown id");
  eq(h.size, 0, "nothing left");
});

await test("handoff: unclaimed text expires", () => {
  let now = 0;
  const h = new Handoff({ ttlMs: 60_000, now: () => now });
  const id = h.put("secret");
  now = 60_001;
  eq(h.size, 0, "swept");
  eq(h.take(id), null, "expired");
});

await test("handoff: text is only released to the same incognito state", () => {
  const h = new Handoff();
  let id = h.put("private", true);
  eq(h.take(id, false), null, "incognito text refused to a normal reader");
  eq(h.take(id, true), null, "and the refused attempt still consumed it");
  id = h.put("private", true);
  eq(h.take(id, true), "private", "incognito reader gets incognito text");
  id = h.put("public");
  eq(h.take(id, true), null, "normal text refused to an incognito reader");
});

await test("handoff: ids are unique", () => {
  const h = new Handoff();
  const ids = new Set(Array.from({ length: 100 }, () => h.put("x")));
  eq(ids.size, 100, "distinct ids");
});

// ── ReaderView ──────────────────────────────────────────────────────────────

await test("loads, shows the first word centred on its ORP letter, autoplays", () => {
  const v = view(TEN);
  const s = v.state();
  eq(s.state, "reading", "state");
  eq(s.playing, true, "autoplay");
  eq(s.word, "one", "word");
  eq(s.focus, "e", "focus (GIST: ~30% in, then next vowel)");
  eq(s.offset, "-1", "offset in ch: (suffix 0 - prefix 2) / 2");
  eq(s.progress, "1 / 10", "progress");
  v.destroy();
});

await test("advances with GIST's pacing (240 ms/word at 250 WPM)", async () => {
  const v = view(TEN);
  await sleep(600); // ≥ 2 words
  const i = v.state().index;
  v.destroy();
  ok(i >= 2 && i <= 3, `index after 600 ms: ${i}`);
  return `index ${i} after 600 ms`;
});

await test("pause holds position; play resumes", async () => {
  const v = view(TEN);
  await sleep(300);
  v.pause();
  const i = v.state().index;
  await sleep(400);
  eq(v.state().index, i, "held while paused");
  eq(v.state().playing, false, "paused");
  v.play();
  await sleep(300);
  ok(v.state().index > i, "moved after resume");
  v.destroy();
});

await test("back/forward skip 5 words; WPM slider changes pace", () => {
  const v = view(TEN);
  v.pause();
  v.forward();
  eq(v.state().index, 5, "forward 5");
  v.back();
  eq(v.state().index, 0, "back 5");
  v.setWpm(1000);
  eq(v.state().wpm, 1000, "wpm");
  v.setWpm(5);
  eq(v.state().wpm, 100, "clamped by GIST");
  v.destroy();
});

await test("keyboard: space on a focused button is left to the button", () => {
  const v = view(TEN);
  const btn = document.createElement("button");
  document.body.append(btn);
  btn.dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true }));
  eq(v.state().playing, true, "no double toggle from the global handler");
  btn.remove();
  v.destroy();
});

await test("keyboard: space toggles, arrows skip, Escape closes", () => {
  let closed = false;
  const v = view(TEN, { onClose: () => (closed = true) });
  key(" ");
  eq(v.state().playing, false, "space pauses");
  key("ArrowRight");
  eq(v.state().index, 5, "→ forward");
  key("ArrowLeft");
  eq(v.state().index, 0, "← back");
  key("Escape");
  eq(closed, true, "Escape → onClose");
  v.destroy();
});

await test("stops on the last word; play restarts from the beginning", async () => {
  const v = view("alpha beta");
  v.setWpm(1000); // 60 ms/word
  await sleep(400);
  let s = v.state();
  eq(s.playing, false, "stopped at end");
  eq(s.word, "beta", "last word stays");
  ok(/may shorten very long selections/.test(s.note), `end note shown: ${s.note}`);
  v.play();
  eq(v.state().word, "alpha", "restarted");
  eq(v.state().note, "", "note cleared on restart");
  v.destroy();
});

await test("no truncation note while reading, or on messages", () => {
  const v = view("alpha beta gamma");
  eq(v.state().note, "", "none while playing");
  v.pause();
  v.forward();
  eq(v.state().note, "", "none after skipping");
  v.destroy();
  const empty = view("   ");
  eq(empty.state().note, "", "none on a message");
  empty.destroy();
});

await test("too-long selection shows a message and disables controls", () => {
  const v = view("a".repeat(Reader.maxSelectionBytes() + 1));
  const s = v.state();
  eq(s.state, "message", "state");
  ok(/too long/.test(s.message), `message: ${s.message}`);
  ok(root.querySelectorAll("button:disabled").length === 3, "buttons disabled");
  v.destroy();
});

await test("whitespace-only selection says there's nothing to read", () => {
  const v = view(" \n\n\t ");
  eq(v.state().message, "No words to read in this selection.", "message");
  v.destroy();
});

await test("a panic inside WASM is contained: error shown, nothing runs after", async () => {
  const errors = [];
  const onError = (e) => errors.push(e.message);
  window.addEventListener("error", onError);
  const v = view(TEN);
  ok(typeof v.reader.panicForTest === "function", "test-hooks build");
  v.guard(() => v.reader.panicForTest());
  const s = v.state();
  eq(s.crashed, true, "crashed");
  eq(s.state, "message", "state");
  ok(/went wrong/.test(s.message), `message: ${s.message}`);
  key(" ");
  key("ArrowRight");
  await sleep(500); // any leftover timer would fire and throw here
  window.removeEventListener("error", onError);
  eq(errors.length, 0, `uncaught errors after the crash: ${errors.join("; ")}`);
  v.destroy();
});

await test("paragraph breaks show no word and aren't counted", async () => {
  const v = view("first.\n\nsecond");
  v.pause();
  v.forward(1);
  const s = v.state();
  eq(s.word, "second", "forward skips the break (counts words only)");
  eq(s.progress, "2 / 2", "progress");
  v.destroy();
});

done();
