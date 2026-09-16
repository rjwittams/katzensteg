import assert from "node:assert/strict";
import { once } from "node:events";
import { existsSync, statSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import test from "node:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
	installHostEnvironment,
	listenForLaunches,
} from "./katzensteg-host.js";
import extension, { KatzenstegProducer } from "./katzensteg-panel.js";

function messages(socket: Socket) {
	let carry = "";
	const queue: Record<string, unknown>[] = [];
	let wake: (() => void) | undefined;
	socket.setEncoding("utf8");
	socket.on("data", (chunk: string) => {
		carry += chunk;
		for (;;) {
			const i = carry.indexOf("\n");
			if (i < 0) break;
			queue.push(JSON.parse(carry.slice(0, i)));
			carry = carry.slice(i + 1);
		}
		wake?.();
	});
	return async () => {
		while (!queue.length)
			await new Promise<void>((resolve) => {
				wake = resolve;
			});
		return queue.shift()!;
	};
}

async function client(target: string) {
	const socket = connect(target.slice("jsonl:".length));
	socket.on("error", () => {});
	await once(socket, "connect");
	return socket;
}

test("hosts allocate private unique addresses and restore only their environment", async () => {
	const a = await listenForLaunches(() => {}, assert.fail);
	const b = await listenForLaunches(() => {}, assert.fail);
	try {
		assert.notEqual(a.target, b.target);
		assert.equal(statSync(a.target.slice(6)).mode & 0o777, 0o600);
		assert.equal(
			statSync(a.target.slice(6).replace(/\/host.sock$/, "")).mode & 0o777,
			0o700,
		);
		const env = {
			KATZENSTEG_TARGET: "jsonl:/inherited",
			KATZENSTEG_OBSERVE: "0",
		};
		const restore = installHostEnvironment(a.target, env);
		assert.equal(env.KATZENSTEG_TARGET, a.target);
		assert.equal(env.KATZENSTEG_OBSERVE, "1");
		env.KATZENSTEG_OBSERVE = "explicit";
		restore();
		assert.equal(env.KATZENSTEG_TARGET, "jsonl:/inherited");
		assert.equal(env.KATZENSTEG_OBSERVE, "explicit");
	} finally {
		a.close();
		b.close();
	}
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(existsSync(a.target.slice(6)), false);
});

test(
	"fragmented registration preserves following output and rejects bad clients without losing listener",
	{ timeout: 5000 },
	async () => {
		const accepted: string[] = [];
		let resolveOutput: (value: string) => void = () => {};
		const output = new Promise<string>((resolve) => {
			resolveOutput = resolve;
		});
		const host = await listenForLaunches((socket, title) => {
			accepted.push(title);
			socket.setEncoding("utf8");
			socket.once("data", resolveOutput);
			socket.resume();
		}, assert.fail);
		try {
			for (const request of [
				"not json\n",
				'{"type":"register","version":2,"title":"bad"}\n',
				'{"type":"register","version":1,"title":"bad\\u001b"}\n',
				"x".repeat(1025),
			]) {
				const bad = await client(host.target);
				const closed = new Promise((resolve) => bad.once("close", resolve));
				bad.end(request);
				await closed;
			}
			const good = await client(host.target);
			const next = messages(good);
			good.write('{"type":"reg');
			good.write('ister","version":1,"title":"Monkey Island 2"}\nfollowing\n');
			assert.deepEqual(await next(), {
				type: "registered",
				version: 1,
				session_id: 1,
			});
			assert.equal(await output, "following\n");
			assert.deepEqual(accepted, ["Monkey Island 2"]);
			good.destroy();
		} finally {
			host.close();
		}
	},
);

test(
	"socket producer shares attach, frames, input, observations and graceful shutdown",
	{ timeout: 5000 },
	async () => {
		let producer: KatzenstegProducer | undefined;
		let frameCount = 0;
		const statuses: string[] = [];
		const host = await listenForLaunches((socket, title) => {
			producer = new KatzenstegProducer(
				title,
				{
					onStatus: (status) => statuses.push(status),
					onError: assert.fail,
					onFrame: () => frameCount++,
				},
				10000,
				[],
				socket,
			);
			producer.start();
			producer.setViewport(
				{
					rect: { row: 1, col: 1, rows: 12, cols: 40 },
					clip: undefined,
					occlusions: [],
					generation: 1,
					cellDimensions: { widthPx: 10, heightPx: 20 },
				},
				10000,
			);
		}, assert.fail);
		try {
			const socket = await client(host.target);
			const next = messages(socket);
			socket.write('{"type":"register","version":1,"title":"test"}\n');
			assert.equal((await next()).type, "registered");
			assert.equal((await next()).type, "attach");
			assert.ok(producer?.ready);
			producer.sendInput({ type: "input", marker: 55 });
			assert.equal((await next()).marker, 55);
			socket.write(
				`${JSON.stringify({ type: "frame_batch", window_id: "main", seq: 1, presentation_generation: 1, groups: { deletes: [], uploads: [], placements: [], after: [] } })}\n`,
			);
			const observation = producer.game.observe();
			const request = await next();
			assert.equal(request.type, "observe");
			assert.equal(typeof request.path, "string");
			writeFileSync(String(request.path), Buffer.from([255, 0, 0, 255]));
			socket.write(
				`${JSON.stringify({ type: "observation", request_id: request.request_id, width: 1, height: 1, frame_id: 1, timestamp_ms: Date.now() })}\n`,
			);
			assert.equal((await observation)?.width, 1);
			assert.equal(frameCount, 1);
			socket.write('{"type":"presentation_status","input_supported":false}\n');
			while (!statuses.includes("observation only")) {
				await new Promise((resolve) => setImmediate(resolve));
			}
			await assert.rejects(
				producer.game.act([{ type: "key", key: "escape" }]),
				/Observation-only/,
			);
			producer.sendInput({ type: "input", marker: "unsupported" });
			// Shutdown must be the next message: neither agent nor human input was sent.

			producer.stop("test");
			assert.equal((await next()).type, "shutdown");
			assert.equal(producer.ready, false);
			const closed = once(socket, "close");
			socket.end();
			await closed;
			await new Promise((resolve) => setImmediate(resolve));
			assert.ok(statuses.includes("disconnected"));
		} finally {
			producer?.stop("cleanup");
			host.close();
		}
	},
);

