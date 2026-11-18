import { networkPermissions, normalizedHost } from "./network.js";

document.documentElement.lang = chrome.i18n.getUILanguage();
for (const element of document.querySelectorAll("[data-message]")) {
  element.textContent = chrome.i18n.getMessage(element.dataset.message);
}

const enabled = document.querySelector("#enabled");
const minimum = document.querySelector("#minimum");
const hosts = document.querySelector("#hosts");
const status = document.querySelector("#status");
const browserNetwork = document.querySelector("#browser-network");

const settings = await chrome.storage.local.get({ enabled: true, minimumMiB: 2, excludedHosts: "" });
enabled.checked = settings.enabled;
browserNetwork.checked = await chrome.permissions.contains(networkPermissions).catch(() => false);
minimum.value = settings.minimumMiB;
hosts.value = settings.excludedHosts;
enabled.addEventListener("change", () => chrome.storage.local.set({ enabled: enabled.checked }));
browserNetwork.addEventListener("change", async () => {
  try {
    if (browserNetwork.checked) await chrome.permissions.request(networkPermissions);
    else await chrome.permissions.remove(networkPermissions);
  } finally {
    browserNetwork.checked = await chrome.permissions.contains(networkPermissions).catch(() => false);
  }
});

const siteButton = document.querySelector("#add-site");
const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
const site = normalizedHost(tab?.url ?? "");
siteButton.hidden = !site;
siteButton.addEventListener("click", async () => {
  const existing = hosts.value.trim().split(/\s+/).map(normalizedHost).filter(Boolean);
  hosts.value = [...new Set([...existing, site])].join("\n");
  await chrome.storage.local.set({ excludedHosts: hosts.value });
  siteButton.disabled = true;
});

minimum.addEventListener("change", () => {
  if (minimum.checkValidity() && minimum.value !== "") {
    void chrome.storage.local.set({ minimumMiB: Number(minimum.value) });
  }
});
hosts.addEventListener("input", () => chrome.storage.local.set({ excludedHosts: hosts.value }));
const connection = await chrome.runtime.sendMessage({ action: "ping" }).catch(() => null);
status.dataset.connected = String(Boolean(connection?.ok));
status.textContent = chrome.i18n.getMessage(connection?.ok ? "connected" : "notConnected");
