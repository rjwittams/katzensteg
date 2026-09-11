import assert from "node:assert/strict";
import {
	existsSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { setTimeout } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import type { Theme } from "@earendil-works/pi-coding-agent";
import type {
	SurfaceGeometry,
	SurfaceHandle,
	SurfaceRenderContext,
} from "@earendil-works/pi-tui";
import { SurfacePanel } from "./katzensteg-panel.js";

const launcher = fileURLToPath(
	new URL("../../../zig-out/bin/katzensteg", import.meta.url),
);

function alive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		if (error instanceof Error && "code" in error && error.code === "ESRCH")
			return false;
		throw error;
	}
}

test(
	"closing a panel lets the launcher reap a child that ignores TERM",
	{
		skip:
			process.platform === "win32" || !existsSync(launcher)
				? "requires the built POSIX launcher"
				: false,
	},
	async () => {
		const dir = mkdtempSync(
			path.join(os.tmpdir(), "katzensteg-shutdown-test-"),
		);
		const pidFile = path.join(dir, "child.json");
		const fixture = path.join(dir, "child.cjs");
		writeFileSync(
			fixture,
			`const fs = require("node:fs");
process.on("SIGTERM", () => {});
fs.writeFileSync(${JSON.stringify(pidFile)}, JSON.stringify({pid: process.pid, parent: process.ppid, config: process.env.KATZENSTEG_CONFIG}));
setInterval(() => {}, 1000);
`,
		);
		writeFileSync(
			path.join(dir, "profiles.json"),
			JSON.stringify({
				profiles: {
					"test.shutdown": { target: process.execPath, args: [fixture] },
				},
			}),
		);
		const previousBin = process.env.KATZENSTEG_BIN;
		const previousProfiles = process.env.KATZENSTEG_PROFILE_DIR;
		process.env.KATZENSTEG_BIN = launcher;
		process.env.KATZENSTEG_PROFILE_DIR = dir;
		const geometry: SurfaceGeometry = {
			bounds: { x: 0, y: 0, width: 56, height: 20 },
			clip: { x: 0, y: 0, width: 56, height: 20 },
			contentOffset: 0,
		};
		let render: Parameters<SurfaceHandle["onRender"]>[0] = () => {};
		const frame = (disposed = false): SurfaceRenderContext => ({
			geometry: disposed ? undefined : geometry,
			revision: 1,
			graphicsInvalidation: "none",
			disposed,
			write: () => true,
		});
		const panel = new SurfacePanel(
			{ fg: (_color: string, text: string) => text } as Theme,
			{ mode: "live", profile: "test.shutdown", size: "medium" },
		);
		try {
			panel.attach({
				getGeometry: () => geometry,
				onGeometryChange: (callback) => {
					callback(geometry);
					return () => {};
				},
				onRender: (callback) => {
					render = callback;
					return () => {};
				},
				requestRender: () => {},
				dispose: () => render(frame(true)),
			});
			render(frame());
			for (let i = 0; i < 100 && !existsSync(pidFile); i++)
				await setTimeout(20);
			assert.ok(
				existsSync(pidFile),
				"fixture child must reach its TERM handler before close",
			);
			const child: { pid: number; parent: number } = JSON.parse(
				readFileSync(pidFile, "utf8"),
			);
			panel.dispose();
			for (let i = 0; i < 225 && (alive(child.pid) || alive(child.parent)); i++)
				await setTimeout(20);
			assert.equal(
				alive(child.pid),
				false,
				"launcher must finish SIGKILL escalation and reap the child",
			);
			assert.equal(
				alive(child.parent),
				false,
				"launcher must exit after cleanup",
			);
		} finally {
			panel.dispose();
			if (previousBin === undefined) delete process.env.KATZENSTEG_BIN;
			else process.env.KATZENSTEG_BIN = previousBin;
			if (previousProfiles === undefined)
				delete process.env.KATZENSTEG_PROFILE_DIR;
			else process.env.KATZENSTEG_PROFILE_DIR = previousProfiles;
			if (existsSync(pidFile)) {
				const child: { pid: number; parent: number; config?: string } =
					JSON.parse(readFileSync(pidFile, "utf8"));
				if (alive(child.pid)) process.kill(child.pid, "SIGKILL");
				if (alive(child.parent)) process.kill(child.parent, "SIGTERM");
				if (child.config) rmSync(child.config, { force: true });
			}
			rmSync(dir, { recursive: true, force: true });
		}
	},
);
