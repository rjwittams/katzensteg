import assert from "node:assert/strict";
import test from "node:test";
import type { TuiMouseEvent } from "@earendil-works/pi-tui";
import {
	makeTerminalBytesInputMessage,
	PointerInput,
} from "./katzensteg-input.js";

test("standalone Escape is sent as a complete key sequence", () => {
	assert.equal(makeTerminalBytesInputMessage("main", "\x1b").bytes, "\x1b[27u");
});

function pointer(over: Partial<TuiMouseEvent> = {}): TuiMouseEvent {
	return {
		type: "move",
		button: "none",
		x: 2,
		y: 3,
		screenX: 9,
		screenY: 4,
		width: 40,
		height: 20,
		shift: false,
		alt: false,
		ctrl: false,
		...over,
	};
}
test("press uses screen coordinates, modifiers, and held-button state", () => {
	const input = new PointerInput();
	const wire = input.encode(
		"main",
		pointer({ type: "press", button: "left", shift: true }),
	);
	assert.ok(wire);
	assert.deepEqual(wire, {
		type: "input",
		window_id: "main",
		event: "pointer",
		kind: "pointerdown",
		row: 5,
		col: 10,
		button: 0,
		buttons: 1,
		modifiers: { shift: true, ctrl: false, alt: false, meta: false },
		pointer_type: "mouse",
	});
	assert.equal(
		input.encode("main", pointer({ type: "drag", button: "left" }))?.buttons,
		1,
	);
	assert.equal(
		input.encode("main", pointer({ type: "release", button: "left" }))?.buttons,
		0,
	);
});
test("wheel forwards physical steps, not accelerated scrolling", () => {
	const wire = new PointerInput().encode(
		"main",
		pointer({ type: "wheel", wheelDelta: -10, wheelSteps: -1 }),
	);
	assert.ok(wire);
	assert.equal(wire.delta_y, -1);
	assert.equal(wire.delta_mode, "line");
	assert.equal(wire.button, -1);
});
test("capture cancellation releases each button exactly once", () => {
	const input = new PointerInput();
	input.encode("main", pointer({ type: "press", button: "left" }));
	input.encode("main", pointer({ type: "press", button: "right" }));
	const releases = input.cancel("main");
	assert.deepEqual(
		releases.map((event) => [event.kind, event.button, event.buttons]),
		[
			["pointerup", 0, 4],
			["pointerup", 2, 0],
		],
	);
	assert.deepEqual(input.cancel("main"), []);
});
test("synthetic clicks are ignored and key bytes are preserved", () => {
	assert.equal(
		new PointerInput().encode("main", pointer({ type: "click" })),
		undefined,
	);
	assert.deepEqual(makeTerminalBytesInputMessage("main", "\x1b[A"), {
		type: "input",
		window_id: "main",
		event: "terminal_bytes",
		bytes: "\x1b[A",
	});
});
