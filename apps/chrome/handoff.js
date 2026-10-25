// One-time, in-memory handoff of selected text from the service worker to a
// reader window. The worker stores the text under a random id and opens
// reader.html#<id>; the reader claims it once by message, which deletes it.
// Unclaimed text expires after `ttlMs`. Nothing touches chrome.storage, so
// nothing is written to disk (docs/ARCHITECTURE.md, "Handing over the text").
export class Handoff {
  #items = new Map();
  #ttlMs;
  #now;

  constructor({ ttlMs = 60_000, now = () => Date.now() } = {}) {
    this.#ttlMs = ttlMs;
    this.#now = now;
  }

  /**
   * Stores `text`; returns the id the reader must present to claim it.
   * `incognito` records where the selection came from. With "split" the
   * incognito instance has its own Handoff, so this should never differ;
   * `take` still releases the text only to a reader in the same kind of
   * window, as defence in depth.
   */
  put(text, incognito = false) {
    this.#sweep();
    const id = crypto.randomUUID();
    this.#items.set(id, { text, incognito, at: this.#now() });
    // Also expire on a timer, so unclaimed text doesn't linger in a live
    // worker until the next put/take.
    setTimeout(() => this.#items.delete(id), this.#ttlMs);
    return id;
  }

  /**
   * Returns the text for `id` once, then forgets it. null if unknown, expired,
   * or claimed from a different incognito state than it was stored from (the
   * entry is still deleted).
   */
  take(id, incognito = false) {
    this.#sweep();
    const item = this.#items.get(id);
    this.#items.delete(id);
    return item && item.incognito === incognito ? item.text : null;
  }

  get size() {
    this.#sweep();
    return this.#items.size;
  }

  #sweep() {
    const now = this.#now();
    for (const [id, item] of this.#items) {
      if (now - item.at > this.#ttlMs) this.#items.delete(id);
    }
  }
}
