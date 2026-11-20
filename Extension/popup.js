document.documentElement.lang = chrome.i18n.getUILanguage();
for (const element of document.querySelectorAll("[data-message]")) {
  element.textContent = chrome.i18n.getMessage(element.dataset.message);
}

const status = document.querySelector("#status");
const summary = document.querySelector("#summary");
const takeover = document.querySelector("#takeover");
const minimum = document.querySelector("#minimum");
const excluded = document.querySelector("#excluded");
const version = document.querySelector("#version");
const open = document.querySelector("#open");

version.textContent = "v" + chrome.runtime.getManifest().version;
open.addEventListener("click", async () => {
  open.disabled = true;
  await chrome.runtime.sendMessage({ action: "open" }).catch(() => null);
  window.close();
});

const reply = await chrome.runtime.sendMessage({ action: "ping" }).catch(() => null);
const connected = Boolean(reply?.ok);
status.dataset.connected = String(connected);
status.textContent = chrome.i18n.getMessage(connected ? "connected" : "notConnected");
open.disabled = !connected;

if (connected && reply.rules) {
  const count = reply.rules.excludedHosts
    .split(/[\s,;]+/)
    .filter(Boolean).length;
  takeover.textContent = chrome.i18n.getMessage(reply.rules.enabled ? "takeoverOn" : "takeoverOff");
  minimum.textContent = chrome.i18n.getMessage("minimumShort", [String(reply.rules.minimumMiB)]);
  excluded.textContent = chrome.i18n.getMessage(count ? "excludedShort" : "excludedNone", [String(count)]);
  summary.hidden = false;
}
