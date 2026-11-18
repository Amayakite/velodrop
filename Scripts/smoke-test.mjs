import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const app = resolve(process.argv[2] ?? ".dist/VeloDrop.app");
const edge = process.env.VELODROP_EDGE ?? "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge";
const here = mkdtempSync(join(tmpdir(), "velodrop-smoke-"));
const profile = join(here, "edge");
const home = join(here, "app-data");
const nativeDownloads = join(here, "native");
const edgeDownloads = join(here, "browser");
const env = { ...process.env, VELODROP_DATA: home, VELODROP_DESTINATION: nativeDownloads };
const smokeLocale = process.env.VELODROP_SMOKE_LOCALE;
const appLog = [];
const edgeLog = [];
const calls = [];
let liveParallelRequests = 0;
let peakParallelRequests = 0;
const downloadSize = 28 * 1024 * 1024;
const payload = Buffer.alloc(downloadSize);
for (let i = 0; i < payload.length; i++) payload[i] = i % 251;
const digest = createHash("sha256").update(payload).digest("hex");

function child(binary, args, options, output) {
  const process = spawn(binary, args, options);
  process.stderr?.on("data", data => output.push(String(data)));
  process.on("error", error => output.push(String(error)));
  return process;
}

const fixture = createServer((request, response) => {
  if (request.url === "/") {
    response.writeHead(200, { "Content-Type": "text/html" });
    response.end("<!doctype html><title>VeloDrop smoke fixture</title>");
    return;
  }

  const route = request.url.slice(1);
  if (!["parallel.zip", "fallback.zip", "bridge-unavailable.zip", "restart.zip"].includes(route)) {
    response.writeHead(404).end();
    return;
  }
  const browser = !request.headers["user-agent"]?.includes("aria2");
  const match = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range ?? "");
  calls.push({ route, browser, range: request.headers.range, since: Date.now() });
  if (route === "parallel.zip" && !browser) {
    liveParallelRequests += 1;
    peakParallelRequests = Math.max(peakParallelRequests, liveParallelRequests);
    response.once("close", () => { liveParallelRequests -= 1; });
  }
  if (route === "fallback.zip" && !browser) {
    response.writeHead(403).end();
    return;
  }
  const headers = {
    "Content-Type": "application/zip",
    "Content-Disposition": "attachment; filename=" + route,
    "Accept-Ranges": "bytes",
    "ETag": '"download-v1"',
  };
  const start = match ? Number(match[1]) : 0;
  const end = match?.[2] ? Math.min(Number(match[2]), payload.length - 1) : payload.length - 1;
  if (start > end) {
    response.writeHead(416, { "Content-Range": "bytes */" + payload.length }).end();
    return;
  }
  headers["Content-Length"] = end - start + 1;
  if (match) headers["Content-Range"] = `bytes ${start}-${end}/${payload.length}`;
  response.writeHead(match ? 206 : 200, headers);
  let offset = start;
  const timer = setInterval(() => {
    const next = Math.min(end + 1, offset + 128 * 1024);
    if (next > offset) response.write(payload.subarray(offset, next));
    offset = next;
    if (offset > end) {
      clearInterval(timer);
      response.end();
    }
  }, route === "restart.zip" ? 65 : 24);
  response.on("close", () => clearInterval(timer));
});

function records() {
  const dir = join(home, "Transfers");
  if (!existsSync(dir)) return [];
  return readdirSync(dir).filter(name => name.endsWith(".json"))
    .map(name => JSON.parse(readFileSync(join(dir, name), "utf8")));
}

async function waitFor(label, evaluate, timeout = 25_000) {
  const until = Date.now() + timeout;
  while (Date.now() < until) {
    const result = await evaluate();
    if (result) return result;
    await sleep(100);
  }
  throw new Error("Timed out waiting for " + label);
}

function sha256(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

async function shutdown(process) {
  if (!process || process.exitCode !== null || process.signalCode !== null) return;
  process.kill("SIGTERM");
  await Promise.race([new Promise(resolve => process.once("exit", resolve)), sleep(2500)]);
  if (process.exitCode === null && process.signalCode === null) process.kill("SIGKILL");
}

function nativeMessage(request) {
  const body = Buffer.from(JSON.stringify(request));
  const length = Buffer.alloc(4);
  length.writeUInt32LE(body.length);
  const raw = execFileSync(join(app, "Contents/Helpers/VeloBridge"), [], {
    input: Buffer.concat([length, body]), env,
  });
  assert.equal(raw.readUInt32LE(0), raw.length - 4);
  return JSON.parse(raw.subarray(4));
}

class CDP {
  sequence = 0;
  pending = new Map();
  buffer = "";

  constructor(browser) {
    this.browser = browser;
    this.input = browser.stdio[3];
    browser.stdio[4].setEncoding("utf8").on("data", data => {
      this.buffer += data;
      const messages = this.buffer.split("\0");
      this.buffer = messages.pop();
      for (const message of messages) {
        const reply = JSON.parse(message);
        this.pending.get(reply.id)?.(reply);
      }
    });
  }

  async send(method, params = {}, sessionId) {
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(method + " did not respond"));
      }, 9000);
      this.pending.set(id, reply => {
        clearTimeout(timer);
        this.pending.delete(id);
        if (reply.error) reject(new Error(method + " " + reply.error.message));
        else resolve(reply.result);
      });
      this.input.write(JSON.stringify({ id, method, params, sessionId }) + "\0");
    });
  }

  async tab(url) {
    const { targetId } = await this.send("Target.createTarget", { url });
    const { sessionId } = await this.send("Target.attachToTarget", { targetId, flatten: true });
    return sessionId;
  }

  async run(session, expression) {
    const reply = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, session);
    if (reply.exceptionDetails) throw new Error(reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text);
    return reply.result.value;
  }
}

