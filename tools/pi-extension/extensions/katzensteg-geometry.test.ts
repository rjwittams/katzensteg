import assert from "node:assert/strict";
import test from "node:test";
import type { SurfaceGeometry } from "@earendil-works/pi-tui";
import {
	bodyHasVisibleCells,
	clipCellsForBody,
	messageLogicalBodyRect,
	occlusionCellsForBody,
	statusLineVisible,
} from "./katzensteg-geometry.js";

function geometry(
	y: number,
	clipY: number,
	clipHeight: number,
	x = 0,
	clipX = 0,
	clipWidth = 80,
): SurfaceGeometry {
	return {
		bounds: { x, y, width: 80, height: 20 },
		clip: { x: clipX, y: clipY, width: clipWidth, height: clipHeight },
		contentOffset: 0,
	};
}

test("fully visible body uses one-based cells", () => {
	const g = geometry(5, 5, 20);
	const body = messageLogicalBodyRect(g);
	assert.ok(body);
	assert.deepEqual(body, { row: 9, col: 2, rows: 16, cols: 78 });
	assert.equal(clipCellsForBody(body, g), undefined);
});

test("occlusion uses absolute cells, clips to the visible body and excludes chrome", () => {
	const g = geometry(-8, 0, 6);
	g.occlusions = [
		{ x: 0, y: 1, width: 20, height: 10 },
		{ x: 79, y: 0, width: 1, height: 6 },
	];
	const body = messageLogicalBodyRect(g)!;
	assert.deepEqual(occlusionCellsForBody(body, g), [
		{ row: 2, col: 2, rows: 5, cols: 19 },
	]);
});

test("visibility subtracts overlapping occluders without mistaking small gaps for full coverage", () => {
	const body = { row: 4, col: 2, rows: 16, cols: 78 };
	const covers = [
		{ ...body, cols: 40 },
		{ ...body, col: 40, cols: 40 },
	];
	assert.equal(bodyHasVisibleCells(body, undefined, covers), false);
	assert.equal(
		bodyHasVisibleCells(body, undefined, [
			{ ...covers[0], cols: 37 },
			covers[1],
		]),
		true,
	);
	assert.equal(bodyHasVisibleCells(body, { ...body, rows: 0 }, []), false);
	assert.equal(
		bodyHasVisibleCells(body, { ...body, cols: 30 }, [covers[0]]),
		false,
	);
});
test("bottom clipping at row zero must not imply top clipping", () => {
	const g = geometry(0, 0, 10);
	const body = messageLogicalBodyRect(g);
	assert.ok(body);
	assert.deepEqual(body, { row: 4, col: 2, rows: 16, cols: 78 });
	assert.deepEqual(clipCellsForBody(body, g), {
		row: 4,
		col: 2,
		rows: 7,
		cols: 78,
	});
});
test("top and both-edge clipping preserve logical dimensions", () => {
	for (const height of [12, 6]) {
		const g = geometry(-8, 0, height);
		const body = messageLogicalBodyRect(g);
		assert.ok(body);
		assert.deepEqual(body, { row: -4, col: 2, rows: 16, cols: 78 });
		assert.deepEqual(clipCellsForBody(body, g), {
			row: 1,
			col: 2,
			rows: Math.min(height, 11),
			cols: 78,
		});
	}
});
test("horizontal clipping intersects both edges", () => {
	const g = geometry(0, 0, 20, -10, 0, 40);
	const body = messageLogicalBodyRect(g);
	assert.ok(body);
	assert.deepEqual(clipCellsForBody(body, g), {
		row: 4,
		col: 1,
		rows: 16,
		cols: 40,
	});
});
test("absent visible body uses a zero clip", () => {
	const g = geometry(0, 0, 2);
	const body = messageLogicalBodyRect(g);
	assert.ok(body);
	assert.deepEqual(clipCellsForBody(body, g), {
		row: 4,
		col: 2,
		rows: 0,
		cols: 0,
	});
});
test("content offset shifts logical content and status", () => {
	const g = { ...geometry(0, 0, 10), contentOffset: 4 };
	assert.equal(messageLogicalBodyRect(g)?.row, 0);
	assert.equal(statusLineVisible(g), false);
});
test("small allocations have no body", () => {
	const g = geometry(0, 0, 20);
	g.bounds.height = 5;
	assert.equal(messageLogicalBodyRect(g), undefined);
});
test("status visibility follows the actual clip", () => {
	assert.equal(statusLineVisible(geometry(-2, 0, 18)), true);
	assert.equal(statusLineVisible(geometry(-3, 0, 17)), false);
	assert.equal(statusLineVisible(geometry(10, 10, 2)), false);
	assert.equal(statusLineVisible(geometry(0, 0, 0)), false);
	assert.equal(statusLineVisible(undefined), false);
});
