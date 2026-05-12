import test from "node:test";
import assert from "node:assert/strict";
import type { PointerEvent } from "@earendil-works/pi-tui";

import {
	makePointerInputMessage,
	makeTerminalBytesInputMessage,
	pointerEventToWire,
} from "./katzensteg-input.js";

function pointer(over: Partial<PointerEvent>): PointerEvent {
	return {
		type: "pointermove",
		row: 0,
		col: 0,
		button: 3,
		buttons: 0,
		deltaX: 0,
		deltaY: 0,
		shiftKey: false,
		altKey: false,
		ctrlKey: false,
		metaKey: false,
		...over,
	};
}

test("pointerdown encodes 1-indexed cells, real button, modifier flags", () => {
	const event = pointer({ type: "pointerdown", row: 4, col: 9, button: 0, buttons: 1, shiftKey: true });
	const wire = pointerEventToWire(event);
	assert.deepEqual(wire, {
		event: "pointer",
		kind: "pointerdown",
		row: 5,
		col: 10,
		button: 0,
		buttons: 1,
		modifiers: { shift: true, ctrl: false, alt: false, meta: false },
		pointer_type: "mouse",
	});
});

test("pointerup carries the released button index", () => {
	const event = pointer({ type: "pointerup", row: 2, col: 3, button: 2, buttons: 0 });
	const wire = pointerEventToWire(event);
	assert.equal(wire.kind, "pointerup");
	assert.equal(wire.button, 2);
	assert.equal(wire.buttons, 0);
});

test("pointermove sets button=-1 (DOM convention) regardless of pi-tui's button=3 overload", () => {
	// pi-tui emits button=3 for motion without a specific button change. We
	// translate that to -1 on the wire so producers (and other hosts) don't
	// have to know about pi-tui's quirk.
	const event = pointer({ type: "pointermove", row: 1, col: 1, button: 3, buttons: 1 });
	const wire = pointerEventToWire(event);
	assert.equal(wire.button, -1);
	// buttons bitmask still reports what's held during the drag.
	assert.equal(wire.buttons, 1);
});

test("wheel includes delta fields and line-mode default", () => {
	const event = pointer({ type: "wheel", deltaY: -1, button: 3 });
	const wire = pointerEventToWire(event);
	assert.equal(wire.kind, "wheel");
	assert.equal(wire.button, -1);
	assert.equal(wire.delta_x, 0);
	assert.equal(wire.delta_y, -1);
	assert.equal(wire.delta_mode, "line");
});

test("non-wheel events omit delta fields entirely", () => {
	const wire = pointerEventToWire(pointer({ type: "pointerdown", button: 0 }));
	assert.equal("delta_x" in wire, false);
	assert.equal("delta_y" in wire, false);
	assert.equal("delta_mode" in wire, false);
});

test("modifiers serialize each flag independently", () => {
	const wire = pointerEventToWire(pointer({ shiftKey: true, ctrlKey: true, altKey: false, metaKey: true }));
	assert.deepEqual(wire.modifiers, { shift: true, ctrl: true, alt: false, meta: true });
});

test("makePointerInputMessage wraps payload in the input envelope", () => {
	const msg = makePointerInputMessage("main", pointer({ type: "pointerdown", row: 0, col: 0, button: 0, buttons: 1 }));
	assert.equal(msg.type, "input");
	assert.equal(msg.window_id, "main");
	assert.equal(msg.event, "pointer");
	assert.equal(msg.kind, "pointerdown");
});

test("makeTerminalBytesInputMessage carries raw bytes string", () => {
	const msg = makeTerminalBytesInputMessage("main", "\x1b[A");
	assert.deepEqual(msg, { type: "input", window_id: "main", event: "terminal_bytes", bytes: "\x1b[A" });
});

test("multi-button buttons bitmask passes through verbatim", () => {
	// Left + middle held simultaneously (bits 0 and 1 set).
	const wire = pointerEventToWire(pointer({ buttons: 0b011 }));
	assert.equal(wire.buttons, 0b011);
});

test("button index 3 (back) and 4 (forward) round-trip even though pi-tui doesn't currently emit them", () => {
	// Forward-compatibility check: our protocol allows the extended buttons
	// even though pi-tui's SGR parser currently only emits 0-2.
	const wireBack = pointerEventToWire(pointer({ type: "pointerdown", button: 3, buttons: 0b1000 }));
	assert.equal(wireBack.button, 3);
	assert.equal(wireBack.buttons, 0b1000);
	const wireForward = pointerEventToWire(pointer({ type: "pointerdown", button: 4, buttons: 0b10000 }));
	assert.equal(wireForward.button, 4);
	assert.equal(wireForward.buttons, 0b10000);
});
