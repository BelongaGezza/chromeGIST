// Reader window bootstrap: claims the selection from the service worker
// (one-time, by the id in the URL fragment), then hands it to ReaderView.
import init, { Reader } from "./pkg/chromegist_wasm.js";
import { ReaderView } from "./reader-core.js";

const view = new ReaderView(document.getElementById("app"), { onClose: () => window.close() });
view.showLoading();

const id = location.hash.slice(1);
// Drop the id from the address so it isn't reused (it's single-use anyway).
history.replaceState(null, "", location.pathname);

let text = null;
try {
  const response = await chrome.runtime.sendMessage({ type: "take", id });
  text = response?.text ?? null;
} catch {
  text = null;
}

if (text === null) {
  view.showMessage("This selection has expired. Select the text again and choose Speed Read with chromeGIST.");
} else {
  try {
    await init();
    view.load(Reader, text);
  } catch (e) {
    console.error(e);
    view.showMessage("chromeGIST couldn't start. Close this window and try again.");
  }
  text = null;
}