const desktopBinary = join(app, "Contents/MacOS/VeloDrop");
function runningDesktop() {
  const list = execFileSync("ps", ["-axo", "pid=,comm="], { encoding: "utf8" });
  for (const line of list.split("\n")) {
    const match = /^\s*(\d+)\s+(.+)$/.exec(line);
    if (match?.[2] === desktopBinary) return Number(match[1]);
  }
  return null;
}

let desktop;
let launchedDesktop;
let requestedDesktopLaunch = false;
let browser;
try {
  assert.ok(existsSync(edge), "Microsoft Edge is required for the browser smoke test.");
  assert.ok(existsSync(app), "Run Scripts/package.sh before testing.");
  await new Promise(resolve => fixture.listen(0, "127.0.0.1", resolve));
  const base = "http://127.0.0.1:" + fixture.address().port;
  const extension = join(app, "Contents/Resources/EdgeExtension");
  const manifest = JSON.parse(readFileSync(join(extension, "manifest.json")));
  const id = createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest("hex").slice(0, 32)
    .replace(/[0-9a-f]/g, value => String.fromCharCode(97 + parseInt(value, 16)));

  const hostDir = join(profile, "NativeMessagingHosts");
  mkdirSync(hostDir, { recursive: true });
  const hostManifest = join(hostDir, "com.amayakite.velodrop.json");
  writeFileSync(hostManifest, JSON.stringify({
    name: "com.amayakite.velodrop",
    description: "VeloDrop smoke test",
    type: "stdio",
    path: join(app, "Contents/Helpers/VeloBridge"),
    allowed_origins: ["chrome-extension://" + id + "/"],
  }));

  const startDesktop = () => child(desktopBinary, [], { env }, appLog);
  assert.equal(runningDesktop(), null, "Quit the packaged test build before running this test.");
  assert.equal(nativeMessage({ action: "ping" }).ok, true);

  browser = child(edge, [
    "--headless=new", "--no-first-run", "--no-default-browser-check", "--disable-background-networking",
    "--remote-debugging-pipe", "--enable-unsafe-extension-debugging", "--user-data-dir=" + profile,
    "--load-extension=" + extension,
    ...(smokeLocale ? ["--lang=" + smokeLocale, "-AppleLanguages", "(" + smokeLocale + ")"] : []),
  ], { env, stdio: ["ignore", "ignore", "pipe", "pipe", "pipe"] }, edgeLog);
  const cdp = new CDP(browser);
  await cdp.send("Browser.getVersion");
  let loaded;
  try {
    loaded = await cdp.send("Extensions.loadUnpacked", { path: extension });
  } catch (error) {
    console.log(String(error));
  }
  assert.ok(!loaded || loaded.id === id, "Native host matches the ID loaded by Edge.");
  await cdp.send("Browser.setDownloadBehavior", { behavior: "allow", downloadPath: edgeDownloads });
  const page = await cdp.tab(base);
  const popup = await cdp.tab("chrome-extension://" + id + "/popup.html");
  await waitFor("Edge extension connection", async () =>
    (await cdp.run(popup, 'document.querySelector("#status")?.dataset.connected')) === "true", 6000);
  const popupLabels = await cdp.run(popup, `({
    language: document.documentElement.lang,
    autoTakeover: document.querySelector("[data-message=autoTakeover]").textContent,
    connection: document.querySelector("#status").textContent,
  })`);
  if (smokeLocale) assert.equal(popupLabels.language, smokeLocale);
  if (popupLabels.language === "zh-CN") {
    assert.equal(popupLabels.autoTakeover, "自动接管下载");
    assert.equal(popupLabels.connection, "已连接到 VeloDrop");
  } else if (popupLabels.language.startsWith("en")) {
    assert.equal(popupLabels.autoTakeover, "Automatically take over downloads");
    assert.equal(popupLabels.connection, "Connected to your Mac");
  } else {
    assert.ok(popupLabels.autoTakeover && popupLabels.connection);
  }
  console.log("Edge extension loaded and connected to the native host (" + popupLabels.language + ").");

  const start = route => cdp.run(page, `(() => {
    const link = document.createElement("a"); link.href = ${JSON.stringify(base + "/" + route)};
    document.body.appendChild(link); link.click(); link.remove(); return true;
  })()`);
  const browserState = route => cdp.run(popup, `chrome.downloads.search({}).then(
    items => items.find(item => item.url.endsWith(${JSON.stringify("/" + route)})))
  `);

  requestedDesktopLaunch = true;
  await start("parallel.zip");
  launchedDesktop = await waitFor("Edge starting the desktop app", runningDesktop);
  await waitFor("Edge held in reserve", async () => (await browserState("parallel.zip"))?.paused);
  await waitFor("segmented download", () => new Set(calls.filter(
    call => call.route === "parallel.zip" && !call.browser && call.range).map(call => call.range)).size >= 2);
  await waitFor("downloaded file", () => records().some(item => item.name === "parallel.zip" && item.state === "completed"));
  await waitFor("Edge cancellation after save", async () => (await browserState("parallel.zip"))?.state === "interrupted");
  assert.ok(peakParallelRequests >= 2, "Segment requests overlap in time.");
  assert.equal(sha256(join(nativeDownloads, "parallel.zip")), digest);
  assert.equal(existsSync(join(edgeDownloads, "parallel.zip")), false);
  console.log(`Edge launched VeloDrop, aria2 used ${peakParallelRequests} concurrent requests, and the final SHA-256 matched.`);

  await start("fallback.zip");
  await waitFor("aria2 rejection", () => calls.some(call => call.route === "fallback.zip" && !call.browser));
  await waitFor("Edge resumed the original request", async () => (await browserState("fallback.zip"))?.state === "complete");
  assert.equal(sha256(join(edgeDownloads, "fallback.zip")), digest);
  assert.equal(existsSync(join(nativeDownloads, "fallback.zip")), false);
  assert.ok(records().some(item => item.name === "fallback.zip" && item.state === "failed"));
  console.log("After the server rejected aria2, Edge resumed the same download and saved identical bytes.");

  const restartID = crypto.randomUUID();
  assert.equal(nativeMessage({
    action: "submit", id: restartID, name: "restart.zip", size: downloadSize, url: base + "/restart.zip",
  }).ok, true);
  await waitFor("persisted partial data", () => records().some(item => item.name === "restart.zip" && item.received > 2 * 1024 * 1024));
  process.kill(launchedDesktop, "SIGTERM");
  await waitFor("desktop exit", () => runningDesktop() === null);
  launchedDesktop = undefined;
  const startOfRestart = Date.now();
  desktop = startDesktop();
  await waitFor("resume after relaunch", () => records().some(item => item.name === "restart.zip" && item.state === "completed"));
  assert.ok(calls.some(call => call.route === "restart.zip" && !call.browser &&
    call.since >= startOfRestart && /^bytes=[1-9]/.test(call.range ?? "")));
  assert.equal(sha256(join(nativeDownloads, "restart.zip")), digest);
  console.log("Relaunch resumed the partial file using nonzero range offsets; SHA-256 matched.");

  rmSync(hostManifest);
  await start("bridge-unavailable.zip");
  await waitFor("Edge download without the native host", async () =>
    (await browserState("bridge-unavailable.zip"))?.state === "complete");
  assert.equal(statSync(join(edgeDownloads, "bridge-unavailable.zip")).size, downloadSize);
  assert.equal(calls.some(call => call.route === "bridge-unavailable.zip" && !call.browser), false);
  console.log("Without the native host, Edge completed the file on its own.");

  await waitFor("idle aria2 process exit", () => {
    const processList = execFileSync("ps", ["-axo", "ppid,comm"], { encoding: "utf8" });
    return !processList.split("\n").some(line => new RegExp("^\\s*" + desktop.pid + "\\s+.*aria2c$").test(line));
  });
  const usage = execFileSync("ps", ["-o", "rss=,pcpu=", "-p", String(desktop.pid)], { encoding: "utf8" }).trim().split(/\s+/);
  const memory = execFileSync("footprint", ["-p", String(desktop.pid)], { encoding: "utf8" })
    .split("\n").find(line => line.includes("Footprint:"))?.match(/Footprint: (.+?) \(/)?.[1];
  console.log(`Idle app: physical footprint ${memory ?? "unavailable"}, RSS ${(Number(usage[0]) / 1024).toFixed(1)} MiB, sampled CPU ${usage[1]}%; no aria2 child.`);
} catch (error) {
  console.error(error);
  for (const directory of ["Inbox", "Abandoned", "Transfers"]) {
    const path = join(home, directory);
    if (existsSync(path)) console.error(directory + ":", readdirSync(path));
  }
  console.error("Native states:", records().map(item => ({ name: item.name, state: item.state, message: item.message })));
  console.error("Fixture requests:", calls.slice(-22));
  console.error("Desktop:", appLog.join("").slice(-3000));
  console.error("Edge:", edgeLog.join("").slice(-3000));
  process.exitCode = 1;
} finally {
  await shutdown(browser);
  await shutdown(desktop);
  const activeLaunch = launchedDesktop ?? (requestedDesktopLaunch && !desktop ? runningDesktop() : null);
  if (activeLaunch && runningDesktop() === activeLaunch) process.kill(activeLaunch, "SIGTERM");
  fixture.closeAllConnections();
  fixture.close();
  rmSync(here, { recursive: true, force: true });
}
