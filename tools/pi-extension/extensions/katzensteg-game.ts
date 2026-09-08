import { deflateSync } from "node:zlib";
import { makeTerminalBytesInputMessage } from "./katzensteg-input.js";

export interface Observation {
	frameId: number;
	timestampMs: number;
	width: number;
	height: number;
	png: Buffer;
}
export interface GameTransport {
	observe(signal: AbortSignal): Promise<Observation | undefined>;
	input(message: object): void;
}
export type GameAction =
	| {
			type: "move" | "click";
			x: number;
			y: number;
			button?: "left" | "right" | "middle";
	  }
	| { type: "key"; key: string }
	| { type: "wait"; ms: number };

const namedKeys: Record<string, string> = {
	enter: "\r",
	escape: "\x1b",
	space: " ",
	tab: "\t",
	backspace: "\x7f",
	up: "\x1b[A",
	down: "\x1b[B",
	right: "\x1b[C",
	left: "\x1b[D",
	f1: "\x1bOP",
	f2: "\x1bOQ",
	f3: "\x1bOR",
	f4: "\x1bOS",
	f5: "\x1b[15~",
	f6: "\x1b[17~",
	f7: "\x1b[18~",
	f8: "\x1b[19~",
};
export function keyBytes(key: string): string {
	const name = key.toLowerCase();
	const bytes = Object.hasOwn(namedKeys, name) ? namedKeys[name] : undefined;
	if (bytes) return bytes;
	if (/^[\x20-\x7e]$/.test(key)) return key;
	throw new Error(
		`Unsupported key: ${key}. Use a printable ASCII character, arrows, enter, escape, space, tab, backspace, or f1–f8.`,
	);
}
export function delay(ms: number, signal: AbortSignal): Promise<void> {
	signal.throwIfAborted();
	return new Promise((resolve, reject) => {
		const abort = () => {
			clearTimeout(timer);
			reject(signal.reason);
		};
		const timer = setTimeout(() => {
			signal.removeEventListener("abort", abort);
			resolve();
		}, ms);
		signal.addEventListener("abort", abort, { once: true });
	});
}

/** A single panel's interaction interface; independent of pi tool definitions. */
export class GameInteraction {
	private running: AbortController | undefined;
	private releaseHeld: (() => void) | undefined;
	private readonly transport: GameTransport;
	constructor(transport: GameTransport) {
		this.transport = transport;
	}

