export const networkPermissions = {
  origins: ["http://*/*", "https://*/*"],
};

const allowedHeaders = new Set(["accept", "accept-language", "user-agent", "referer", "cookie", "authorization"]);
const recent = new Map();
const maxAge = 15_000;

export function observeBrowserRequests() {
  chrome.permissions.onRemoved.addListener(() => recent.clear());
  if (!chrome.webRequest) return;
  chrome.webRequest.onSendHeaders.addListener(request => {
    if (request.tabId < 0) return;
    const fields = Object.fromEntries((request.requestHeaders ?? [])
      .filter(header => allowedHeaders.has(header.name.toLowerCase()) && typeof header.value === "string")
      .map(header => [header.name.toLowerCase(), header.value]));
    recent.delete(request.requestId);
    recent.set(request.requestId, { url: request.url, method: request.method, fields, at: Date.now() });
    while (recent.size > 128) recent.delete(recent.keys().next().value);
  }, { urls: networkPermissions.origins, types: ["main_frame", "sub_frame", "xmlhttprequest", "other"] },
  ["requestHeaders", "extraHeaders"]);
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
    // Chromium only compares IP ranges to literal IPs. Keep ambiguous ranges in Edge.
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

async function browserProxy(url) {
  if (!chrome.proxy?.settings) return { mode: "system" };
  const { value } = await chrome.proxy.settings.get({ incognito: false });
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

export async function requestContext(item, url) {
  const granted = await chrome.permissions.contains(networkPermissions);
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
