import { normalizedHost, observeBrowserRequests, requestContext } from "./network.js";

observeBrowserRequests();

const host = "com.amayakite.velodrop";
const alarm = "velodrop-watch";
const prefix = "transfer:";
const starting = new Set();
const defaults = { enabled: true, minimumMiB: 2, excludedHosts: "" };
let pulse;
let sweeping = false;

function native(message, timeout = 2400) {
  let timer;
  return Promise.race([
    chrome.runtime.sendNativeMessage(host, message),
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("VeloDrop did not respond")), timeout);
    }),
  ]).finally(() => clearTimeout(timer));
}

function safeURL(value) {
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return null;
    url.hash = "";
    return url;
  } catch {
    return null;
  }
}

function eligible(item, settings) {
  if (!settings.enabled || item.paused || item.state !== "in_progress" ||
      item.danger !== "safe" || item.incognito || !item.filename) return null;
  if (item.mime === "text/html" || item.mime === "application/xhtml+xml") return null;
  const url = safeURL(item.finalUrl || item.url);
  if (!url || !safeURL(item.url)) return null;
  if (settings.minimumMiB > 0 && item.totalBytes < settings.minimumMiB * 1024 * 1024) return null;
  const blocked = settings.excludedHosts.split(/[\s,;]+/).map(normalizedHost).filter(Boolean);
  const hosts = [url.hostname, normalizedHost(item.url), normalizedHost(item.referrer ?? "")];
  if (blocked.some(domain => hosts.some(host => host === domain || host.endsWith("." + domain)))) return null;
  return url;
}

async function takeOver(browserId) {
  if (starting.has(browserId)) return;
  starting.add(browserId);
  const key = prefix + browserId;
  let handoff;
  try {
    const stored = await chrome.storage.local.get({ ...defaults, [key]: null });
    if (stored[key]) return;
    const [item] = await chrome.downloads.search({ id: browserId });
    if (!item) return;
    const url = eligible(item, stored);
    if (!url) return;
    const context = await requestContext(item, url);
    if (!context) return;

    // Keep Edge in charge unless the registered desktop helper can answer.
    const ping = await native({ action: "ping" });
    if (!ping.ok) return;
    handoff = { id: crypto.randomUUID(), browserId, started: Date.now() };
    await chrome.storage.local.set({ [key]: handoff });
    await ensureAlarm();
    await chrome.downloads.pause(browserId);
    const [paused] = await chrome.downloads.search({ id: browserId });
    if (!paused?.paused || paused.state !== "in_progress" || paused.danger !== "safe") {
      await release(handoff, "resume");
      return;
    }
    const reply = await native({
      action: "submit",
      id: handoff.id,
      url: url.href,
      source: item.url,
      referrer: safeURL(item.referrer)?.href,
      mimeType: item.mime,
      headers: context.headers,
      proxy: context.proxy,
      name: item.filename.split(/[\\/]/).pop(),
      size: Number.isSafeInteger(item.fileSize) && item.fileSize > 0
        ? item.fileSize
        : (Number.isSafeInteger(item.totalBytes) && item.totalBytes > 0 ? item.totalBytes : null),
    });
    if (!reply.ok) await release(handoff, "resume");
  } catch {
    if (handoff) await release(handoff, "resume").catch(() => {});
  } finally {
    starting.delete(browserId);
    if (handoff) schedule();
  }
}

async function release(handoff, outcome) {
  if (outcome === "resume" || outcome === "abandon") {
    await native({ action: "abandon", id: handoff.id }).catch(() => {});
  }
  let [item] = await chrome.downloads.search({ id: handoff.browserId });
  if (item?.state === "in_progress" && item.paused) {
    if (outcome === "resume") await chrome.downloads.resume(handoff.browserId);
    if (outcome === "cancel") {
      await chrome.downloads.cancel(handoff.browserId);
      [item] = await chrome.downloads.search({ id: handoff.browserId });
    }
  }
  if (outcome === "cancel" && item?.state === "interrupted" && item.error === "USER_CANCELED") {
    await chrome.downloads.erase({ id: handoff.browserId });
  }
  await chrome.storage.local.remove(prefix + handoff.browserId);
  await native({ action: "acknowledge", id: handoff.id }).catch(() => {});
}

async function ensureAlarm() {
  if (!(await chrome.alarms.get(alarm))) {
    await chrome.alarms.create(alarm, { periodInMinutes: 0.5 });
  }
}

function schedule() {
  if (pulse !== undefined) return;
  pulse = setTimeout(() => {
    pulse = undefined;
    void sweep();
  }, 2000);
}

async function sweep() {
  if (sweeping) return;
  sweeping = true;
  try {
    const data = await chrome.storage.local.get(null);
    const jobs = Object.entries(data).filter(([key]) => key.startsWith(prefix)).map(([, job]) => job);
    if (!jobs.length) {
      if (!starting.size) await chrome.alarms.clear(alarm);
      return;
    }
    await ensureAlarm();
    const returned = await native({ action: "status", ids: jobs.map(job => job.id) })
      .catch(() => ({ ok: false }));
    for (const job of jobs) {
      if (starting.has(job.browserId)) continue;
      try {
        const [item] = await chrome.downloads.search({ id: job.browserId });
        const state = returned.jobs?.[job.id];
        if (!item || item.state !== "in_progress" || !item.paused) {
          const committed = state?.state === "completed" || state?.state === "canceled";
          await release(job, committed ? "cancel" : "abandon");
          continue;
        }
        if (item.danger !== "safe") {
          await release(job, "resume");
          continue;
        }
        if (state?.state === "completed" || state?.state === "canceled") {
          await release(job, "cancel");
        } else if (state?.state === "failed" || !returned.ok ||
            (!state && Date.now() - job.started > 8500) ||
            (state?.state === "awaitingConfirmation" && returned.appRunning === false) ||
            (state && !["paused", "awaitingConfirmation"].includes(state.state) && Date.now() - state.updatedAt > 14000)) {
          await release(job, "resume");
        }
      } catch {
        // The alarm retries browser or disk operations after a transient failure.
      }
    }
    schedule();
  } finally {
    sweeping = false;
  }
}

chrome.downloads.onCreated.addListener(item => void takeOver(item.id));
chrome.downloads.onChanged.addListener(delta => {
  if (delta.filename || delta.danger?.current === "safe") void takeOver(delta.id);
  if (delta.state || delta.paused) schedule();
});
chrome.downloads.onErased.addListener(() => schedule());
chrome.alarms.onAlarm.addListener(event => {
  if (event.name === alarm) void sweep();
});
chrome.runtime.onStartup.addListener(() => void sweep());
chrome.runtime.onInstalled.addListener(() => void sweep());
chrome.runtime.onMessage.addListener((message, _, reply) => {
  if (message.action !== "ping") return false;
  native({ action: "ping" }).then(reply, () => reply({ ok: false }));
  return true;
});
