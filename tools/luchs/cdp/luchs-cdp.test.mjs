import assert from "node:assert/strict";
import { candidateBrowsers, localFileUrl } from "./luchs-cdp.mjs";

assert.equal(candidateBrowsers("darwin", { LUCHS_BROWSER: "/tmp/chrome" })[0], "/tmp/chrome");
assert(candidateBrowsers("linux", {}).some((name) => name.includes("chromium") || name.includes("google-chrome")));
assert(candidateBrowsers("darwin", {}).some((name) => name.includes("Google Chrome.app")));
assert.equal(localFileUrl("/tmp/luchs test.html"), "file:///tmp/luchs%20test.html");

console.log("luchs-cdp tests passed");
