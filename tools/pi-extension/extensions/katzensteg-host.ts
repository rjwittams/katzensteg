import { chmodSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import os from "node:os";
import path from "node:path";
import { TextDecoder } from "node:util";

/** A host address is opaque to launchers; only the owning host removes it. */
export async function listenForLaunches(
	onLaunch: (socket: Socket, title: string) => void | Promise<void>,
	onError: (error: Error) => void,
): Promise<{ target: string; close(): void }> {
	let base = path.resolve(os.tmpdir());
	const runtime = process.env.XDG_RUNTIME_DIR;
	if (runtime && path.isAbsolute(runtime)) {
		try {
			const info = statSync(runtime);
			if (
				info.isDirectory() &&
				info.uid === process.getuid?.() &&
				(info.mode & 0o777) === 0o700
			)
				base = runtime;
		} catch {
			/* Fall back to a private temporary directory. */
		}
	}
	// Leave room for the random suffix and socket name on macOS (104 bytes).
	if (
		Buffer.byteLength(path.join(base, "katzensteg-XXXXXX", "host.sock")) >= 100
	)
		base = "/tmp";
	const directory = mkdtempSync(path.join(base, "katzensteg-"));
	chmodSync(directory, 0o700);
	const address = path.join(directory, "host.sock");
	const sockets = new Set<Socket>();
	let pending = 0;
	let nextSessionId = 1;
	let closed = false;
	const server = createServer({ allowHalfOpen: true }, (socket) => {
		if (closed || pending >= 16 || sockets.size >= 32) {
			socket.destroy();
			return;
		}
		sockets.add(socket);
		pending++;
		let registering = true;
		let bytes = Buffer.alloc(0);
		const timer = setTimeout(() => socket.destroy(), 5000);
		const finishRegistration = () => {
			if (!registering) return;
			registering = false;
			pending--;
			clearTimeout(timer);
			socket.off("data", readRegistration);
		};
		socket.on("error", () => {}); // Per-client failure must not take down pi.
		socket.once("close", () => {
			finishRegistration();
			sockets.delete(socket);
		});
		socket.once("end", () => {
			if (registering) socket.destroy();
		});
		const readRegistration = (chunk: Buffer) => {
			const newline = chunk.indexOf(10);
			const prefix = newline < 0 ? chunk : chunk.subarray(0, newline);
			if (bytes.length + prefix.length > 1024) {
				socket.destroy();
				return;
			}
			bytes = Buffer.concat([bytes, prefix]);
			if (newline < 0) return;
			try {
				const request = JSON.parse(
					new TextDecoder("utf-8", { fatal: true }).decode(bytes),
				);
				if (
					request?.type !== "register" ||
					request.version !== 1 ||
					typeof request.title !== "string" ||
					Buffer.byteLength(request.title) < 1 ||
					Buffer.byteLength(request.title) > 128 ||
					/[\u0000-\u001f\u007f-\u009f]/u.test(request.title)
				)
					throw new Error("Invalid registration");
				socket.pause();
				finishRegistration();
				if (newline + 1 < chunk.length)
					socket.unshift(chunk.subarray(newline + 1));
				socket.write(
					`${JSON.stringify({ type: "registered", version: 1, session_id: nextSessionId++ })}\n`,
				);
				Promise.resolve(onLaunch(socket, request.title)).catch(
					(error: unknown) => {
						socket.destroy();
						onError(error instanceof Error ? error : new Error(String(error)));
					},
				);
			} catch {
				socket.destroy();
			}
		};
		socket.on("data", readRegistration);
	});
	try {
		await new Promise<void>((resolve, reject) => {
			server.once("error", reject);
			server.listen(address, () => {
				server.off("error", reject);
				resolve();
			});
		});
		chmodSync(address, 0o600);
	} catch (error) {
		server.close();
		rmSync(directory, { recursive: true, force: true });
		throw error;
	}
	server.on("error", onError);
	return {
		target: `jsonl:${address}`,
		close() {
			if (closed) return;
			closed = true;
			for (const socket of sockets) socket.destroy();
			server.close(() => rmSync(directory, { recursive: true, force: true }));
		},
	};
}

/** Restore only values we still own, respecting subsequent explicit changes. */
export function installHostEnvironment(
	target: string,
	env: NodeJS.ProcessEnv = process.env,
): () => void {
	const values = { KATZENSTEG_TARGET: target, KATZENSTEG_OBSERVE: "1" };
	const previous = new Map(Object.keys(values).map((key) => [key, env[key]]));
	Object.assign(env, values);
	return () => {
		for (const [key, value] of Object.entries(values)) {
			if (env[key] !== value) continue;
			const old = previous.get(key);
			if (old === undefined) delete env[key];
			else env[key] = old;
		}
	};
}

interface InteractiveHostState {
	listener?: Awaited<ReturnType<typeof listenForLaunches>>;
	restoreEnvironment?: () => void;
	onLaunch?: (socket: Socket, title: string) => Promise<void>;
	onError?: (error: Error) => void;
}

// Pi recreates extension modules on /new, /resume and /fork. Keep only the
// listener here; UI callbacks are replaced by the new runtime, never retained.
const interactiveHostKey = Symbol.for("katzensteg.pi.interactive-host.v1");
export function interactiveHostState(): InteractiveHostState {
	const processState = globalThis as typeof globalThis & {
		[interactiveHostKey]?: InteractiveHostState;
	};
	return (processState[interactiveHostKey] ??= {});
}
