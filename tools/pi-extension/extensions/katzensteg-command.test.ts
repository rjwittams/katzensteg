import test from "node:test";
import assert from "node:assert/strict";

import { expandHomePrefix, parseCommand, sameArgs } from "./katzensteg-command.js";

test("bare input toggles", () => {
	assert.deepEqual(parseCommand(""), { kind: "toggle" });
	assert.deepEqual(parseCommand("   "), { kind: "toggle" });
});

test("open/inline select a profile without args", () => {
	assert.deepEqual(parseCommand("open retroarch"), { kind: "open", profile: "retroarch" });
	assert.deepEqual(parseCommand("inline sonic"), { kind: "inline", profile: "sonic" });
});

test("open with no profile falls through to preferred (undefined profile)", () => {
	assert.deepEqual(parseCommand("open"), { kind: "open", profile: undefined });
});

test("bare profile name opens it", () => {
	assert.deepEqual(parseCommand("retroarch"), { kind: "open", profile: "retroarch" });
});

test("program args are positional — no -- required", () => {
	assert.deepEqual(parseCommand("inline ffplay @~/dev/k-vids/clip.mp4"), {
		kind: "inline",
		profile: "ffplay",
		args: ["@~/dev/k-vids/clip.mp4"],
	});
	assert.deepEqual(parseCommand("open retroarch -L core.dylib game.rom"), {
		kind: "open",
		profile: "retroarch",
		args: ["-L", "core.dylib", "game.rom"],
	});
});

test("bare profile carries positional args", () => {
	assert.deepEqual(parseCommand("ffplay /tmp/clip.mp4"), {
		kind: "open",
		profile: "ffplay",
		args: ["/tmp/clip.mp4"],
	});
});

test("a -- separator between profile and args is accepted and dropped", () => {
	assert.deepEqual(parseCommand("open retroarch -- -L core.dylib game.rom"), {
		kind: "open",
		profile: "retroarch",
		args: ["-L", "core.dylib", "game.rom"],
	});
	assert.deepEqual(parseCommand("inline ffplay -- --fullscreen"), {
		kind: "inline",
		profile: "ffplay",
		args: ["--fullscreen"],
	});
});

test("a leading -- means args only (preferred profile)", () => {
	assert.deepEqual(parseCommand("open -- -L core.dylib"), {
		kind: "open",
		profile: undefined,
		args: ["-L", "core.dylib"],
	});
	assert.deepEqual(parseCommand("-- -L core.dylib"), {
		kind: "open",
		profile: undefined,
		args: ["-L", "core.dylib"],
	});
});

test("open with no args yields no args field", () => {
	assert.deepEqual(parseCommand("open retroarch"), { kind: "open", profile: "retroarch" });
	assert.deepEqual(parseCommand("open retroarch --"), { kind: "open", profile: "retroarch" });
});

test("profile subcommand carries args", () => {
	assert.deepEqual(parseCommand("profile ffplay /tmp/clip.mp4"), {
		kind: "profile",
		profile: "ffplay",
		args: ["/tmp/clip.mp4"],
	});
	assert.deepEqual(parseCommand("profile retroarch"), { kind: "profile", profile: "retroarch" });
});

test("size presets parse before being treated as a profile", () => {
	assert.deepEqual(parseCommand("size large"), { kind: "size", size: "large" });
	assert.deepEqual(parseCommand("medium"), { kind: "size", size: "medium" });
});

test("close ignores any trailing args", () => {
	assert.deepEqual(parseCommand("close"), { kind: "close" });
});

test("expandHomePrefix expands a leading ~ only", () => {
	assert.equal(expandHomePrefix("~", "/Users/test"), "/Users/test");
	assert.equal(expandHomePrefix("~/dev/clip.mp4", "/Users/test"), "/Users/test/dev/clip.mp4");
	// Not a prefix, or another token entirely — left untouched.
	assert.equal(expandHomePrefix("/abs/clip.mp4", "/Users/test"), "/abs/clip.mp4");
	assert.equal(expandHomePrefix("$HOME/clip.mp4", "/Users/test"), "$HOME/clip.mp4");
	assert.equal(expandHomePrefix("report~name.txt", "/Users/test"), "report~name.txt");
	assert.equal(expandHomePrefix("~backup", "/Users/test"), "~backup");
});

test("sameArgs compares element-wise", () => {
	assert.ok(sameArgs([], []));
	assert.ok(sameArgs(["-L", "core"], ["-L", "core"]));
	assert.ok(!sameArgs(["-L"], ["-L", "core"]));
	assert.ok(!sameArgs(["-L", "core"], ["-L", "other"]));
});
