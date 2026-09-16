import assert from "node:assert/strict";
import test from "node:test";
import type { Theme } from "@earendil-works/pi-coding-agent";
import type { TuiMouseEvent } from "@earendil-works/pi-tui";
import { SurfacePanel } from "./katzensteg-panel.js";

function fixture() {
	let cancellations = 0;
	let raises = 0;
	const sent: object[] = [];
	const panel = new SurfacePanel(
		{} as Theme,
		{ mode: "layout", profile: "test", size: "medium" },
		() => {},
		0,
		() => raises++,
	);
	// Supply the producer boundary without launching a game or terminal.
	Object.assign(panel, {
		geometry: { bounds: { x: 0, y: 0, width: 56, height: 20 } },
		producer: {
			game: { cancel: () => cancellations++ },
			sendInput: (message: object) => sent.push(message),
			stop: () => {},
		},
	});
	return {
		panel,
		sent,
		cancellations: () => cancellations,
		raises: () => raises,
	};
}
function pointer(
	type: TuiMouseEvent["type"],
	x: number,
	y: number,
): TuiMouseEvent {
	return {
		type,
		button: "left",
		x,
		y,
		screenX: x,
		screenY: y,
		width: 56,
		height: 20,
		shift: false,
		alt: false,
		ctrl: false,
	};
}

test("title and edge gestures preserve focus and agent control", async () => {
	for (const focused of [false, true]) {
		for (const [x, y] of [
			[5, 1],
			[0, 0],
			[55, 19],
		]) {
			const f = fixture();
			f.panel.focused = focused;
			const before = f.cancellations();
			try {
				assert.equal(
					f.panel.handleMouse(pointer("press", x, y))?.focus,
					undefined,
				);
				f.panel.handleMouse(pointer("drag", x + 2, y + 2));
				f.panel.handleMouse(pointer("release", x + 2, y + 2));
				await Promise.resolve();
				assert.equal(f.cancellations(), before);
				assert.equal(f.raises(), 0);
				assert.equal(f.panel.focused, focused);
				assert.deepEqual(f.sent, []);
			} finally {
				f.panel.dispose();
			}
		}
	}
});

test("unfocused hover and wheel leave the game alone; a body press takes control", async () => {
	const f = fixture();
	try {
		f.panel.handleMouse(pointer("move", 5, 5));
		f.panel.handleMouse(pointer("wheel", 5, 5));
		f.panel.handleMouse(pointer("press", 5, 2));
		assert.equal(f.cancellations(), 0);
		assert.deepEqual(f.sent, []);
		assert.equal(f.panel.handleMouse(pointer("press", 5, 5))?.focus, true);
		await Promise.resolve();
		assert.equal(f.cancellations(), 1);
		assert.equal(f.raises(), 1);
		assert.equal(f.sent.length, 1);
	} finally {
		f.panel.dispose();
	}
});

test("focus acquisition and keyboard input take control", () => {
	const f = fixture();
	try {
		f.panel.focused = true;
		assert.equal(f.cancellations(), 1);
		f.panel.focused = true;
		f.panel.focused = false;
		assert.equal(f.cancellations(), 1);
		f.panel.handleInput("a");
		assert.equal(f.cancellations(), 2);
		assert.equal(f.sent.length, 2);
		assert.match(JSON.stringify(f.sent[0]), /001b\[O/);
	} finally {
		f.panel.dispose();
	}
});
