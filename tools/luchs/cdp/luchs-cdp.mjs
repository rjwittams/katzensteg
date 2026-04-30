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

export function emitMockFrame(stdout = process.stdout) {
  const payload = Buffer.from("mock");
  stdout.write(`LUCHS_FRAME {"format":"png","width":1,"height":1,"len":${payload.length}}\n`);
  stdout.write(payload);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  emitMockFrame();
}
