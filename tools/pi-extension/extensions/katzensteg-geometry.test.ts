import test from "node:test";
import assert from "node:assert/strict";
import type { SurfaceRect } from "@earendil-works/pi-tui";

import {
	clipCellsForBody,
	messageLogicalBodyRect,
	statusLineVisible,
	FRAME_OVERHEAD_COLS,
	FRAME_OVERHEAD_ROWS,
} from "./katzensteg-geometry.js";

// All rects below use a 20-row message (matches the "medium" size preset).
// Body height after chrome subtraction is 20 - 4 = 16 rows.
const TOTAL = 20;
const COLS = 80;

function rect(over: Partial<SurfaceRect>): SurfaceRect {
	return { row: 0, col: 0, rows: TOTAL, cols: COLS, totalRows: TOTAL, ...over };
}

test("messageLogicalBodyRect: fully visible, anchored below the top", () => {
	const r = rect({ row: 5, rows: TOTAL });
	const body = messageLogicalBodyRect(r);
	assert.deepEqual(body, { row: 9, col: 2, rows: 16, cols: 78 });
	assert.equal(clipCellsForBody(body!, r), undefined);
});

test("messageLogicalBodyRect: fully visible at top of viewport (rect.row=0, no clip)", () => {
	const r = rect({ row: 0, rows: TOTAL });
	const body = messageLogicalBodyRect(r);
	assert.deepEqual(body, { row: 4, col: 2, rows: 16, cols: 78 });
	assert.equal(clipCellsForBody(body!, r), undefined);
});

test("messageLogicalBodyRect: partial top clip pushes body.row below 1", () => {
	// 8 rows have scrolled off the top: rect.rows=12, rect.row=0, totalRows=20.
	// Logical message top is at terminal row -8 (0-indexed). Body sits +4 lower
	// (chrome offset), so body.row = -8 + 1 + 3 = -4 (1-indexed).
	const r = rect({ row: 0, rows: 12 });
	const body = messageLogicalBodyRect(r);
	assert.deepEqual(body, { row: -4, col: 2, rows: 16, cols: 78 });
	// Visible portion of message is rows 1..12 (1-indexed). Body spans -4..11.
	// Intersection: 1..11 (11 rows).
	assert.deepEqual(clipCellsForBody(body!, r), { row: 1, col: 2, rows: 11, cols: 78 });
});

test("messageLogicalBodyRect: bottom clip leaves logical top equal to rect.row", () => {
	// Top stays on-screen (rect.row=10), bottom clipped: rect.rows=8, totalRows=20.
	const r = rect({ row: 10, rows: 8 });
	const body = messageLogicalBodyRect(r);
	assert.deepEqual(body, { row: 14, col: 2, rows: 16, cols: 78 });
	// Visible portion of message: rows 11..18. Body: 14..29.
	// Intersection: 14..18 (5 rows).
	assert.deepEqual(clipCellsForBody(body!, r), { row: 14, col: 2, rows: 5, cols: 78 });
});

test("messageLogicalBodyRect: both ends clipped (totalRows > visible)", () => {
	// rect.row=0, rect.rows=10, totalRows=20 means top is clipped. The
	// formula is identical whether or not the bottom is also clipped; clip_cells
	// expresses the visible portion regardless.
	const r = rect({ row: 0, rows: 10 });
	const body = messageLogicalBodyRect(r);
	assert.deepEqual(body, { row: -6, col: 2, rows: 16, cols: 78 });
	assert.deepEqual(clipCellsForBody(body!, r), { row: 1, col: 2, rows: 9, cols: 78 });
});

test("messageLogicalBodyRect: zero-sized clip when body rows < 2 after chrome", () => {
	// totalRows=5 → body rows = 5 - 4 = 1, below the 2-row minimum.
	const r = rect({ row: 0, rows: 5, totalRows: 5 });
	assert.equal(messageLogicalBodyRect(r), undefined);
});

test("clipCellsForBody: zero-sized when nothing visible", () => {
	// Message is fully off-screen above the body: visTop=1, visBottom=0 → empty.
	const r = rect({ row: 0, rows: 0 });
	// messageLogicalBodyRect won't be called with rows=0 in practice, but the
	// clip function should still handle the no-intersection case cleanly.
	const body = { row: 4, col: 2, rows: 16, cols: 78 };
	const clip = clipCellsForBody(body, r);
	assert.deepEqual(clip, { row: 4, col: 2, rows: 0, cols: 0 });
});

test("clipCellsForBody: returns undefined when body fully inside visible", () => {
	const r = rect({ row: 5, rows: TOTAL });
	const body: ReturnType<typeof messageLogicalBodyRect> = { row: 9, col: 2, rows: 16, cols: 78 };
	assert.equal(clipCellsForBody(body!, r), undefined);
});

test("statusLineVisible: fully visible message", () => {
	assert.equal(statusLineVisible(rect({ row: 5, rows: TOTAL })), true);
});

test("statusLineVisible: top-clipped but status row still visible (2 rows off)", () => {
	// rowsScrolledOff = 2 → status row (index 2) is the first visible row.
	assert.equal(statusLineVisible(rect({ row: 0, rows: TOTAL - 2 })), true);
});

test("statusLineVisible: status row just scrolled off (3 rows off)", () => {
	assert.equal(statusLineVisible(rect({ row: 0, rows: TOTAL - 3 })), false);
});

test("statusLineVisible: status row deep above the viewport", () => {
	assert.equal(statusLineVisible(rect({ row: 0, rows: 5 })), false);
});

test("statusLineVisible: bottom-clipped (rect.row > 0) — top is visible", () => {
	// rect.row > 0 implies no top clip; chrome rows including status are visible.
	assert.equal(statusLineVisible(rect({ row: 10, rows: 8 })), true);
});

test("statusLineVisible: undefined rect (fully off-screen)", () => {
	assert.equal(statusLineVisible(undefined), false);
});

// Sanity check that the constants match the chrome layout assumed by tests.
test("chrome constants match comment in renderPanelChrome", () => {
	assert.equal(FRAME_OVERHEAD_ROWS, 4);
	assert.equal(FRAME_OVERHEAD_COLS, 2);
});
