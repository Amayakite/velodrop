import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { homedir, tmpdir } from "node:os";
import { setTimeout as sleep } from "node:timers/promises";

const args = process.argv.slice(2);
const app = resolve(args[0] ?? ".dist/VeloDrop.app");
const driver = process.env.VELODROP_GECKODRIVER ?? "geckodriver";
const browser = process.env.VELODROP_BROWSER_BINARY ?? "/Applications/Firefox.app/Contents/MacOS/firefox";
const review = mkdtempSync(join(tmpdir(), "velodrop-firefox-smoke-"));
const data = join(review, "data");
const nativeFiles = join(review, "native");
const browserFiles = join(review, "browser");
for (const folder of [data, nativeFiles, browserFiles]) mkdirSync(folder);
const env = { ...process.env, VELODROP_DATA: data, VELODROP_DESTINATION: nativeFiles, VELODROP_TEST_NO_LAUNCH: "1" };
const rules = { enabled: true, minimumMiB: 2, excludedHosts: "", reuseSessionHeaders: true };
const writeRules = change => writeFileSync(join(data, "browser-rules.json"), JSON.stringify({ ...rules, ...change }));
writeRules({});
const payload = Buffer.alloc(8 * 1024 * 1024);
for (let i = 0; i < payload.length; i++) payload[i] = i % 251;
const digest = bytes => createHash("sha256").update(bytes).digest("hex");
const extension = join(review, "extension");
const hostName = "com.amayakite.velodrop.smoke_" + crypto.randomUUID().replaceAll("-", "");
const hostDir = join(homedir(), "Library/Application Support/Mozilla/NativeMessagingHosts");
const hostFile = join(hostDir, hostName + ".json");
const driverLog = [];
const events = [];
let rejectSignedDownload;
const routes = [
  "public.zip", "cookie.zip", "signed.zip?ticket=fixture", "one-shot.zip?ticket=fixture",
  "excluded.zip", "small.zip", "disabled.zip",
];
const fixture = createServer((req, res) => {
  const parsed = new URL(req.url, "http://127.0.0.1");
  if (parsed.pathname === "/") {
    res.setHeader("Content-Type", "text/html");
    res.setHeader("Set-Cookie", "vd_fixture=allowed; Path=/; SameSite=Lax");
    res.end("<title>VeloDrop Firefox isolated test</title>" +
      routes.map((route, i) => '<a id="route' + i + '" href="/' + route + '">' + route + '</a><br>').join(""));
    return;
  }
  const filename = parsed.pathname.slice(1);
  if (!routes.some(route => route.split("?")[0] === filename)) {
    res.writeHead(404).end();
    return;
  }
  const native = Boolean(req.headers["want-digest"]);
  const withCookie = req.headers.cookie?.includes("vd_fixture=allowed") ?? false;
  events.push({ filename, native, withCookie, range: req.headers.range, at: Date.now() });
  if (filename === "signed.zip" && native) {
    rejectSignedDownload = () => res.writeHead(403).end();
    return;
  }
  if (filename === "cookie.zip" && !withCookie) {
    res.writeHead(403).end();
    return;
  }
  const bytes = filename === "small.zip" ? payload.subarray(0, 128 * 1024) : payload;
  const parts = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range ?? "");
  const start = parts ? Number(parts[1]) : 0;
  const end = parts?.[2] ? Math.min(bytes.length - 1, Number(parts[2])) : bytes.length - 1;
  if (start > end) {
    res.writeHead(416, { "Content-Range": "bytes */" + bytes.length }).end();
    return;
  }
  res.writeHead(parts ? 206 : 200, {
    "Content-Type": "application/zip",
    "Content-Disposition": 'attachment; filename="' + filename + '"',
    "Content-Length": end - start + 1,
    "Accept-Ranges": filename === "one-shot.zip" ? "none" : "bytes",
    "ETag": '"velodrop-fixture"',
    ...(parts ? { "Content-Range": "bytes " + start + "-" + end + "/" + bytes.length } : {}),
  });
  let offset = start;
  const timer = setInterval(() => {
    const next = Math.min(offset + 96 * 1024, end + 1);
    res.write(bytes.subarray(offset, next));
    offset = next;
    if (offset > end) { clearInterval(timer); res.end(); }
  }, native ? 14 : 46);
  res.once("close", () => clearInterval(timer));
});

async function until(label, condition, ms = 18_000) {
  const end = Date.now() + ms;
  let lastError;
  while (Date.now() < end) {
    try {
      const result = await condition();
      if (result) return result;
    } catch (error) { lastError = error; }
    await sleep(100);
  }
  throw new Error("Timed out: " + label, { cause: lastError });
}

