import assert from "node:assert/strict";
import test from "node:test";
import { inflateSync } from "node:zlib";
import {
	GameInteraction,
	rgbaPng,
	type Observation,
} from "./katzensteg-game.js";

const frame = (frameId = 1): Observation => ({
	frameId,
	timestampMs: 123,
	width: 320,
	height: 200,
	png: Buffer.from("image"),
});
test("agent Escape sends a complete key sequence without needing another input", async () => {
	const sent: object[] = [];
	const game = new GameInteraction({
		observe: async () => frame(),
		input: (message) => sent.push(message),
	});
	await game.act([{ type: "key", key: "escape" }]);
	assert.deepEqual(sent, [
		{
			type: "input",
			window_id: "main",
			event: "terminal_bytes",
			bytes: "\x1b[27u",
		},
	]);
});
test("actions use full image pixels and release click before human takeover", async () => {
	const sent: Record<string, unknown>[] = [];
	let game: GameInteraction;
	game = new GameInteraction({
		observe: async () => frame(),
		input: (message) => {
			sent.push(message as Record<string, unknown>);
			if ((message as Record<string, unknown>).kind === "pointerdown")
				queueMicrotask(() => {
					game.cancel();
					sent.push({ human: true });
				});
		},
	});
	await assert.rejects(
		game.act([{ type: "click", x: 247, y: 123 }]),
		/Human input/,
	);
	assert.deepEqual(
		sent.map((m) => m.kind ?? "human"),
		["pointermove", "pointerdown", "pointerup", "human"],
	);
	assert.equal(sent[0].x, 247);
	assert.equal(sent[0].width, 320);
});
test("validate entire action sequence before emitting input", async () => {
	const sent: object[] = [];
	const game = new GameInteraction({
		observe: async () => frame(),
		input: (m) => sent.push(m),
	});
	await assert.rejects(
		game.act([
			{ type: "click", x: 1, y: 1 },
			{ type: "move", x: 320, y: 1 },
		]),
		/Coordinates/,
	);
	assert.equal(sent.length, 0);
});
test("observation waits for a newer frame and can return retained paused frame", async () => {
	let calls = 0;
	const game = new GameInteraction({
		observe: async () => frame(++calls),
		input: () => {},
	});
	assert.equal((await game.observe({ afterFrame: 1 })).frameId, 2);
	const paused = new GameInteraction({
		observe: async () => frame(),
		input: () => {},
	});
	assert.equal(
		(await paused.observe({ afterFrame: 1, timeoutMs: 0 })).frameId,
		1,
	);
});
test("abort releases a held button and overlapping operations fail", async () => {
	const sent: Record<string, unknown>[] = [];
	const abort = new AbortController();
	const game = new GameInteraction({
		observe: async () => frame(),
		input: (m) => {
			sent.push(m as Record<string, unknown>);
			if ((m as Record<string, unknown>).kind === "pointerdown")
				abort.abort(new Error("Cancelled"));
		},
	});
	const action = game.act([{ type: "click", x: 1, y: 1 }], abort.signal);
	await assert.rejects(game.observe(), /in progress/);
	await assert.rejects(action, /Cancelled/);
	assert.equal(sent.at(-1)?.kind, "pointerup");
});
test("PNG preserves exact RGBA pixels and dimensions", async () => {
	const rgba = Buffer.from([255, 0, 0, 255, 0, 255, 0, 128]);
	const png = await rgbaPng(2, 1, rgba);
	assert.equal(png.readUInt32BE(16), 2);
	assert.equal(png.readUInt32BE(20), 1);
	const compressedLength = png.readUInt32BE(33);
	assert.deepEqual(
		inflateSync(png.subarray(41, 41 + compressedLength)),
		Buffer.concat([Buffer.from([0]), rgba]),
	);
	await assert.rejects(rgbaPng(3, 1, rgba), /Invalid/);
});

test("PNG compression lets the event loop run before completion", async () => {
	let yielded = false;
	const turn = new Promise<void>((resolve) =>
		setImmediate(() => {
			yielded = true;
			resolve();
		}),
	);
	await rgbaPng(1024, 1024, Buffer.alloc(1024 * 1024 * 4));
	assert.equal(yielded, true);
	await turn;
});

test("cancellation during asynchronous observation rejects the operation", async () => {
	const abort = new AbortController();
	const game = new GameInteraction({
		observe: async () => {
			abort.abort(new Error("Cancelled"));
			return frame();
		},
		input: () => assert.fail("unexpected input"),
	});
	await assert.rejects(game.observe({}, abort.signal), /Cancelled/);
});

test("invalid keys do not enter the input stream", async () => {
	const game = new GameInteraction({
		observe: async () => frame(),
		input: () => assert.fail("unexpected input"),
	});
	await assert.rejects(
		game.act([{ type: "key", key: "constructor" }]),
		/Unsupported key/,
	);
});
