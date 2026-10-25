import { test, eq, ok, done } from "./harness.js";

const manifest = await (await fetch("../manifest.json")).json();
const csp = manifest.content_security_policy?.extension_pages ?? "";
const directives = Object.fromEntries(
  csp.split(";").map((d) => d.trim()).filter(Boolean).map((d) => {
    const [name, ...values] = d.split(/\s+/);
    return [name, values];
  }),
);

const ALLOWED_KEYS = new Set([
  "manifest_version", "name", "short_name", "description", "version",
  "minimum_chrome_version", "permissions", "background", "icons",
  "content_security_policy", "incognito",
]);

await test("manifest has only the reviewed top-level keys", () => {
  const extra = Object.keys(manifest).filter((k) => !ALLOWED_KEYS.has(k));
  eq(extra.join(","), "", "unexpected keys (host_permissions, content_scripts, web_accessible_resources, externally_connectable...)");
});

await test("the only permission is contextMenus", () => {
  eq(JSON.stringify(manifest.permissions), '["contextMenus"]', "permissions");
});

// "spanning" opens extension tabs in a regular window even for an incognito
// click (observed 2026-10-25), so incognito reading needs "split" or
// "not_allowed". Never allow the default back.
await test("incognito is split or not_allowed", () => {
  ok(manifest.incognito === "split" || manifest.incognito === "not_allowed", `incognito: ${manifest.incognito}`);
});

await test("CSP: default-src 'none', connect-src 'self', object-src 'none'", () => {
  eq(JSON.stringify(directives["default-src"]), `["'none'"]`, "default-src");
  eq(JSON.stringify(directives["connect-src"]), `["'self'"]`, "connect-src");
  eq(JSON.stringify(directives["object-src"]), `["'none'"]`, "object-src");
  eq(JSON.stringify(directives["base-uri"]), `["'none'"]`, "base-uri");
  eq(JSON.stringify(directives["form-action"]), `["'none'"]`, "form-action");
});

await test("CSP: script-src allows only 'self' and 'wasm-unsafe-eval'", () => {
  const values = [...(directives["script-src"] ?? [])].sort();
  eq(JSON.stringify(values), `["'self'","'wasm-unsafe-eval'"]`, "script-src");
});

await test("CSP: no directive allows remote origins, data:, blob: or unsafe-*", () => {
  for (const [name, values] of Object.entries(directives)) {
    for (const v of values) {
      ok(["'self'", "'none'", "'wasm-unsafe-eval'"].includes(v), `${name} allows ${v}`);
    }
  }
});

await test("reader.html has no inline script, style attribute or on* handler", async () => {
  const html = await (await fetch("../reader.html")).text();
  const doc = new DOMParser().parseFromString(html, "text/html");
  for (const s of doc.querySelectorAll("script")) {
    ok(s.hasAttribute("src") && !s.textContent.trim(), "inline <script> found");
  }
  ok(!doc.querySelector("style"), "inline <style> found");
  for (const el of doc.querySelectorAll("*")) {
    ok(!el.hasAttribute("style"), `style= on <${el.localName}>`);
    for (const a of el.attributes) ok(!/^on/i.test(a.name), `${a.name}= on <${el.localName}>`);
  }
});

await test("reader.css has no url() or @import", async () => {
  const css = await (await fetch("../reader.css")).text();
  ok(!/url\s*\(/i.test(css), "url( found");
  ok(!/@import/i.test(css), "@import found");
});

done();
