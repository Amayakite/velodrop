// Firefox exposes the promise-based `browser` namespace. Chrome and Edge
// expose promise-based APIs on `chrome` in Manifest V3. Prefer `browser` so the
// same modules run in every supported browser.
export const api = globalThis.browser ?? globalThis.chrome;

// `getBrowserInfo` is Gecko-only and stays available in the background page.
export const isGecko = typeof api.runtime?.getBrowserInfo === "function";
