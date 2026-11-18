const enabled = document.querySelector("#enabled");
const minimum = document.querySelector("#minimum");
const hosts = document.querySelector("#hosts");
const status = document.querySelector("#status");

const settings = await chrome.storage.local.get({ enabled: true, minimumMiB: 2, excludedHosts: "" });
enabled.checked = settings.enabled;
minimum.value = settings.minimumMiB;
hosts.value = settings.excludedHosts;
enabled.addEventListener("change", () => chrome.storage.local.set({ enabled: enabled.checked }));
minimum.addEventListener("change", () => {
  if (minimum.checkValidity() && minimum.value !== "") {
    void chrome.storage.local.set({ minimumMiB: Number(minimum.value) });
  }
});
hosts.addEventListener("input", () => chrome.storage.local.set({ excludedHosts: hosts.value }));
const connection = await chrome.runtime.sendMessage({ action: "ping" }).catch(() => null);
status.dataset.connected = String(Boolean(connection?.ok));
status.textContent = connection?.ok ? "Connected to your Mac" : "Set up Edge in VeloDrop Settings";
