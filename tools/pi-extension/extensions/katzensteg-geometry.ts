import type { SurfaceGeometry } from "@earendil-works/pi-tui";

export interface RectCells {
	row: number;
	col: number;
	rows: number;
	cols: number;
}
export const VIEWPORT_ROW_OFFSET = 3;
export const VIEWPORT_COL_OFFSET = 1;
export const FRAME_OVERHEAD_ROWS = 4;
export const FRAME_OVERHEAD_COLS = 2;

/** Full logical body, in the producer's one-based terminal cells. */
export function messageLogicalBodyRect(
	geometry: SurfaceGeometry,
): RectCells | undefined {
	const { bounds, contentOffset } = geometry;
	const rows = bounds.height - FRAME_OVERHEAD_ROWS;
	const cols = bounds.width - FRAME_OVERHEAD_COLS;
	if (rows < 2 || cols < 2) return undefined;
	return {
		row: bounds.y - contentOffset + 1 + VIEWPORT_ROW_OFFSET,
		col: bounds.x + 1 + VIEWPORT_COL_OFFSET,
		rows,
		cols,
	};
}

/** Undefined means fully visible; a zero-sized clip suppresses placements. */
export function clipCellsForBody(
	body: RectCells,
	{ clip }: SurfaceGeometry,
): RectCells | undefined {
	const row = Math.max(body.row, clip.y + 1);
	const col = Math.max(body.col, clip.x + 1);
	const rows = Math.max(
		0,
		Math.min(body.row + body.rows, clip.y + clip.height + 1) - row,
	);
	const cols = Math.max(
		0,
		Math.min(body.col + body.cols, clip.x + clip.width + 1) - col,
	);
	if (!rows || !cols) return { row: body.row, col: body.col, rows: 0, cols: 0 };
	if (
		row === body.row &&
		col === body.col &&
		rows === body.rows &&
		cols === body.cols
	)
		return undefined;
	return { row, col, rows, cols };
}

export function statusLineVisible(
	geometry: SurfaceGeometry | undefined,
): boolean {
	if (!geometry) return false;
	const y =
		geometry.bounds.y - geometry.contentOffset + VIEWPORT_ROW_OFFSET - 1;
	return (
		geometry.clip.width > 0 &&
		y >= geometry.clip.y &&
		y < geometry.clip.y + geometry.clip.height
	);
}

/** Occluders use absolute terminal coordinates, just like the body and clip. */
export function occlusionCellsForBody(
	body: RectCells,
	geometry: SurfaceGeometry,
): RectCells[] {
	const clip = clipCellsForBody(body, geometry) ?? body;
	return (geometry.occlusions ?? []).flatMap((rect) => {
		const row = Math.max(clip.row, rect.y + 1);
		const col = Math.max(clip.col, rect.x + 1);
		const rows = Math.min(clip.row + clip.rows, rect.y + 1 + rect.height) - row;
		const cols = Math.min(clip.col + clip.cols, rect.x + 1 + rect.width) - col;
		return rows > 0 && cols > 0 ? [{ row, col, rows, cols }] : [];
	});
}

/** Test the union of occluders, including several overlays covering the body together. */
export function bodyHasVisibleCells(
	body: RectCells,
	clip: RectCells | undefined,
	occlusions: readonly RectCells[],
): boolean {
	let regions = [clip ?? body];
	for (const cover of occlusions) {
		regions = regions.flatMap((rect) => {
			const top = Math.max(rect.row, cover.row);
			const left = Math.max(rect.col, cover.col);
			const bottom = Math.min(rect.row + rect.rows, cover.row + cover.rows);
			const right = Math.min(rect.col + rect.cols, cover.col + cover.cols);
			if (top >= bottom || left >= right) return [rect];
			return [
				{ ...rect, rows: top - rect.row },
				{ ...rect, row: bottom, rows: rect.row + rect.rows - bottom },
				{ row: top, col: rect.col, rows: bottom - top, cols: left - rect.col },
				{
					row: top,
					col: right,
					rows: bottom - top,
					cols: rect.col + rect.cols - right,
				},
			].filter((piece) => piece.rows > 0 && piece.cols > 0);
		});
	}
	return regions.some((rect) => rect.rows > 0 && rect.cols > 0);
}
