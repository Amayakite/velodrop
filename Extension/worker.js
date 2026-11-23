import { api, isGecko } from "./api.js";
import { normalizedHost, observeBrowserRequests, observeResponses, requestContext, responseInfo } from "./network.js";

const host = "com.amayakite.velodrop";
const alarm = "velodrop-watch";
const prefix = "transfer:";
const starting = new Set();
const defaults = { enabled: true, minimumMiB: 2, excludedHosts: "", reuseSessionHeaders: false };
let pulse;
let sweeping = false;
let cachedRules = null;
let rulesAt = 0;
let rulesRequest = null;

// The extension is only a bridge. Settings are owned by the VeloDrop app and
// fetched through the native helper; the popup never writes configuration.
observeBrowserRequests(() => cachedRules?.reuseSessionHeaders === true);
observeResponses();

function native(message, timeout = 2400) {
  let timer;
  return Promise.race([
    api.runtime.sendNativeMessage(host, message),
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("VeloDrop did not respond")), timeout);
    }),
  ]).finally(() => clearTimeout(timer));
}

async function reloadWhenIdle() {
  const data = await api.storage.local.get(null);
  const busy = starting.size > 0 || Object.keys(data).some(key => key.startsWith(prefix));
  if (busy) {
    setTimeout(() => void reloadWhenIdle(), 3000);
    return;
  }
  api.runtime.reload();
}

async function rememberAppVersion(version) {
  if (!version) return;
  const { appVersion = "" } = await api.storage.local.get({ appVersion: "" });
  if (appVersion === version) return;
  await api.storage.local.set({ appVersion: version });
  // The app was replaced while this service worker kept running. Reloading
  // picks up the browser extension shipped with the new version, but wait until
  // no handoff is in flight so an update cannot interrupt a download.
  if (appVersion) setTimeout(() => void reloadWhenIdle(), 80);
}

async function pingApp() {
  const reply = await native({ action: "ping", extensionVersion: api.runtime.getManifest().version });
  if (!reply?.ok) throw new Error("VeloDrop is not ready");
  await rememberAppVersion(reply.version);
  if (reply.rules) {
    cachedRules = { ...defaults, ...reply.rules, testURL: reply.testURL };
    rulesAt = Date.now();
  }
  return reply;
}