function records() {
  const folder = join(data, "Transfers");
  if (!existsSync(folder)) return [];
  return readdirSync(folder).filter(file => file.endsWith(".json"))
    .map(file => JSON.parse(readFileSync(join(folder, file))));
}

function bytesMatch(directory, filename, expected = payload) {
  const path = join(directory, filename);
  return existsSync(path) && digest(readFileSync(path)) === digest(expected);
}

let desktop;
let gecko;
let session;
let url;
let fixtureTab;
let popupTab;
async function request(method, endpoint, body) {
  const result = await fetch(url + endpoint, {
    method, headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  });
  const json = await result.json();
  if (!result.ok) throw new Error(JSON.stringify(json.value));
  return json.value;
}
const command = (method, endpoint, body) => request(method, "/session/" + session + endpoint, body);
const script = (js, args = []) => command("POST", "/execute/sync", { script: js, args });
const asyncScript = (js, args = []) => command("POST", "/execute/async", { script: js, args });
const select = handle => command("POST", "/window", { handle });
async function downloads(filename) {
  await select(popupTab);
  const rows = await asyncScript(`
    const filename = arguments[0];
    const done = arguments[arguments.length - 1];
    const api = window.browser ?? window.wrappedJSObject?.browser;
    api.downloads.search({}).then(items => done(items
      .filter(item => new URL(item.url).pathname === "/" + filename)
      .map(({ id, state, paused }) => ({ id, state, paused }))), error => done(String(error)));
  `, [filename]);
  assert.ok(Array.isArray(rows), String(rows));
  return rows;
}
async function start(filename) {
  await select(fixtureTab);
  const element = await command("POST", "/element", { using: "css selector", value: "#route" + routes.indexOf(filename) });
  const id = Object.values(element)[0];
  await command("POST", "/element/" + id + "/click", {});
}
try {
  assert.ok(existsSync(browser), "Firefox is required for the browser smoke test.");
  // Firefox finds hosts in a user-level directory. Give this disposable profile
  // its own name and leave any installed VeloDrop connector intact.
  cpSync(join(app, "Contents/Resources/VeloDropFirefoxExtension"), extension, { recursive: true });
  const manifest = JSON.parse(readFileSync(join(extension, "manifest.json")));
  assert.equal(manifest.name, "VeloDrop");
  const addonId = manifest.browser_specific_settings.gecko.id;
  const worker = join(extension, "worker.js");
  const original = readFileSync(worker, "utf8");
  const adapted = original.replace('const host = "com.amayakite.velodrop";', 'const host = "' + hostName + '";');
  assert.notEqual(adapted, original, "Use only the test's temporary host.");
  writeFileSync(worker, adapted);
  mkdirSync(hostDir, { recursive: true });
  writeFileSync(hostFile, JSON.stringify({
    name: hostName, description: "VeloDrop Firefox smoke test", type: "stdio",
    path: join(app, "Contents/Helpers/VeloBridge"), allowed_extensions: [addonId],
  }), { flag: "wx" });
  await new Promise(resolve => fixture.listen(0, "127.0.0.1", resolve));
  const base = "http://127.0.0.1:" + fixture.address().port;
  const portLease = createServer();
  await new Promise(resolve => portLease.listen(0, "127.0.0.1", resolve));
  const port = portLease.address().port;
  await new Promise(resolve => portLease.close(resolve));
  url = "http://127.0.0.1:" + port;
  desktop = spawn(join(app, "Contents/MacOS/VeloDrop"), [
    "-confirmBrowserDownloads", "NO", "-showWindowOnCapture", "NO", "-welcomeCompleted", "YES",
    "-browserTakeoverEnabled", "YES", "-browserMinimumMiB", "2", "-browserExcludedHosts", "",
    "-browserReuseSessionHeaders", "YES", "-maxConnections", "4",
  ], { env: {...env, VELODROP_BACKGROUND_LAUNCH: "1"}, stdio: "ignore" });
  await until("desktop state folders", () => existsSync(join(data, "app.lock")));
  gecko = spawn(driver, ["--port", String(port), "--allow-system-access"], { env: {...env, MOZ_REMOTE_ALLOW_SYSTEM_ACCESS: "1"}, stdio: ["ignore", "pipe", "pipe"] });
  for (const stream of [gecko.stdout, gecko.stderr]) stream.on("data", d => driverLog.push(String(d)));
  await until("geckodriver startup", () => request("GET", "/status"));
  const started = await request("POST", "/session", {
    capabilities: { alwaysMatch: { browserName: "firefox", "moz:firefoxOptions": {
      binary: browser,
      args: ["-headless", "-no-remote"],
      prefs: {
        "browser.download.folderList": 2, "browser.download.dir": browserFiles,
        "browser.download.useDownloadDir": true, "browser.download.always_ask_before_handling_new_types": false,
        "browser.helperApps.neverAsk.saveToDisk": "application/zip,application/octet-stream",
        "browser.download.alwaysOpenPanel": false, "network.proxy.type": 0,
      },
    } } },
  });
  session = started.sessionId;
  console.log("Firefox", started.capabilities.browserVersion);
  const archive = join(review, "velodrop-test.xpi");
  execFileSync("/usr/bin/zip", ["-q", "-r", archive, "."], { cwd: extension });
  const loaded = await command("POST", "/moz/addon/install", { path: archive, temporary: true });
  assert.equal(loaded, addonId);
  await command("POST", "/moz/context", { context: "chrome" });
  const popupUrl = await script("return WebExtensionPolicy.getByID(arguments[0]).getURL('popup.html');", [addonId]);
  await command("POST", "/moz/context", { context: "content" });
  fixtureTab = await command("GET", "/window");
  await command("POST", "/url", { url: base + "/" });
  popupTab = (await command("POST", "/window/new", { type: "tab" })).handle;
  await select(popupTab);
  await command("POST", "/moz/context", { context: "chrome" });
  await script("gBrowser.selectedBrowser.loadURI(Services.io.newURI(arguments[0]), {triggeringPrincipal:Services.scriptSecurityManager.getSystemPrincipal()});", [popupUrl]);
  await command("POST", "/moz/context", { context: "content" });
  await until("Firefox add-on connected to native host", () => script("return document.querySelector('#status').dataset.connected === 'true'"));
  const connection = JSON.parse(readFileSync(join(data, "Browsers", "firefox-connection.json")));
  assert.equal(connection.extensionVersion, manifest.version);
  console.log("Firefox temporary extension connected to VeloDrop.");

  for (const filename of ["public.zip", "cookie.zip"]) {
    await start(filename);
    const record = await until("native download for " + filename, () => records()
      .find(item => item.name === filename && item.state === "completed"));
    assert.equal(record.sourceBrowser, "firefox");
    assert.ok(bytesMatch(nativeFiles, filename));
    assert.ok(!existsSync(join(browserFiles, filename)));
    await until("original Firefox item removed", async () => (await downloads(filename)).length === 0);
    if (filename === "cookie.zip") {
      assert.ok(record.browserHeaderNames.includes("Cookie"));
      assert.ok(!JSON.stringify(record).includes("vd_fixture"));
    }
  }
  console.log("Firefox delivered normal and authenticated downloads. SHA-256 matched both.");

  await start("signed.zip?ticket=fixture");
  const paused = await until("original signed download paused", async () => (await downloads("signed.zip")).find(item => item.paused));
  await until("native download request received", () => rejectSignedDownload);
  rejectSignedDownload();
  await until("same Firefox item completed", async () => (await downloads("signed.zip")).find(item => item.id === paused.id && item.state === "complete"));
  assert.ok(events.some(event => event.filename === "signed.zip" && event.native));
  assert.ok(bytesMatch(browserFiles, "signed.zip"));
  assert.ok(!existsSync(join(nativeFiles, "signed.zip")));
  console.log("After a native rejection, Firefox resumed the original signed URL and saved matching bytes.");

  for (const [filename, change, expected] of [
    ["one-shot.zip?ticket=fixture", {}, payload],
    ["excluded.zip", { excludedHosts: "127.0.0.1" }, payload],
    ["small.zip", {}, payload.subarray(0, 128 * 1024)],
    ["disabled.zip", { enabled: false }, payload],
  ]) {
    writeRules(change);
    await start(filename);
    const name = filename.split("?")[0];
    await until("browser download for " + name, () => bytesMatch(browserFiles, name, expected));
    assert.ok(!records().some(item => item.name === name));
    assert.ok(!events.some(event => event.filename === name && event.native));
  }
  console.log("Non-resumable signed downloads, host exclusions, size threshold, and disabled takeover left downloads in Firefox.");
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  if (session) await request("DELETE", "/session/" + session).catch(() => {});
  gecko?.kill();
  desktop?.kill();
  rmSync(hostFile, { force: true });
  fixture.closeAllConnections();
  fixture.close();
  if (process.exitCode) {
    console.error("Gecko driver:", driverLog.join("").slice(-2000));
    console.error("Records:", records().map(({ name, state, message }) => ({ name, state, message })));
    console.error("Fixture:", events.slice(-20));
  }
  rmSync(review, { recursive: true, force: true });
}
