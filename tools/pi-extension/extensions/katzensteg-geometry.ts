// Pure-function geometry helpers for the Katzensteg pi-extension panel.
// Extracted from katzensteg-panel.ts so they can be unit-tested without
// loading the full extension (which depends on pi-coding-agent at runtime).

import type { SurfaceRect } from "@earendil-works/pi-tui";

export interface RectCells {
	row: number;
	col: number;
	rows: number;
	cols: number;
}

// Chrome layout assumed by renderPanelChrome in katzensteg-panel.ts:
//   row 0: top border
//   row 1: title
//   row 2: status        <- last chrome row above body (VIEWPORT_ROW_OFFSET=3)
//   row 3..N-2: body
//   row N-1: bottom border
export const VIEWPORT_ROW_OFFSET = 3;
export const VIEWPORT_COL_OFFSET = 1;
export const FRAME_OVERHEAD_ROWS = 4;
export const FRAME_OVERHEAD_COLS = 2;

// Logical body rect of the message in 1-indexed terminal cells. May have a row
// less than 1 when the chrome rows have scrolled off the top of the viewport.
// The producer composes at this size; clip_cells (see clipCellsForBody) narrows
// the placement target to what is currently visible.
export function messageLogicalBodyRect(rect: SurfaceRect): RectCells | undefined {
	// pi-tui clamps to the visible viewport: rect.row is the visible top
	// (0-indexed) and rect.rows is the visible height. totalRows is the full
	// unclipped message height, regardless of which edges (top, bottom, both)
	// are currently clipped — see SurfaceRect's docstring in pi-tui. Recover
	// the logical message top:
	//   - top is on-screen (no top clip) when rect.row > 0; logical top = rect.row.
	//   - top is clipped when rect.row == 0 and rect.rows < rect.totalRows.
	//     The bottom edge is at rect.row + rect.rows - 1, so the logical top is
	//     that minus (totalRows - 1) = rect.row + rect.rows - rect.totalRows.
	//     This formula is also correct when both ends are clipped (totalRows
	//     exceeds the terminal viewport): rect.row==0, rect.rows==termRows.
	// Body height is always rect.totalRows - FRAME_OVERHEAD_ROWS, even when the
	// bottom is clipped — because totalRows is unclipped. clip_cells (computed
	// by clipCellsForBody) narrows the placement target to what is visible.
	const topClipped = rect.row === 0 && rect.rows < rect.totalRows;
	const messageTop0 = topClipped ? rect.row + rect.rows - rect.totalRows : rect.row;
	const row = messageTop0 + 1 + VIEWPORT_ROW_OFFSET;
	const col = rect.col + 1 + VIEWPORT_COL_OFFSET;
	const rows = rect.totalRows - FRAME_OVERHEAD_ROWS;
	const cols = rect.cols - FRAME_OVERHEAD_COLS;
	if (rows < 2 || cols < 2) return undefined;
	return { row, col, rows, cols };
}

// Visible intersection of the body rect with the message's visible window, in
// 1-indexed terminal cells. Returns undefined when the body is fully visible
// (producer treats absent clip as "no clipping"). Returns a zero-sized rect
// anchored at the body origin when nothing is visible — the producer reads that
// as "emit no placements".
export function clipCellsForBody(body: RectCells, rect: SurfaceRect): RectCells | undefined {
	// Columns: pi-tui's chat layout never presents horizontal overflow for inline
	// messages (rect.col is always 0 and rect.cols always equals the terminal
	// column count), so the body's columns can pass through unchanged. If pi-tui
	// ever supports horizontal scroll, this needs a column intersection too.
	const msgVisTop = rect.row + 1; // 1-indexed visible top of the whole message
	const msgVisBottom = rect.row + rect.rows; // 1-indexed inclusive
	const bodyTop = body.row;
	const bodyBottom = body.row + body.rows - 1;
	const top = Math.max(bodyTop, msgVisTop);
	const bottom = Math.min(bodyBottom, msgVisBottom);
	if (bottom < top) {
		return { row: body.row, col: body.col, rows: 0, cols: 0 };
	}
	if (top === bodyTop && bottom === bodyBottom) return undefined;
	return { row: top, col: body.col, rows: bottom - top + 1, cols: body.cols };
}

// Status line lives at message-internal row 2 (the last of the
// VIEWPORT_ROW_OFFSET=3 chrome rows above the body). It's visible iff
// strictly fewer rows than the full chrome have scrolled off the top.
// Returns false when rect is undefined (fully off-screen).
export function statusLineVisible(rect: SurfaceRect | undefined): boolean {
	if (!rect) return false;
	const topClipped = rect.row === 0 && rect.rows < rect.totalRows;
	if (!topClipped) return true;
	const rowsScrolledOff = rect.totalRows - rect.rows;
	return rowsScrolledOff < VIEWPORT_ROW_OFFSET;
}
