import { test, eq, ok, done } from "./harness.js";

// Stub the extension API before background.js runs (it touches `chrome` at
// import time).
const listeners = {};
const created = [];
const menus = [];
let failCreate = false;
const addListener = (name) => ({ addListener: (fn) => { listeners[name] = fn; } });
globalThis.chrome = {
  runtime: {
    id: "abc",
    getURL: (p) => `chrome-extension://abc/${p}`,
    onInstalled: addListener("installed"),
    onMessage: addListener("message"),
  },
  contextMenus: {
    create: (props) => menus.push(props),
    onClicked: addListener("clicked"),
  },
  windows: {
    create: async (props) => {
      if (failCreate) throw new Error("boom");
      created.push({ via: "window", ...props });
    },
  },
  tabs: {
    create: async (props) => {
      if (failCreate) throw new Error("boom");
      created.push({ via: "tab", ...props });
    },
  },
};

await import("../background.js");
const menusAtStartup = menus.length;

const MENU = "chromegist-speed-read";
const click = (info, tab) => listeners.clicked(info, tab);
const readerSender = { id: "abc", url: "chrome-extension://abc/reader.html" };
const incognitoSender = { ...readerSender, tab: { incognito: true } };
function claim(id, sender = readerSender) {
  let reply;
  let called = false;
  listeners.message({ type: "take", id }, sender, (r) => { called = true; reply = r; });
  return called ? reply : undefined;
}

await test("registers the selection menu item on install", () => {
  listeners.installed();
  eq(menusAtStartup, 0, "a normal-context worker creates nothing until installed");
  eq(menus.length, 1, "one item");
  eq(menus[0].id, MENU, "id");
  eq(JSON.stringify(menus[0].contexts), '["selection"]', "contexts");
});

// Chrome blocks extension popups created with incognito:true, so an
// incognito selection opens a tab in the clicking window; everything else is
// a popup that never sets `incognito`.
for (const [label, tab] of [
  ["normal tab", { incognito: false, windowId: 7 }],
  ["no tab", undefined],
  ["incognito tab without a windowId", { incognito: true }],
]) {
  await test(`popup (no incognito flag) for ${label}`, async () => {
    created.length = 0;
    await click({ menuItemId: MENU, selectionText: "hello world" }, tab);
    eq(created.length, 1, "one window");
    eq(created[0].via, "window", "popup window");
    eq(created[0].type, "popup", "type");
    eq("incognito" in created[0], false, "incognito flag not passed");
  });
}

await test("incognito tab: reader opens as a tab in the same window", async () => {
  created.length = 0;
  await click({ menuItemId: MENU, selectionText: "hello world" }, { incognito: true, windowId: 42 });
  eq(created.length, 1, "one item");
  eq(created[0].via, "tab", "tab, not popup");
  eq(created[0].windowId, 42, "same window");
  ok(/^chrome-extension:\/\/abc\/reader\.html#[0-9a-f-]{36}$/.test(created[0].url), `url: ${created[0].url}`);
});

await test("wrong menu id or empty selection opens nothing", async () => {
  created.length = 0;
  await click({ menuItemId: "other", selectionText: "x" }, {});
  await click({ menuItemId: MENU, selectionText: "" }, {});
  await click({ menuItemId: MENU }, {});
  eq(created.length, 0, "no window");
});

await test("window URL is reader.html#<uuid>; text is claimable exactly once", async () => {
  created.length = 0;
  await click({ menuItemId: MENU, selectionText: "secret text" }, {});
  const m = /^chrome-extension:\/\/abc\/reader\.html#([0-9a-f-]{36})$/.exec(created[0].url);
  ok(m, `url shape: ${created[0].url}`);
  eq(claim(m[1])?.text, "secret text", "first take");
  eq(claim(m[1])?.text, null, "second take");
});

await test("foreign senders get no response and don't consume the text", async () => {
  created.length = 0;
  await click({ menuItemId: MENU, selectionText: "keep me" }, {});
  const id = created[0].url.split("#")[1];
  eq(claim(id, { id: "evil", url: readerSender.url }), undefined, "wrong extension id");
  eq(claim(id, { id: "abc", url: "chrome-extension://abc/other.html" }), undefined, "other page");
  eq(claim(id, { id: "abc" }), undefined, "no url");
  eq(claim(id)?.text, "keep me", "still claimable by the reader");
});

await test("incognito selections are only released to an incognito reader", async () => {
  created.length = 0;
  await click({ menuItemId: MENU, selectionText: "private" }, { incognito: true, windowId: 5 });
  const id = created[0].url.split("#")[1];
  eq(claim(id)?.text, null, "a normal-window reader gets nothing");
  created.length = 0;
  await click({ menuItemId: MENU, selectionText: "private" }, { incognito: true, windowId: 5 });
  eq(claim(created[0].url.split("#")[1], incognitoSender)?.text, "private", "the incognito reader gets it");
});

await test("a failing windows.create doesn't throw", async () => {
  failCreate = true;
  try {
    await click({ menuItemId: MENU, selectionText: "x" }, {});
    await click({ menuItemId: MENU, selectionText: "x" }, { incognito: true, windowId: 1 });
  } finally {
    failCreate = false;
  }
});

done();