test(
	"a stalled registration times out, and closing a host disconnects admitted clients",
	{ timeout: 7000 },
	async () => {
		let producer: KatzenstegProducer | undefined;
		let resolveClosed: () => void = () => {};
		const producerClosed = new Promise<void>((resolve) => {
			resolveClosed = resolve;
		});
		const host = await listenForLaunches((socket, title) => {
			producer = new KatzenstegProducer(
				title,
				{ onStatus: () => {}, onClosed: resolveClosed },
				0,
				[],
				socket,
			);
			producer.start();
			producer.setViewport(
				{
					rect: { row: 1, col: 1, rows: 12, cols: 40 },
					clip: undefined,
					occlusions: [],
					generation: 1,
					cellDimensions: { widthPx: 10, heightPx: 20 },
				},
				0,
			);
		}, assert.fail);
		try {
			const stalled = await client(host.target);
			stalled.write('{"type":');
			await once(stalled, "close");
			const socket = await client(host.target);
			const next = messages(socket);
			socket.write('{"type":"register","version":1,"title":"test"}\n');
			await next();
			await next();
			assert.ok(producer?.ready);
			const observation = producer.game.observe();
			const rejected = assert.rejects(observation, /cancelled|disconnected/);
			await next();
			host.close();
			await rejected;
			await producerClosed;
			assert.equal(producer.ready, false);
		} finally {
			host.close();
		}
	},
);

test(
	"pending registration capacity recovers after clients disconnect",
	{ timeout: 5000 },
	async () => {
		const host = await listenForLaunches(() => {}, assert.fail);
		const clients: Socket[] = [];
		try {
			for (let i = 0; i < 16; i++) clients.push(await client(host.target));
			const overflow = await client(host.target);
			await once(overflow, "close");
			for (const socket of clients) socket.destroy();
			// An extra connection is processed after the preceding EOF events.
			await new Promise((resolve) => setTimeout(resolve, 20));
			const fresh = await client(host.target);
			clients.push(fresh);
			const next = messages(fresh);
			fresh.write('{"type":"register","version":1,"title":"fresh"}\n');
			assert.equal((await next()).type, "registered");
		} finally {
			for (const socket of clients) socket.destroy();
			host.close();
		}
	},
);

test("interactive host survives conversation replacement, reload restores inherited target, headless has no host", async () => {
	const inheritedTarget = process.env.KATZENSTEG_TARGET;
	const inheritedObserve = process.env.KATZENSTEG_OBSERVE;
	const ctx = {
		hasUI: true,
		ui: { notify: (message: string) => assert.fail(message) },
	};
	function runtime() {
		const handlers = new Map<
			string,
			(event: { reason: string }, context: typeof ctx) => void | Promise<void>
		>();
		extension({
			on: (
				name: string,
				handler: (
					event: { reason: string },
					context: typeof ctx,
				) => void | Promise<void>,
			) => handlers.set(name, handler),
			registerTool: () => {},
			registerCommand: () => {},
			registerMessageRenderer: () => {},
		} as unknown as ExtensionAPI);
		return async (name: string, reason: string, context = ctx) => {
			await handlers.get(name)?.({ reason }, context);
		};
	}
	const first = runtime();
	let current = first;
	try {
		await first("session_start", "startup", { ...ctx, hasUI: false });
		assert.equal(process.env.KATZENSTEG_TARGET, inheritedTarget);
		await first("session_start", "startup");
		const target = process.env.KATZENSTEG_TARGET;
		assert.ok(target);
		assert.ok(target.startsWith("jsonl:"));
		await first("session_shutdown", "new");
		assert.equal(process.env.KATZENSTEG_TARGET, target);
		current = runtime();
		await current("session_start", "new");
		assert.equal(process.env.KATZENSTEG_TARGET, target);
		await current("session_shutdown", "reload");
		assert.equal(process.env.KATZENSTEG_TARGET, inheritedTarget);
		assert.equal(process.env.KATZENSTEG_OBSERVE, inheritedObserve);
		await new Promise((resolve) => setImmediate(resolve));
		assert.equal(existsSync(target.slice(6)), false);
		current = runtime();
		await current("session_start", "reload");
		assert.notEqual(process.env.KATZENSTEG_TARGET, target);
	} finally {
		await current("session_shutdown", "quit");
	}
});
