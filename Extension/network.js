import { api, isGecko } from "./api.js";

export const networkPermissions = {
  origins: ["http://*/*", "https://*/*"],
};

const allowedHeaders = new Set(["accept", "accept-language", "user-agent", "referer", "cookie", "authorization"]);
const recent = new Map();
const maxAge = 15_000;

export function observeBrowserRequests(reuseEnabled = () => true) {
  if (!api.webRequest) return;
  const capture = request => {
    if (!reuseEnabled() || request.tabId < 0) return;
    const fields = Object.fromEntries((request.requestHeaders ?? [])
      .filter(header => allowedHeaders.has(header.name.toLowerCase()) && typeof header.value === "string")
      .map(header => [header.name.toLowerCase(), header.value]));
    recent.delete(request.requestId);
    recent.set(request.requestId, { url: request.url, method: request.method, fields, at: Date.now() });
    while (recent.size > 128) recent.delete(recent.keys().next().value);
  };
  let revision = 0;
  const refresh = async () => {
    const current = ++revision;
    const granted = await api.permissions.contains(networkPermissions);
    if (current !== revision) return;
    const event = api.webRequest.onSendHeaders;
    if (granted && !event.hasListener(capture)) {
      const extra = ["requestHeaders"];
      // `extraHeaders` is Chromium-only; Firefox rejects the listener otherwise.
      if (!isGecko) extra.push("extraHeaders");
      event.addListener(capture,
        { urls: networkPermissions.origins, types: ["main_frame", "sub_frame", "xmlhttprequest", "other"] },
        extra);
    } else if (!granted) {
      event.removeListener(capture);
      recent.clear();
    }
  };
  api.permissions.onAdded.addListener(() => void refresh());
  api.permissions.onRemoved.addListener(() => void refresh());
  void refresh();
}

const responses = new Map();
const responseMaxAge = 20_000;

function filenameFromDisposition(value) {
  if (typeof value !== "string") return null;
  const encoded = /filename\*\s*=\s*(?:UTF-8'')?([^;]+)/i.exec(value);
  if (encoded) {
    try { return decodeURIComponent(encoded[1].trim().replace(/^"|"$/g, "")); } catch { /* use plain form */ }
  }
  const plain = /filename\s*=\s*"?([^";]+)"?/i.exec(value);
  return plain ? plain[1].trim() : null;
}

/// Firefox has no downloads.onDeterminingFilename, so the worker decides
/// eligibility from response metadata captured before the download starts.
export function observeResponses() {
  if (!isGecko || !api.webRequest?.onHeadersReceived) return;
  const capture = details => {
    const info = { at: Date.now() };
    for (const header of details.responseHeaders ?? []) {
      const name = header.name.toLowerCase();
      if (name === "content-length") {
        const value = Number(header.value);
        if (Number.isFinite(value) && value > 0) info.contentLength = value;
      } else if (name === "content-type") {
        info.contentType = header.value.split(";")[0].trim().toLowerCase();
      } else if (name === "content-disposition") {
        info.filename = filenameFromDisposition(header.value) ?? info.filename;
      }
    }
    if (!info.contentLength && !info.contentType && !info.filename) return;
    responses.delete(details.url);
    responses.set(details.url, info);
    while (responses.size > 64) responses.delete(responses.keys().next().value);
  };
  api.webRequest.onHeadersReceived.addListener(capture, {
    urls: networkPermissions.origins,
    types: ["main_frame", "sub_frame", "object", "other", "xmlhttprequest"],
  }, ["responseHeaders"]);
}

export function responseInfo(url) {
  const info = responses.get(url);
  if (!info) return null;
  if (Date.now() - info.at > responseMaxAge) {
    responses.delete(url);
    return null;
  }
  return info;
}

function takeRecent(url) {
  let result;
  for (const [id, entry] of recent) {
    if (Date.now() - entry.at > maxAge) {
      recent.delete(id);
      continue;
    }
    if (entry.url !== url) continue;
    recent.delete(id);
    if (result && (entry.method !== result.method ||
        Object.keys(entry.fields).some(key => entry.fields[key] !== result.fields[key]) ||
        Object.keys(result.fields).some(key => result.fields[key] !== entry.fields[key]))) {
      return { ambiguous: true };
    }
    result = entry;
  }
  return result;
}

