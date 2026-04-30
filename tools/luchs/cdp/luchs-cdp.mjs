import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

export function candidateBrowsers(platform = process.platform, env = process.env) {
  const candidates = [];
  if (env.LUCHS_BROWSER) candidates.push(env.LUCHS_BROWSER);

  if (platform === "darwin") {
    candidates.push(
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    );
  } else if (platform === "linux") {
    candidates.push(
      "chromium",
      "chromium-browser",
      "google-chrome",
      "google-chrome-stable",
      "brave-browser",
      "microsoft-edge",
    );
  } else if (platform === "win32") {
    candidates.push(
      "chrome.exe",
      "msedge.exe",
      "brave.exe",
    );
  }

  return candidates;
}

export function localFileUrl(inputPath) {
  return pathToFileURL(path.resolve(inputPath)).href;
}

function parseArgs(argv) {
  const options = { width: 800, height: 600, fps: 15, frames: 1 };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--width") options.width = Number(argv[++i]);
    else if (arg === "--height") options.height = Number(argv[++i]);
    else if (arg === "--fps") options.fps = Number(argv[++i]);
    else if (arg === "--frames") options.frames = Number(argv[++i]);
    else rest.push(arg);
  }
  if (rest.length !== 1) throw new Error("usage: luchs-cdp [--width N] [--height N] [--fps N] [--frames N] file.html");
  if (!Number.isInteger(options.width) || options.width <= 0) throw new Error("width must be a positive integer");
  if (!Number.isInteger(options.height) || options.height <= 0) throw new Error("height must be a positive integer");
  if (!Number.isFinite(options.fps) || options.fps <= 0) throw new Error("fps must be positive");
  if (!Number.isInteger(options.frames) || options.frames < 0) throw new Error("frames must be a non-negative integer");
  options.htmlPath = rest[0];
  return options;
}

function resolveBrowser(env = process.env, platform = process.platform) {
  for (const candidate of candidateBrowsers(platform, env)) {
    if (path.isAbsolute(candidate)) {
      if (existsSync(candidate)) return candidate;
    } else {
      return candidate;
    }
  }
  throw new Error("no Chromium-family browser found; set LUCHS_BROWSER");
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : undefined;
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

async function waitForVersion(port, child) {
  const deadline = Date.now() + 8000;
  let lastError;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`browser exited with code ${child.exitCode}`);
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (response.ok) return await response.json();
      lastError = new Error(`DevTools version endpoint returned ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for browser DevTools endpoint: ${lastError?.message ?? "unknown error"}`);
}

class CdpClient {
  constructor(url) {
    this.url = url;
    this.nextId = 1;
    this.pending = new Map();
    this.events = [];
    this.waiters = [];
  }

  async open() {
    this.ws = new WebSocket(this.url);
    this.ws.addEventListener("message", (event) => this.onMessage(event.data));
    await new Promise((resolve, reject) => {
      this.ws.addEventListener("open", resolve, { once: true });
      this.ws.addEventListener("error", reject, { once: true });
    });
  }

  close() {
    this.ws?.close();
  }

  send(method, params = {}, sessionId = undefined) {
    const id = this.nextId++;
    const message = sessionId === undefined ? { id, method, params } : { id, method, params, sessionId };
    const promise = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.ws.send(JSON.stringify(message));
    return promise;
  }

  waitFor(method, sessionId = undefined, timeoutMs = 5000) {
    const existingIndex = this.events.findIndex((event) => event.method === method && (sessionId === undefined || event.sessionId === sessionId));
    if (existingIndex >= 0) {
      const [event] = this.events.splice(existingIndex, 1);
      return Promise.resolve(event.params);
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = this.waiters.indexOf(waiter);
        if (idx >= 0) this.waiters.splice(idx, 1);
        reject(new Error(`timed out waiting for ${method}`));
      }, timeoutMs);
      const waiter = { method, sessionId, resolve, reject, timer };
      this.waiters.push(waiter);
    });
  }

  onMessage(data) {
    const text = typeof data === "string" ? data : Buffer.from(data).toString("utf8");
    const message = JSON.parse(text);
    if (message.id !== undefined) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) pending.reject(new Error(message.error.message ?? "CDP command failed"));
      else pending.resolve(message.result ?? {});
      return;
    }

    const idx = this.waiters.findIndex((waiter) => waiter.method === message.method && (waiter.sessionId === undefined || waiter.sessionId === message.sessionId));
    if (idx >= 0) {
      const [waiter] = this.waiters.splice(idx, 1);
      clearTimeout(waiter.timer);
      waiter.resolve(message.params ?? {});
    } else {
      this.events.push(message);
    }
  }
}

async function launchBrowser(browser, port, userDataDir) {
  const args = [
    `--remote-debugging-port=${port}`,
    "--remote-allow-origins=*",
    `--user-data-dir=${userDataDir}`,
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    "--no-first-run",
    "--no-default-browser-check",
    "about:blank",
  ];
  return spawn(browser, args, { stdio: ["ignore", "ignore", "pipe"] });
}

function writeFrame(stdout, options, png) {
  stdout.write(`LUCHS_FRAME {"format":"png","width":${options.width},"height":${options.height},"len":${png.length}}\n`);
  stdout.write(png);
}

async function captureFrames(options, stdout = process.stdout) {
  const browser = resolveBrowser();
  const port = await freePort();
  const userDataDir = mkdtempSync(path.join(os.tmpdir(), "luchs-cdp-"));
  const child = await launchBrowser(browser, port, userDataDir);
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", () => {});

  let client;
  try {
    const version = await waitForVersion(port, child);
    client = new CdpClient(version.webSocketDebuggerUrl);
    await client.open();
    const target = await client.send("Target.createTarget", { url: "about:blank" });
    const attached = await client.send("Target.attachToTarget", { targetId: target.targetId, flatten: true });
    const sessionId = attached.sessionId;
    await client.send("Page.enable", {}, sessionId);
    await client.send("Emulation.setDeviceMetricsOverride", {
      width: options.width,
      height: options.height,
      deviceScaleFactor: 1,
      mobile: false,
    }, sessionId);
    await client.send("Page.navigate", { url: localFileUrl(options.htmlPath) }, sessionId);
    await client.waitFor("Page.loadEventFired", sessionId);

    const delayMs = Math.max(1, Math.round(1000 / options.fps));
    let frame = 0;
    while (options.frames === 0 || frame < options.frames) {
      const screenshot = await client.send("Page.captureScreenshot", { format: "png", fromSurface: true }, sessionId);
      writeFrame(stdout, options, Buffer.from(screenshot.data, "base64"));
      frame++;
      if (options.frames === 0 || frame < options.frames) await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  } finally {
    client?.close();
    child.kill("SIGTERM");
    rmSync(userDataDir, { recursive: true, force: true });
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  captureFrames(parseArgs(process.argv.slice(2))).catch((error) => {
    console.error(`luchs-cdp: ${error.message}`);
    process.exitCode = 1;
  });
}
