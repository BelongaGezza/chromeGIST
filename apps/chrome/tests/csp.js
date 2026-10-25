import init, { Reader } from "../pkg/chromegist_wasm.js";
import { ReaderView } from "../reader-core.js";
import { test, eq, ok, sleep, done } from "./harness.js";

const violations = [];
document.addEventListener("securitypolicyviolation", (e) => {
  violations.push({ directive: e.violatedDirective, uri: e.blockedURI });
});
const since = (n) => violations.slice(n);

await test("the meta CSP is active (a remote fetch is blocked by connect-src)", async () => {
  const n = violations.length;
  let rejected = false;
  try {
    await fetch("https://example.com/");
  } catch {
    rejected = true;
  }
  await sleep(100);
  ok(rejected, "fetch should reject");
  ok(since(n).some((v) => v.directive.startsWith("connect-src")), `connect-src violation: ${JSON.stringify(since(n))}`);
});

await test("a remote image is blocked", async () => {
  const n = violations.length;
  const img = new Image();
  const failed = new Promise((resolve) => { img.onerror = () => resolve(true); img.onload = () => resolve(false); });
  img.src = "https://example.com/x.png";
  eq(await failed, true, "image load should fail");
  ok(since(n).some((v) => /^(img|default)-src/.test(v.directive)), `img-src violation: ${JSON.stringify(since(n))}`);
});

await test("WASM still instantiates under the policy", async () => {
  const n = violations.length;
  await init();
  eq(since(n).length, 0, `violations: ${JSON.stringify(since(n))}`);
});

await test("a ReaderView loads and ticks; --orp-offset raises no violation", async () => {
  const n = violations.length;
  const v = new ReaderView(document.getElementById("app"));
  v.load(Reader, "one two three four five six seven eight nine ten");
  await sleep(600);
  const s = v.state();
  ok(s.index >= 1, `advanced (index ${s.index})`);
  ok(s.offset !== "", "--orp-offset set via CSSOM");
  v.destroy();
  eq(since(n).length, 0, `violations: ${JSON.stringify(since(n))}`);
});

done();