function matchesBypass(url, entry) {
  let rule = entry.trim().toLowerCase();
  if (!rule || rule === "<-loopback>") return false;
  if (rule === "<local>") return !/[.:]/.test(url.hostname);
  const scheme = /^([a-z]+):\/\//.exec(rule);
  if (scheme) {
    if (url.protocol !== scheme[1] + ":") return false;
    rule = rule.slice(scheme[0].length);
  }
  if (rule.includes("/")) {
    // Chromium only compares IP ranges to literal IPs. Keep ambiguous ranges in the browser.
    return /^(\[|[\d.]+$)/.test(url.hostname) ? null : false;
  }
  const port = /:(\d+)$/.exec(rule);
  if (port && !rule.endsWith("]")) {
    if ((url.port || (url.protocol === "https:" ? "443" : "80")) !== port[1]) return false;
    rule = rule.slice(0, -port[0].length);
  }
  if (rule.startsWith(".")) rule = "*" + rule;
  const escaped = rule.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp("^" + escaped + "$", "i").test(url.hostname);
}

function proxyEndpoint(value) {
  let server = value.trim();
  if (!server) return null;
  if (!/^[a-z]+:\/\//i.test(server)) server = "http://" + server;
  let url;
  try { url = new URL(server); } catch { return null; }
  if (url.protocol !== "http:" || !url.hostname) return null;
  const host = url.hostname.includes(":") && !url.hostname.startsWith("[")
    ? "[" + url.hostname + "]" : url.hostname;
  return "http://" + host + ":" + (url.port || "80");
}

// Firefox reports proxyType/rules instead of the Chromium mode/rules shape.
function firefoxProxy(url, value) {
  if (value.proxyType === "none") return { mode: "direct" };
  if (value.proxyType === "system") return { mode: "system" };
  if (value.proxyType !== "manual") return null;
  const bypass = (value.passthrough ?? "").split(/[\s,]+/).filter(Boolean);
  if (!bypass.includes("<-loopback>") &&
      /(^|\.)localhost\.?$|^127(?:\.\d{1,3}){3}$|^\[::1\]$|^169\.254(?:\.\d{1,3}){2}$|^\[fe[89ab]/i.test(url.hostname)) {
    return { mode: "direct" };
  }
  const matches = bypass.map(rule => matchesBypass(url, rule));
  if (matches.includes(true)) return { mode: "direct" };
  if (matches.includes(null)) return null;
  const server = proxyEndpoint(url.protocol === "https:" ? (value.sslProxy ?? "") : (value.httpProxy ?? ""));
  if (!server) return { mode: "direct" };
  return { mode: "fixed", endpoint: server };
}

async function browserProxy(url) {
  if (!api.proxy?.settings) return { mode: "system" };
  const { value } = await api.proxy.settings.get({ incognito: false });
  if (value.proxyType !== undefined) return firefoxProxy(url, value);
  if (value.mode === "system" || value.mode === "direct") return { mode: value.mode };
  if (value.mode !== "fixed_servers") return null;
  const rules = value.rules;
  if (!rules) return null;
  const bypass = rules.bypassList ?? [];
  if (!bypass.includes("<-loopback>") &&
      /(^|\.)localhost\.?$|^127(?:\.\d{1,3}){3}$|^\[::1\]$|^169\.254(?:\.\d{1,3}){2}$|^\[fe[89ab]/i.test(url.hostname)) {
    return { mode: "direct" };
  }
  const matches = bypass.map(rule => matchesBypass(url, rule));
  if (matches.includes(true)) return { mode: "direct" };
  if (matches.includes(null)) return null;

  const server = rules.singleProxy ?? (url.protocol === "https:" ? rules.proxyForHttps : rules.proxyForHttp) ??
    rules.fallbackProxy;
  if (!server) return { mode: "direct" };
  if ((server.scheme ?? "http") !== "http") return null;
  const host = server.host.includes(":") && !server.host.startsWith("[") ? "[" + server.host + "]" : server.host;
  const endpoint = "http://" + host + ":" + (server.port ?? 80);
  return { mode: "fixed", endpoint };
}

export async function requestContext(item, url, reuseHeaders = true) {
  const granted = reuseHeaders && await api.permissions.contains(networkPermissions);
  const final = granted ? takeRecent(url.href) : undefined;
  const initial = item.url === url.href ? final : (granted ? takeRecent(item.url) : undefined);
  if (final?.ambiguous || initial?.ambiguous ||
      (final && final.method !== "GET") || (initial && initial.method !== "GET")) return null;
  const proxy = await browserProxy(url);
  if (!proxy) return null;
  const headers = { "user-agent": navigator.userAgent, ...(final?.fields ?? {}) };
  if (!headers.referer && item.referrer && item.url === url.href) {
    let referer;
    try { referer = new URL(item.referrer); } catch { return { headers, proxy }; }
    if (["http:", "https:"].includes(referer.protocol) && !referer.username && !referer.password) {
      if (referer.origin === url.origin) {
        // Browser history may expose a broader page URL than its actual Referer policy.
        headers.referer = referer.origin + "/";
      }
    }
  }
  return { headers, proxy, method: initial?.method };
}

export function normalizedHost(input) {
  try {
    const value = input.trim().replace(/^\*?\./, "");
    const url = new URL(value.includes("://") ? value : "https://" + value);
    return ["http:", "https:"].includes(url.protocol) ? url.hostname.toLowerCase().replace(/\.$/, "") : "";
  } catch {
    return "";
  }
}
