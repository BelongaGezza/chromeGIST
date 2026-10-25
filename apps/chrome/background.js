// chromeGIST service worker: one context-menu item. On click, hands the
// selection to a new reader popup window (a tab, for incognito). Chrome passes the selection as
// `info.selectionText`, so the extension never reads page contents and
// needs no permission beyond "contextMenus".
import { Handoff } from "./handoff.js";

const MENU_ID = "chromegist-speed-read";
const READER_URL = chrome.runtime.getURL("reader.html");
const handoff = new Handoff();

function createMenu() {
  chrome.contextMenus.create({
    id: MENU_ID,
    title: "Speed Read with chromeGIST",
    contexts: ["selection"],
  });
}

chrome.runtime.onInstalled.addListener(createMenu);
// "incognito": "split" runs a second, separate instance of this worker inside
// incognito, with its own menus and its own in-memory handoff. Don't rely on
// onInstalled reaching it: create the menu when that instance starts too.
if (chrome.extension?.inIncognitoContext) createMenu();

// Only `tab.incognito` and `tab.windowId` are read from `tab` (neither needs
// the "tabs" permission). With "spanning" (the default) one worker serves both
// profiles and Chrome silently opens extension tabs in a regular window even
// when given an incognito `windowId` (observed 2026-10-25), and
// `windows.create({incognito: true})` is blocked (ERR_BLOCKED_BY_CLIENT,
// observed 2026-10-01). So the manifest uses "split": the incognito instance
// of this worker handles incognito clicks and opens the reader inside
// incognito, as a tab in the clicked window. (Needs "Allow in Incognito".)
chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== MENU_ID || !info.selectionText) return;
  const id = handoff.put(info.selectionText, tab?.incognito === true);
  const url = `${READER_URL}#${id}`;
  try {
    if (tab?.incognito === true && tab.windowId !== undefined) {
      await chrome.tabs.create({ url, windowId: tab.windowId });
    } else {
      await chrome.windows.create({ url, type: "popup", width: 620, height: 400 });
    }
  } catch (e) {
    // The text is never claimed; the handoff TTL deletes it. Log no text.
    console.warn("chromeGIST: couldn't open the reader window", e?.message ?? "");
  }
});

// Only the extension's own reader page may claim text. (Web pages can't
// message an extension without "externally_connectable", which chromeGIST
// doesn't declare; this is defence in depth.)
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || !sender.url?.startsWith(READER_URL)) return;
  if (message?.type === "take" && typeof message.id === "string") {
    sendResponse({ text: handoff.take(message.id, sender.tab?.incognito === true) });
  }
});
