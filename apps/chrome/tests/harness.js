// Minimal test harness for browser test pages. Each page logs
// "[chromeGIST] PASS|FAIL <name>" and a final "[chromeGIST] DONE: ..." line,
// which tools/test-browser.sh reads from headless Chrome's console.
const out = [];
let failed = 0;

export const log = (line) => {
  out.push(line);
  console.log(`[chromeGIST] ${line}`);
};

export async function test(name, fn) {
  try {
    const detail = await fn();
    log(`PASS ${name}${detail ? ` (${detail})` : ""}`);
  } catch (e) {
    failed++;
    log(`FAIL ${name}: ${e && e.message ? e.message : e}`);
  }
}

export function eq(actual, expected, what = "value") {
  if (actual !== expected) {
    throw new Error(`${what}: got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
  }
}

export function ok(condition, what) {
  if (!condition) throw new Error(what);
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function done() {
  log(failed ? `DONE: ${failed} failed` : "DONE: all passed");
  const pre = document.getElementById("results");
  if (pre) pre.textContent = out.join("\n");
}
