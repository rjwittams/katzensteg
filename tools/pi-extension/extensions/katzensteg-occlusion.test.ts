import assert from "node:assert/strict";
import {
	chmodSync,
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
import type { Theme } from "@earendil-works/pi-coding-agent";
import { getCellDimensions, setCellDimensions } from "@earendil-works/pi-tui";
import type {
	SurfaceGeometry,
	SurfaceHandle,
	SurfaceRenderContext,
} from "@earendil-works/pi-tui";
import { SurfacePanel } from "./katzensteg-panel.js";

test("panel sends coverage on attach, updates stationary coverage and clears it on uncover", async () => {
	const dir = mkdtempSync(path.join(os.tmpdir(), "katzensteg-occlusion-test-"));
	const output = path.join(dir, "controls.jsonl");
	const executable = path.join(dir, "producer.cjs");
	writeFileSync(
		executable,
		`#!/usr/bin/env node
const fs = require("node:fs");
const readline = require("node:readline");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  fs.appendFileSync(${JSON.stringify(output)}, line + "\\n");
  const message = JSON.parse(line);
  if (message.type === "shutdown") process.exit(0);
  if (message.type === "attach") process.stdout.write(JSON.stringify({
    type: "frame_batch", window_id: "main", seq: 1,
    presentation_generation: message.presentation_generation,
    groups: { deletes: [], uploads: [], placements: [${JSON.stringify("\x1b_Ga=p,i=10,p=20;\x1b\\")}], after: [] }
  }) + "\\n");
});
`,
	);
	chmodSync(executable, 0o755);
	const previousCellDimensions = getCellDimensions();
	setCellDimensions({ widthPx: 13, heightPx: 29 });
	const previousBin = process.env.KATZENSTEG_BIN;
	process.env.KATZENSTEG_BIN = executable;
	let geometry: SurfaceGeometry = {
		bounds: { x: 2, y: 1, width: 20, height: 10 },
		clip: { x: 2, y: 1, width: 20, height: 10 },
		contentOffset: 0,
		occlusions: [{ x: 10, y: 3, width: 12, height: 8 }],
	};
	let onGeometry: Parameters<SurfaceHandle["onGeometryChange"]>[0] = () => {};
	let onRender: Parameters<SurfaceHandle["onRender"]>[0] = () => {};
	const writes: string[] = [];
	const frame = (disposed = false): SurfaceRenderContext => ({
		geometry: disposed ? undefined : geometry,
		revision: 0,
		graphicsInvalidation: "none",
		disposed,
		write: (data) => {
			writes.push(data);
			return true;
		},
	});
	const surface: SurfaceHandle = {
		getGeometry: () => geometry,
		onGeometryChange: (callback) => {
			onGeometry = callback;
			callback(geometry);
			return () => {};
		},
		onRender: (callback) => {
			onRender = callback;
			return () => {};
		},
		requestRender: () => {},
		dispose: () => onRender(frame(true)),
	};
	const panel = new SurfacePanel(
		{ fg: (_color: string, text: string) => text } as Theme,
		{ mode: "live", profile: "fixture", size: "medium" },
	);
	async function controls(count: number): Promise<Record<string, unknown>[]> {
		for (let attempt = 0; attempt < 100; attempt++) {
			const lines = existsSync(output)
				? readFileSync(output, "utf8").trim().split("\n").filter(Boolean)
				: [];
			if (lines.length >= count) return lines.map((line) => JSON.parse(line));
			await setTimeout(20);
		}
		throw new Error(`Timed out waiting for ${count} control messages`);
	}
	try {
		panel.attach(surface);
		onRender(frame());
		const attach = (await controls(1))[0];
		assert.equal(attach.type, "attach");
		const assertCellDimensions = (
			message: Record<string, unknown>,
			width: number,
			height: number,
		) => {
			const cells = message.terminal_cells as { rows: number; cols: number };
			const pixels = message.terminal_px as { w: number; h: number };
			assert.ok(
				cells && pixels,
				"host must send terminal cells and pixels together",
			);
			assert.equal(pixels.w / cells.cols, width);
			assert.equal(pixels.h / cells.rows, height);
		};
		assertCellDimensions(attach, 13, 29);
		assert.deepEqual(attach.occlusion_rects, [
			{ row: 5, col: 11, rows: 6, cols: 11 },
		]);
		for (
			let attempt = 0;
			attempt < 100 && !writes.join("").includes("a=p");
			attempt++
		) {
			onRender(frame());
			await setTimeout(20);
		}
		assert.match(writes.join(""), /a=p,i=10/);
		writes.length = 0;
		geometry = { ...geometry, occlusions: [geometry.clip] };
		onGeometry(geometry);
		onRender(frame());
		assert.match(
			writes.join(""),
			/a=d,d=i,i=10/,
			"full coverage removes old placements without waiting for a producer frame",
		);
		const covered = (await controls(2))[1];
		assert.equal(covered.type, "viewport");
		assertCellDimensions(covered, 13, 29);
		assert.deepEqual(covered.rect_cells, attach.rect_cells);
		assert.deepEqual(covered.occlusion_rects, [
			{ row: 5, col: 4, rows: 6, cols: 18 },
		]);
		assert.ok(
			Number(covered.presentation_generation) >
				Number(attach.presentation_generation),
		);
		geometry = { ...geometry, occlusions: [] };
		onGeometry(geometry);
		onRender(frame());
		assert.deepEqual((await controls(3))[2].occlusion_rects, []);
		// Pi's startup measurement may arrive after the first geometry callback.
		// A render with unchanged cell bounds must propagate the corrected ratio.
		setCellDimensions({ widthPx: 15, heightPx: 31 });
		onRender(frame());
		const corrected = (await controls(4))[3];
		assert.equal(corrected.type, "viewport");
		assertCellDimensions(corrected, 15, 31);
		assert.deepEqual(corrected.rect_cells, attach.rect_cells);
		assert.ok(
			Number(corrected.presentation_generation) >
				Number(covered.presentation_generation),
		);
		panel.dispose();
		assert.equal((await controls(5))[4].type, "shutdown");
	} finally {
		setCellDimensions(previousCellDimensions);
		panel.dispose();
		if (previousBin === undefined) delete process.env.KATZENSTEG_BIN;
		else process.env.KATZENSTEG_BIN = previousBin;
		rmSync(dir, { recursive: true, force: true });
	}
});