	cancel(reason = "Human input took control"): void {
		try {
			this.releaseHeld?.();
		} catch {
			/* A disconnected producer cannot retain input. */
		} finally {
			this.running?.abort(new Error(reason));
		}
	}
	private async exclusive<T>(
		signal: AbortSignal | undefined,
		work: (signal: AbortSignal) => Promise<T>,
	): Promise<T> {
		if (this.running)
			throw new Error("This panel already has an agent operation in progress.");
		const controller = new AbortController();
		this.running = controller;
		try {
			return await work(
				signal
					? AbortSignal.any([signal, controller.signal])
					: controller.signal,
			);
		} finally {
			this.running = undefined;
		}
	}
	observe(
		options: { afterFrame?: number; timeoutMs?: number } = {},
		signal?: AbortSignal,
	): Promise<Observation> {
		return this.exclusive(signal, (s) => this.observeWithin(options, s));
	}
	private async observeWithin(
		options: { afterFrame?: number; timeoutMs?: number },
		signal: AbortSignal,
	): Promise<Observation> {
		const deadline =
			Date.now() + Math.max(0, Math.min(5000, options.timeoutMs ?? 1500));
		let latest: Observation | undefined;
		do {
			signal.throwIfAborted();
			latest = await this.transport.observe(signal);
			if (latest) {
				if (
					options.afterFrame === undefined ||
					latest.frameId > options.afterFrame
				)
					return latest;
			}
			if (Date.now() >= deadline) break;
			await delay(Math.min(100, Math.max(0, deadline - Date.now())), signal);
		} while (true);
		if (latest) return latest; // Paused games can legitimately retain the same frame.
		throw new Error(
			"No captured frame. Wait for the game to render; observation currently requires an SDL renderer profile such as mi2.",
		);
	}
	act(actions: GameAction[], signal?: AbortSignal): Promise<Observation> {
		return this.exclusive(signal, async (s) => {
			if (actions.length < 1 || actions.length > 16)
				throw new Error("Send between 1 and 16 actions.");
			const before = await this.observeWithin({}, s);
			let waitMs = 0;
			// Validate the whole sequence before sending any input.
			for (const action of actions) {
				if (action.type === "key") keyBytes(action.key);
				else if (action.type === "wait") {
					if (!Number.isInteger(action.ms) || action.ms < 0 || action.ms > 5000)
						throw new Error("Wait must be 0–5000 ms.");
					waitMs += action.ms;
				} else if (
					!Number.isInteger(action.x) ||
					!Number.isInteger(action.y) ||
					action.x < 0 ||
					action.y < 0 ||
					action.x >= before.width ||
					action.y >= before.height
				) {
					throw new Error(
						`Coordinates must be within the ${before.width}×${before.height} observation.`,
					);
				}
			}
			if (waitMs > 10000)
				throw new Error("Total wait must not exceed 10 seconds.");
			for (const action of actions) {
				s.throwIfAborted();
				if (action.type === "wait") await delay(action.ms, s);
				else if (action.type === "key") {
					this.transport.input(makeTerminalBytesInputMessage("main", keyBytes(action.key)));
					await delay(100, s);
				} else {
					const pointer = {
						type: "input",
						window_id: "main",
						event: "source_pointer",
						x: action.x,
						y: action.y,
						width: before.width,
						height: before.height,
					};
					this.transport.input({
						...pointer,
						kind: "pointermove",
						button: -1,
						buttons: 0,
					});
					if (action.type === "click") {
						const button =
							action.button === "right"
								? 2
								: action.button === "middle"
									? 1
									: 0;
						this.transport.input({
							...pointer,
							kind: "pointerdown",
							button,
							buttons: 1 << button,
						});
						let released = false;
						const release = () => {
							if (released) return;
							released = true;
							this.releaseHeld = undefined;
							this.transport.input({
								...pointer,
								kind: "pointerup",
								button,
								buttons: 0,
							});
						};
						this.releaseHeld = release;
						try {
							await delay(60, s);
						} finally {
							release();
						}
					}
				}
			}
			return this.observeWithin(
				{ afterFrame: before.frameId, timeoutMs: 1500 },
				s,
			);
		});
	}
}

/** PNG encoding from a coherent RGBA snapshot; no terminal upload files involved. */
export function rgbaPng(width: number, height: number, rgba: Buffer): Buffer {
	if (
		!Number.isInteger(width) ||
		!Number.isInteger(height) ||
		width <= 0 ||
		height <= 0 ||
		width * height * 4 > 64 * 1024 * 1024 ||
		rgba.length !== width * height * 4
	)
		throw new Error("Invalid RGBA snapshot");
	const chunk = (name: string, data: Buffer): Buffer => {
		const body = Buffer.concat([Buffer.from(name), data]);
		let crc = 0xffffffff;
		for (const byte of body) {
			crc ^= byte;
			for (let bit = 0; bit < 8; bit++)
				crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
		}
		const out = Buffer.alloc(body.length + 8);
		out.writeUInt32BE(data.length);
		body.copy(out, 4);
		out.writeUInt32BE((crc ^ 0xffffffff) >>> 0, body.length + 4);
		return out;
	};
	const header = Buffer.alloc(13);
	header.writeUInt32BE(width);
	header.writeUInt32BE(height, 4);
	header[8] = 8;
	header[9] = 6;
	const scanlines = Buffer.alloc((width * 4 + 1) * height);
	for (let y = 0; y < height; y++)
		rgba.copy(
			scanlines,
			y * (width * 4 + 1) + 1,
			y * width * 4,
			(y + 1) * width * 4,
		);
	return Buffer.concat([
		Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
		chunk("IHDR", header),
		chunk("IDAT", deflateSync(scanlines)),
		chunk("IEND", Buffer.alloc(0)),
	]);
}
