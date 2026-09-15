import assert from "node:assert/strict";
import test from "node:test";
import type {
	OverlayOptions,
	SurfaceRect,
	TuiMouseEvent,
} from "@earendil-works/pi-tui";
import { PanelWindowControls } from "./katzensteg-window.js";

function pointer(
	type: TuiMouseEvent["type"],
	x: number,
	y: number,
	screenX = x,
	screenY = y,
): TuiMouseEvent {
	return {
		type,
		button: "left",
		x,
		y,
		screenX,
		screenY,
		width: 56,
		height: 20,
		shift: false,
		ctrl: false,
		alt: false,
	};
}
test("a new title drag starts at the last clamped bounds", () => {
	let bounds: SurfaceRect = { x: 4, y: 3, width: 56, height: 20 };
	const updates: Partial<OverlayOptions>[] = [];
	const controls = new PanelWindowControls(
		() => bounds,
		(options) => updates.push(options),
		() => {},
	);
	assert.deepEqual(controls.handle(pointer("press", 4, 1, 8, 4)), {
		capture: true,
		handled: true,
	});
	controls.handle(pointer("drag", 4, 30, 8, 33));
	assert.equal(updates.at(-1)?.row, 32);
	bounds = { ...bounds, y: 11 }; // host clamped at bottom
	controls.handle(pointer("release", 4, 22, 8, 33));
	controls.handle(pointer("press", 4, 1, 8, 12));
	controls.handle(pointer("drag", 6, -2, 10, 9));
	assert.deepEqual(updates.at(-1), { col: 6, row: 8, width: 56, height: 20 });
});
test("top-left resizing preserves the opposite corner at minimum size", () => {
	const updates: Partial<OverlayOptions>[] = [];
	const controls = new PanelWindowControls(
		() => ({ x: 4, y: 3, width: 56, height: 20 }),
		(options) => updates.push(options),
		() => {},
	);
	controls.handle(pointer("press", 0, 0, 4, 3));
	controls.handle(pointer("drag", 30, 30, 34, 33));
	assert.deepEqual(updates.at(-1), { col: 18, row: 13, width: 42, height: 10 });
});
test("bottom-right resize changes both dimensions and cancellation stops it", () => {
	const updates: Partial<OverlayOptions>[] = [];
	const controls = new PanelWindowControls(
		() => ({ x: 0, y: 0, width: 56, height: 20 }),
		(options) => updates.push(options),
		() => {},
	);
	controls.handle(pointer("press", 55, 19));
	controls.handle(pointer("drag", 60, 23));
	assert.deepEqual(updates.at(-1), { col: 0, row: 0, width: 61, height: 24 });
	controls.cancel();
	assert.equal(controls.handle(pointer("drag", 65, 25)), undefined);
	assert.equal(updates.length, 1);
});
test("close button closes; body input is not consumed", () => {
	let closed = 0;
	const controls = new PanelWindowControls(
		() => ({ x: 0, y: 0, width: 56, height: 20 }),
		() => {},
		() => closed++,
	);
	assert.equal(controls.handle(pointer("press", 10, 5)), undefined);
	assert.deepEqual(controls.handle(pointer("press", 54, 0)), { handled: true });
	assert.equal(closed, 1);
});
