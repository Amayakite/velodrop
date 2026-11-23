import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

const packaged = resolve(process.argv[2] ?? ".dist/VeloDrop.app");
assert.ok(existsSync(packaged), "Run Scripts/package.sh before testing.");
const root = realpathSync(mkdtempSync(join(tmpdir(), "velodrop-cli-")));
const app = join(root, "CLI Test.app");
const executable = join(app, "Contents/MacOS/VeloDrop");
const command = join(root, "bin/vd");
const cwd = join(root, "shell directory");
const destination = join(root, "default downloads");
const data = join(root, "state");
const env = { ...process.env, VELODROP_DATA: data, VELODROP_DESTINATION: destination };
const payload = "VeloDrop CLI fixture\n";
let releaseSlow;
const slow = new Promise(resolve => { releaseSlow = resolve; });
const server = createServer(async (request, response) => {
  if (request.url === "/missing.zip") {
    response.writeHead(404).end();
    return;
  }
  if (request.url === "/slow.zip") await slow;
  response.writeHead(200, { "Content-Length": Buffer.byteLength(payload) });
  response.end(payload);
});

function run(...args) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { cwd, env, timeout: 30_000 }, (error, stdout, stderr) => {
      if (error && typeof error.code !== "number") reject(error);
      else resolve({ code: error?.code ?? 0, stdout, stderr });
    });
  });
}

function taskIDs(result, count, code = 0) {
  assert.equal(result.code, code, result.stderr);
  const ids = result.stdout.trim().split("\n");
  assert.equal(ids.length, count);
  for (const id of ids) assert.match(id, /^[A-F0-9-]{36}$/);
  return ids;
}

function record(id) {
  const file = join(data, "Transfers", id + ".json");
  return existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : undefined;
}

function assertDownloaded(id, path) {
  const item = record(id);
  assert.equal(item.state, "completed");
  assert.equal(item.submittedFromTerminal, true);
  assert.equal(realpathSync(item.finalPath), realpathSync(path));
  assert.equal(readFileSync(path, "utf8"), payload);
  return item;
}

function desktopPIDs() {
  const list = execFileSync("ps", ["-axo", "pid=,comm="], { encoding: "utf8" });
  return list.split("\n").flatMap(line => {
    const match = /^\s*(\d+)\s+(.+)$/.exec(line);
    return match?.[2] === executable ? [Number(match[1])] : [];
  });
}

async function waitFor(label, test, timeout = 12_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (test()) return;
    await sleep(100);
  }
  throw new Error("Timed out waiting for " + label);
}

try {
  execFileSync("/usr/bin/ditto", [packaged, app]);
  const info = join(app, "Contents/Info.plist");
  // Give the copy its own LaunchServices identity and preference domain.
  execFileSync("/usr/bin/plutil", ["-replace", "CFBundleIdentifier", "-string",
    "com.amayakite.velodrop.cli-smoke-" + randomUUID(), info]);
  execFileSync("/usr/bin/codesign", ["--force", "--sign", "-", app], { stdio: "ignore" });
  mkdirSync(dirname(command));
  mkdirSync(cwd);
  symlinkSync(join(app, "Contents/Helpers/VeloDropCLI"), command);

  await new Promise((resolve, reject) => server.once("error", reject).listen(0, "127.0.0.1", resolve));
  const base = "http://127.0.0.1:" + server.address().port;

  assert.match((await run("--help")).stdout, /Usage: velodrop/);
  const version = execFileSync("/usr/bin/plutil", ["-extract", "CFBundleShortVersionString", "raw", "-o", "-", info],
    { encoding: "utf8" }).trim();
  assert.equal((await run("--version")).stdout.trim(), "VeloDrop " + version);
  assert.equal((await run("--connections", "17", base + "/file.zip")).code, 2);
  const invalidBatch = await run(base + "/file.zip", "file:///tmp/example");
  assert.equal(invalidBatch.code, 2);
  assert.equal(invalidBatch.stdout, "");
  assert.ok(!existsSync(data), "Invalid commands must not start or submit to the app.");

  const output = join(cwd, "chosen files");
  mkdirSync(output);
  writeFileSync(join(output, "file.zip"), "keep this file");
  const [coldBatch, concurrent] = await Promise.all([
    run("--no-ui", "--wait", "--dir", "chosen files", "--connections", "16", base + "/file.zip", base + "/other.zip"),
    run("--no-ui", "--wait", base + "/default.zip"),
  ]);
  const [file, other] = taskIDs(coldBatch, 2);
  const [defaultFile] = taskIDs(concurrent, 1);
  assert.equal(assertDownloaded(file, join(output, "file (2).zip")).connectionLimit, 16);
  assert.equal(realpathSync(assertDownloaded(other, join(output, "other.zip")).destinationPath), output);
  assert.equal(realpathSync(assertDownloaded(defaultFile, join(destination, "default.zip")).destinationPath), destination);
  assert.equal(readFileSync(join(output, "file.zip"), "utf8"), "keep this file");
  const originalPIDs = desktopPIDs();
  assert.equal(originalPIDs.length, 1, "Concurrent cold commands must use a single app instance.");

  const [slowFile] = taskIDs(await run("--no-ui", "--connections=1", base + "/slow.zip"), 1);
  await waitFor("warm command intake", () => record(slowFile));
  assert.notEqual(record(slowFile).state, "completed", "Submission must return before the file completes.");
  assert.equal(record(slowFile).connectionLimit, 1);
  releaseSlow();
  await waitFor("background download", () => record(slowFile)?.state === "completed");
  assertDownloaded(slowFile, join(destination, "slow.zip"));
  assert.deepEqual(desktopPIDs(), originalPIDs, "A warm command must reuse the running app.");

  const failure = await run("--no-ui", "--wait", base + "/missing.zip", base + "/good.zip");
  const [missing, good] = taskIDs(failure, 2, 1);
  assert.match(failure.stderr, new RegExp(missing));
  assert.equal(record(missing).state, "failed");
  assertDownloaded(good, join(destination, "good.zip"));
  assert.deepEqual(readdirSync(join(data, "Inbox")), []);
  console.log("CLI smoke passed: bundled alias, validation, single-instance launch, batch downloads, and wait exit codes.");
} finally {
  releaseSlow();
  server.close();
  server.closeAllConnections();
  for (const pid of desktopPIDs()) {
    try {
      process.kill(pid, "SIGTERM");
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
  await waitFor("test app exit", () => desktopPIDs().length === 0);
  rmSync(root, { recursive: true, force: true });
}