async function currentRules(force = false) {
  if (!force && cachedRules && Date.now() - rulesAt < 5000) return cachedRules;
  if (!rulesRequest) {
    rulesRequest = pingApp()
      .then(() => cachedRules ?? defaults)
      .catch(() => cachedRules ?? defaults)
      .finally(() => { rulesRequest = null; });
  }
  return rulesRequest;
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

function isBrowserTest(item, rules) {
  return Boolean(rules.testURL && item.url === rules.testURL &&
    (!item.finalUrl || item.finalUrl === rules.testURL));
}

function eligible(item, rules) {
  if (item.paused || item.state !== "in_progress" ||
      (item.danger !== undefined && item.danger !== "safe") ||
      item.incognito || !item.filename) return null;
  if (item.mime === "text/html" || item.mime === "application/xhtml+xml") return null;
  const url = safeURL(item.finalUrl || item.url);
  if (!url || !safeURL(item.url)) return null;
  if (isBrowserTest(item, rules)) return url;
  if (!rules.enabled) return null;
  const size = item.totalBytes > 0 ? item.totalBytes : item.fileSize;
  if (rules.minimumMiB > 0 && !(size >= rules.minimumMiB * 1024 * 1024)) return null;
  const blocked = rules.excludedHosts.split(/[\s,;]+/).map(normalizedHost).filter(Boolean);
  const hosts = [url.hostname, normalizedHost(item.url), normalizedHost(item.referrer ?? "")];
  if (blocked.some(domain => hosts.some(host => host === domain || host.endsWith("." + domain)))) return null;
  return url;
}

function heldByExtension(item) {
  // Gecko exposes a paused download as interrupted until it is resumed.
  return item?.paused === true &&
    (item.state === "in_progress" || (isGecko && item.state === "interrupted"));
}

function exchange(port, message, timeout = 850) {
  return new Promise((resolve, reject) => {
    const finish = (callback, value) => {
      clearTimeout(timer);
      port.onMessage.removeListener(received);
      port.onDisconnect.removeListener(disconnected);
      callback(value);
    };
    const received = reply => finish(resolve, reply);
    const disconnected = () => finish(reject,
      new Error(port.error?.message ?? api.runtime.lastError?.message ?? "VeloDrop disconnected"));
    const timer = setTimeout(() => finish(reject, new Error("VeloDrop did not respond")), timeout);
    port.onMessage.addListener(received);
    port.onDisconnect.addListener(disconnected);
    try { port.postMessage(message); }
    catch (error) { finish(reject, error); }
  });
}

function replayable(item, context) {
  const source = safeURL(item.url);
  return source && !source.search && !context.headers.authorization &&
    (context.method === "GET" || /\.[a-z0-9]{1,8}$/i.test(source.pathname));
}

async function canHoldGeckoDownload(item, url) {
  const info = responseInfo(url.href) ?? responseInfo(item.url);
  if (!info?.acceptsRanges || !info.hasValidator || (info.contentEncoding && info.contentEncoding !== "identity")) {
    return false;
  }
  // Gecko cancels instead of pausing when its partial file is still empty.
  // Byte progress does not trigger downloads.onChanged in Firefox.
  const deadline = Date.now() + 1600;
  while (Date.now() < deadline) {
    const [current] = await api.downloads.search({ id: item.id });
    if (!current || current.state !== "in_progress" || current.paused) return false;
    if (current.bytesReceived > 0) return true;
    await new Promise(resolve => setTimeout(resolve, 80));
  }
  return false;
}

function payload(item, url, context, handoff, action) {
  return {
    action,
    id: handoff.id,
    url: url.href,
    source: item.url,
    referrer: safeURL(item.referrer)?.href,
    mimeType: item.mime,
    headers: context.headers,
    proxy: context.proxy,
    name: item.filename.split(/[\\/]/).pop() || "download",
    size: Number.isSafeInteger(item.fileSize) && item.fileSize > 0 ? item.fileSize
      : (Number.isSafeInteger(item.totalBytes) && item.totalBytes > 0 ? item.totalBytes : null),
  };
}

async function takeOver(item, rules) {
  const browserId = item.id;
  const key = prefix + browserId;
  let handoff;
  let port;
  let canceled = false;
  try {
    const currentSettings = rules ?? await currentRules(true);
    const url = eligible(item, currentSettings);
    if (!url) return;
    const context = isBrowserTest(item, currentSettings)
      ? { headers: {}, proxy: { mode: "direct" }, method: "GET" }
      : await requestContext(item, url, currentSettings.reuseSessionHeaders);
    if (!context) return;
    const fast = Boolean(replayable(item, context));
    if (isGecko && !fast && !(await canHoldGeckoDownload(item, url))) return;
    handoff = {
      id: crypto.randomUUID(),
      browserId,
      started: Date.now(),
      fast,
      ...(fast ? { source: item.url } : {}),
    };
    if (fast) {
      port = api.runtime.connectNative(host);
      const saved = await exchange(port, payload(item, url, context, handoff, "reserve"));
      if (!saved.ok) return;
      await api.storage.local.set({ [key]: handoff });
      await ensureAlarm();
      await api.downloads.cancel(browserId);
      const [original] = await api.downloads.search({ id: browserId });
      canceled = original?.state === "interrupted" && original.error === "USER_CANCELED";
      if (!canceled) {
        await release(handoff, "abandon");
        return;
      }
      const activated = exchange(port, { action: "activate", id: handoff.id }, 2400).catch(() => null);
      // Remove the interrupted item before resolving filename determination.
      await api.downloads.erase({ id: browserId }).catch(() => {});
      await activated;
    } else {
      await api.storage.local.set({ [key]: handoff });
      await ensureAlarm();
      await api.downloads.pause(browserId);
      const [paused] = await api.downloads.search({ id: browserId });
      if (!heldByExtension(paused) || (paused.danger !== undefined && paused.danger !== "safe")) {
        await release(handoff, "resume");
        return;
      }
      const submitted = await native(payload(item, url, context, handoff, "submit"));
      if (!submitted.ok) await release(handoff, "resume");
    }
  } catch {
    if (handoff && !canceled) {
      if (handoff.fast) {
        // Cancellation and storage can succeed independently if the browser exits mid-handoff.
        const [original] = await api.downloads.search({ id: browserId }).catch(() => []);
        if (original?.state !== "interrupted" || original.error !== "USER_CANCELED") {
          await release(handoff, "abandon").catch(() => {});
        }
      } else {
        await release(handoff, "resume").catch(() => {});
      }
    }
  } finally {
    port?.disconnect();
    if (handoff) schedule();
  }
  return canceled;
}

async function settleFast(job, item, state, returned) {
  const expired = Date.now() - job.started > 8500;
  if (item?.state === "in_progress" || item?.state === "complete") {
    if (expired) await release(job, "abandon");
    return;
  }
  if (state?.state === "completed" || state?.state === "canceled") {
    await release(job, "cancel");
    return;
  }
  const stale = state && !["awaitingConfirmation", "paused"].includes(state.state) &&
    Date.now() - state.updatedAt > 14000;
  if (state?.state !== "failed" && !(expired && (!returned.ok || !state)) && !stale &&
      !(state?.state === "awaitingConfirmation" && returned.appRunning === false)) return;

  if (!job.returningAt) {
    job.returningAt = Date.now();
    await api.storage.local.set({ [prefix + job.browserId]: job });
  }
  const attempts = await api.downloads.search({ url: job.source, startedAfter: new Date(job.returningAt).toISOString() });
  if (!attempts.some(attempt => attempt.byExtensionId === api.runtime.id)) {
    await api.downloads.download({ url: job.source, saveAs: false });
  }
  await release(job, "abandon");
}

async function release(handoff, outcome) {
  if (outcome === "resume" || outcome === "abandon") {
    await native({ action: "abandon", id: handoff.id }).catch(() => {});
  }
  let [item] = await api.downloads.search({ id: handoff.browserId });
  if (heldByExtension(item)) {
    if (outcome === "resume") await api.downloads.resume(handoff.browserId);
    if (outcome === "cancel") {
      await api.downloads.cancel(handoff.browserId);
      [item] = await api.downloads.search({ id: handoff.browserId });
    }
  }
  if (outcome === "cancel" && item?.state === "interrupted" && item.error === "USER_CANCELED") {
    await api.downloads.erase({ id: handoff.browserId });
  }
  await api.storage.local.remove(prefix + handoff.browserId);
  await native({ action: "acknowledge", id: handoff.id }).catch(() => {});
}

async function ensureAlarm() {
  if (!(await api.alarms.get(alarm))) {
    await api.alarms.create(alarm, { periodInMinutes: 0.5 });
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
    const data = await api.storage.local.get(null);
    const jobs = Object.entries(data).filter(([key]) => key.startsWith(prefix)).map(([, job]) => job);
    if (!jobs.length) {
      if (!starting.size) await api.alarms.clear(alarm);
      return;
    }
    await ensureAlarm();
    const returned = await native({ action: "status", ids: jobs.map(job => job.id) })
      .catch(() => ({ ok: false }));
    for (const job of jobs) {
      if (starting.has(job.browserId)) continue;
      try {
        const [item] = await api.downloads.search({ id: job.browserId });
        const state = returned.jobs?.[job.id];
        if (job.fast) {
          await settleFast(job, item, state, returned);
          continue;
        }
        if (!heldByExtension(item)) {
          const committed = state?.state === "completed" || state?.state === "canceled";
          await release(job, committed ? "cancel" : "abandon");
          continue;
        }
        if (item.danger !== undefined && item.danger !== "safe") {
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

function waitForDownload(id, rules) {
  return new Promise(resolve => {
    let finished = false;
    let checking = false;
    const finish = item => {
      if (finished) return;
      finished = true;
      clearInterval(retry);
      clearTimeout(deadline);
      api.downloads.onChanged.removeListener(changed);
      api.downloads.onErased.removeListener(erased);
      resolve(item);
    };
    const check = async () => {
      if (finished || checking) return;
      checking = true;
      const [download] = await api.downloads.search({ id }).catch(() => []);
      checking = false;
      if (finished) return;
      if (!download || download.state !== "in_progress") return finish(null);
      const item = enrichDownload(download);
      const size = Math.max(item.totalBytes ?? 0, item.fileSize ?? 0);
      if (item.filename && (size > 0 || rules.minimumMiB === 0 || isBrowserTest(item, rules))) finish(item);
    };
    const changed = delta => { if (delta.id === id) void check(); };
    const erased = erasedId => { if (erasedId === id) finish(null); };
    // Header capture and onCreated are separate events. A header can arrive
    // without triggering downloads.onChanged, so allow a short retry window.
    const retry = setInterval(() => void check(), 90);
    const deadline = setTimeout(() => finish(null), 1600);
    api.downloads.onChanged.addListener(changed);
    api.downloads.onErased.addListener(erased);
    void check();
  });
}

// Firefox creates the download before it exposes size and filename. Fill the
// gaps from response headers so the same rules can decide, then reuse the
// Chromium pause/submit flow.
function enrichDownload(item) {
  const info = responseInfo(item.finalUrl || item.url) ?? responseInfo(item.url);
  if (!item.mime && info?.contentType) item.mime = info.contentType;
  const size = item.totalBytes > 0 ? item.totalBytes : (item.fileSize > 0 ? item.fileSize : 0);
  if (size <= 0 && info?.contentLength > 0) item.totalBytes = info.contentLength;
  if (!item.filename && info?.filename) item.filename = info.filename;
  if (!item.filename) {
    const url = safeURL(item.finalUrl || item.url);
    const last = url?.pathname.split("/").filter(Boolean).pop();
    if (last) {
      try { item.filename = decodeURIComponent(last); } catch { item.filename = last; }
    }
  }
  return item;
}

if (api.downloads.onDeterminingFilename) {
  api.downloads.onDeterminingFilename.addListener((item, suggest) => {
    if (item.byExtensionId === api.runtime.id || starting.has(item.id)) return false;
    starting.add(item.id);
    void takeOver(item).then(canceled => {
      starting.delete(item.id);
      if (!canceled) suggest();
    }, () => {
      starting.delete(item.id);
      suggest();
    });
    return true;
  });
} else {
  // Firefox has no filename-determination event, so intercept newly created
  // downloads and let the bridge decide before the browser writes much.
  api.downloads.onCreated.addListener(item => {
    if (item.byExtensionId === api.runtime.id || starting.has(item.id)) return;
    starting.add(item.id);
    void currentRules(true).then(async rules => {
      if (!rules.enabled && !isBrowserTest(item, rules)) return;
      const ready = await waitForDownload(item.id, rules);
      if (ready) await takeOver(ready, rules);
    })
      .catch(() => false)
      .finally(() => starting.delete(item.id));
  });
}
api.downloads.onChanged.addListener(delta => {
  if (delta.state || delta.paused) schedule();
});
api.downloads.onErased.addListener(() => schedule());
api.alarms.onAlarm.addListener(event => {
  if (event.name === alarm) void sweep();
});
api.runtime.onStartup.addListener(() => {
  void currentRules(true);
  void sweep();
});
api.runtime.onInstalled.addListener(details => {
  if (details.reason === "update") {
    // VeloDrop 0.5 kept takeover rules in extension storage. The app owns them
    // now; drop the leftover keys so they cannot be mistaken for live state.
    void api.storage.local.remove(["enabled", "minimumMiB", "excludedHosts"]);
  }
  void currentRules(true);
  void sweep();
});
api.runtime.onMessage.addListener((message, _, reply) => {
  if (message.action === "open") {
    native({ action: "open" }).then(reply, () => reply({ ok: false }));
    return true;
  }
  if (message.action !== "ping") return false;
  pingApp().then(reply, () => reply({ ok: false }));
  return true;
});
// Register the bridge early so Settings can show a recent connection even
// before the first download or popup visit.
void currentRules(true);

