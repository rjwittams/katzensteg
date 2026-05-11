# Surface Lab v1: Pointer Events for Overlays Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land structured pointer events with cell coordinates and click-to-focus for floating overlays in `pi-mono`'s TUI, with Pi-enforced Esc / click-outside release. Ship a `surface-lab floating` extension that demonstrates a plugin consuming those events with pixel awareness.

**Architecture:** Pi (`pi-mono` repo) parses SGR mouse sequences in TUI, owns mouse-mode lifecycle, dispatches structured pointer events through `OverlayHandle.onPointer` subscriptions. Click-to-focus on overlay components extends Pi's existing `focusedComponent` model with a "plugin focus" flag so TUI can intercept Esc and route it back to composer before the plugin sees it. The `surface-lab` extension in `katzensteg.cheshire` is the first consumer.

**Tech Stack:** TypeScript, Node.js `node --test`, `tsx`, biome lint/format. Two repos: `~/dev/pi-mono` (TUI + extension API surface), `~/dev/katzensteg.cheshire` (lab extension).

**Out of scope this plan (deferred to v2):** Inline `MessageHandle` for `registerMessageRenderer` components, click-to-focus on inline components, scroll-out auto-release, inline variant of the lab. v2 starts with an investigation task into how `interactive-mode.ts` renders chat messages.

---

## Pre-flight: Repo state

### Task 0: Verify pi-mono baseline

**Files:**
- Read: `/Users/robert/dev/pi-mono/packages/tui/package.json` (informational)

The demo lives in-tree at `pi-mono/packages/coding-agent/examples/extensions/terminal-surface-demo.ts`, so no cross-repo npm-link work is needed. The unrelated `katzensteg.cheshire/tools/pi-extension/` peer-deps were updated from `@mariozechner/...` to `@earendil-works/...` separately (drive-by fix; not a v1 concern).

- [x] **Step 1: Branch base confirmed.** Working off `katzensteg-terminal-surface` HEAD (commit `912374fa`, which checkpoints the WIP that v1 supersedes).

- [ ] **Step 2: Confirm pi-mono baseline builds and tests pass**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && npm test
```

Expected: all existing tests pass. If any fail, **stop and surface to user** — we should not start work on a broken baseline.

---

## Chunk 1: SGR Pointer Parser (pi-mono)

### Task 1: Pure SGR pointer-event parser

**Files:**
- Create: `/Users/robert/dev/pi-mono/packages/tui/src/pointer-events.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/pointer-events.test.ts`
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/index.ts`

- [ ] **Step 1: Write failing tests**

Create `/Users/robert/dev/pi-mono/packages/tui/test/pointer-events.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import { parsePointerEvent } from "../src/pointer-events.js";

describe("parsePointerEvent", () => {
	it("parses a left-button press", () => {
		const ev = parsePointerEvent("\x1b[<0;10;5M");
		assert.deepStrictEqual(ev, {
			type: "pointerdown",
			row: 4,
			col: 9,
			button: 0,
			buttons: 1,
			deltaX: 0,
			deltaY: 0,
			shiftKey: false,
			altKey: false,
			ctrlKey: false,
			metaKey: false,
		});
	});

	it("parses a left-button release", () => {
		const ev = parsePointerEvent("\x1b[<0;10;5m");
		assert.strictEqual(ev?.type, "pointerup");
		assert.strictEqual(ev?.button, 0);
		assert.strictEqual(ev?.buttons, 0);
	});

	it("parses a middle-button press", () => {
		const ev = parsePointerEvent("\x1b[<1;3;7M");
		assert.strictEqual(ev?.button, 1);
		assert.strictEqual(ev?.buttons, 2);
	});

	it("parses a right-button press", () => {
		const ev = parsePointerEvent("\x1b[<2;3;7M");
		assert.strictEqual(ev?.button, 2);
		assert.strictEqual(ev?.buttons, 4);
	});

	it("parses a motion event with no buttons (button=35)", () => {
		const ev = parsePointerEvent("\x1b[<35;20;10M");
		assert.strictEqual(ev?.type, "pointermove");
		assert.strictEqual(ev?.button, 3);
		assert.strictEqual(ev?.buttons, 0);
	});

	it("parses a drag event with left button held (button=32)", () => {
		const ev = parsePointerEvent("\x1b[<32;20;10M");
		assert.strictEqual(ev?.type, "pointermove");
		assert.strictEqual(ev?.buttons, 1);
	});

	it("parses a wheel-up event (button=64)", () => {
		const ev = parsePointerEvent("\x1b[<64;5;3M");
		assert.strictEqual(ev?.type, "wheel");
		assert.strictEqual(ev?.deltaY, -1);
	});

	it("parses a wheel-down event (button=65)", () => {
		const ev = parsePointerEvent("\x1b[<65;5;3M");
		assert.strictEqual(ev?.type, "wheel");
		assert.strictEqual(ev?.deltaY, 1);
	});

	it("decodes shift modifier (button|=4)", () => {
		const ev = parsePointerEvent("\x1b[<4;10;5M");
		assert.strictEqual(ev?.shiftKey, true);
		assert.strictEqual(ev?.altKey, false);
		assert.strictEqual(ev?.ctrlKey, false);
		assert.strictEqual(ev?.button, 0);
	});

	it("decodes alt modifier (button|=8)", () => {
		const ev = parsePointerEvent("\x1b[<8;10;5M");
		assert.strictEqual(ev?.altKey, true);
		assert.strictEqual(ev?.button, 0);
	});

	it("decodes ctrl modifier (button|=16)", () => {
		const ev = parsePointerEvent("\x1b[<16;10;5M");
		assert.strictEqual(ev?.ctrlKey, true);
		assert.strictEqual(ev?.button, 0);
	});

	it("returns undefined for non-pointer sequences", () => {
		assert.strictEqual(parsePointerEvent("hello"), undefined);
		assert.strictEqual(parsePointerEvent("\x1b[A"), undefined);
		assert.strictEqual(parsePointerEvent("\x1b[<bad"), undefined);
	});

	it("returns undefined for malformed SGR mouse sequences", () => {
		assert.strictEqual(parsePointerEvent("\x1b[<0;10M"), undefined);
		assert.strictEqual(parsePointerEvent("\x1b[<0;10;5"), undefined);
	});
});
```

- [ ] **Step 2: Run tests and verify they fail**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/pointer-events.test.ts
```

Expected: all tests fail with "Cannot find module '../src/pointer-events.js'" (or equivalent).

- [ ] **Step 3: Implement the parser**

Create `/Users/robert/dev/pi-mono/packages/tui/src/pointer-events.ts`:

```ts
/**
 * Structured pointer event delivered to plugin handlers.
 *
 * Coordinates are in 0-based terminal cells (row, col).
 * Wheel events use deltaY: -1 for up, 1 for down.
 */
export interface PointerEvent {
	type: "pointerdown" | "pointermove" | "pointerup" | "wheel";
	row: number;
	col: number;
	button: number;       // 0=left, 1=middle, 2=right, 3=none/move
	buttons: number;      // bitmask: bit0=left, bit1=middle, bit2=right
	deltaX: number;
	deltaY: number;
	shiftKey: boolean;
	altKey: boolean;
	ctrlKey: boolean;
	metaKey: boolean;
}

const SGR_RE = /^\x1b\[<(\d+);(\d+);(\d+)([Mm])$/;

/**
 * Parse one SGR mouse sequence into a structured PointerEvent.
 * Returns undefined for any input that is not a complete SGR mouse sequence.
 *
 * SGR encoding (xterm):
 *   ESC [ < B ; X ; Y M    (press / motion)
 *   ESC [ < B ; X ; Y m    (release of B's button)
 *   X, Y are 1-based cell coords; we convert to 0-based.
 *   B encodes button + modifiers + wheel + motion as a bitmask.
 */
export function parsePointerEvent(data: string): PointerEvent | undefined {
	const match = SGR_RE.exec(data);
	if (!match) return undefined;

	const b = parseInt(match[1]!, 10);
	const x = parseInt(match[2]!, 10);
	const y = parseInt(match[3]!, 10);
	const finalChar = match[4]!;

	const isMotion = (b & 32) !== 0;
	const isWheel = (b & 64) !== 0;
	const buttonBits = b & 3;
	const shiftKey = (b & 4) !== 0;
	const altKey = (b & 8) !== 0;
	const ctrlKey = (b & 16) !== 0;

	let type: PointerEvent["type"];
	let button: number;
	let buttons: number;
	let deltaX = 0;
	let deltaY = 0;

	if (isWheel) {
		type = "wheel";
		button = 3;
		buttons = 0;
		// Wheel buttons: 64=up, 65=down, 66=left, 67=right
		const wheelDir = b & 3;
		if (wheelDir === 0) deltaY = -1;
		else if (wheelDir === 1) deltaY = 1;
		else if (wheelDir === 2) deltaX = -1;
		else if (wheelDir === 3) deltaX = 1;
	} else if (isMotion) {
		type = "pointermove";
		// Motion-with-button-held: buttonBits indicates which button is held.
		// Motion-with-no-button (button code 35 = 32+3): buttonBits=3, no buttons held.
		if (buttonBits === 3) {
			button = 3;
			buttons = 0;
		} else {
			button = buttonBits;
			buttons = 1 << buttonBits;
		}
	} else if (finalChar === "m") {
		type = "pointerup";
		button = buttonBits;
		buttons = 0;
	} else {
		type = "pointerdown";
		button = buttonBits;
		buttons = 1 << buttonBits;
	}

	return {
		type,
		row: y - 1,
		col: x - 1,
		button,
		buttons,
		deltaX,
		deltaY,
		shiftKey,
		altKey,
		ctrlKey,
		metaKey: false,
	};
}
```

- [ ] **Step 4: Run tests and verify they pass**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/pointer-events.test.ts
```

Expected: all tests pass.

- [ ] **Step 5: Export from package index**

Modify `/Users/robert/dev/pi-mono/packages/tui/src/index.ts` — add to the existing exports:

```ts
export { parsePointerEvent, type PointerEvent } from "./pointer-events.js";
```

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && npm run build
```

Expected: clean build.

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/pointer-events.ts packages/tui/test/pointer-events.test.ts packages/tui/src/index.ts
git commit -m "feat(tui): add SGR pointer-event parser"
```

---

## Chunk 2: Mouse Mode Lifecycle on TUI (pi-mono)

### Task 2: Refcounted mouse-mode enable/disable

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/mouse-mode.test.ts`

- [ ] **Step 1: Write failing test**

Create `/Users/robert/dev/pi-mono/packages/tui/test/mouse-mode.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import { TUI } from "../src/tui.js";
import { VirtualTerminal } from "./virtual-terminal.js";

describe("TUI mouse mode lifecycle", () => {
	it("enables mouse mode on first acquire and writes ?1002h + ?1006h", () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const written: string[] = [];
		const origWrite = terminal.write.bind(terminal);
		terminal.write = (data: string) => {
			written.push(data);
			origWrite(data);
		};

		const release = tui.acquireMouseMode();

		assert.ok(written.some((d) => d.includes("\x1b[?1002h")));
		assert.ok(written.some((d) => d.includes("\x1b[?1006h")));

		release();
	});

	it("does not write enable bytes again on a second concurrent acquire", () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const release1 = tui.acquireMouseMode();

		const written: string[] = [];
		const origWrite = terminal.write.bind(terminal);
		terminal.write = (data: string) => {
			written.push(data);
			origWrite(data);
		};

		const release2 = tui.acquireMouseMode();

		assert.ok(!written.some((d) => d.includes("\x1b[?1002h")));

		release1();
		release2();
	});

	it("only disables mouse mode after the last release", () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const release1 = tui.acquireMouseMode();
		const release2 = tui.acquireMouseMode();

		const written: string[] = [];
		const origWrite = terminal.write.bind(terminal);
		terminal.write = (data: string) => {
			written.push(data);
			origWrite(data);
		};

		release1();
		assert.ok(!written.some((d) => d.includes("\x1b[?1002l")));

		release2();
		assert.ok(written.some((d) => d.includes("\x1b[?1002l")));
		assert.ok(written.some((d) => d.includes("\x1b[?1006l")));
	});

	it("releasing the same handle twice is a no-op", () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const release = tui.acquireMouseMode();
		release();

		const written: string[] = [];
		const origWrite = terminal.write.bind(terminal);
		terminal.write = (data: string) => {
			written.push(data);
			origWrite(data);
		};

		release();
		assert.ok(!written.some((d) => d.includes("\x1b[?1002l")));
	});
});
```

- [ ] **Step 2: Run test and verify it fails**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/mouse-mode.test.ts
```

Expected: fails with "tui.acquireMouseMode is not a function".

- [ ] **Step 3: Implement on TUI**

Modify `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`. Add private fields near other state (around line 290):

```ts
	private mouseModeRefcount = 0;
```

Add public method (place it alongside other public methods, e.g. near `writeRaw`):

```ts
	/**
	 * Acquire mouse-mode reporting. Refcounted across callers.
	 * Returns a release function; mouse mode disables when the refcount reaches zero.
	 * Calling the release function twice is a no-op.
	 */
	acquireMouseMode(): () => void {
		if (this.mouseModeRefcount === 0) {
			this.terminal.write("\x1b[?1002h\x1b[?1006h");
		}
		this.mouseModeRefcount++;
		let released = false;
		return () => {
			if (released) return;
			released = true;
			this.mouseModeRefcount--;
			if (this.mouseModeRefcount === 0) {
				this.terminal.write("\x1b[?1002l\x1b[?1006l");
			}
		};
	}
```

Also disable on `stop()` (find the existing `stop()` method and add disable bytes if refcount > 0):

```ts
	stop(): void {
		// ... existing stop logic ...
		if (this.mouseModeRefcount > 0) {
			this.terminal.write("\x1b[?1002l\x1b[?1006l");
			this.mouseModeRefcount = 0;
		}
		// ... rest of existing logic ...
	}
```

(Locate the existing `stop()` method and add the disable lines at the appropriate point — before terminal restore.)

- [ ] **Step 4: Run tests and verify they pass**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/mouse-mode.test.ts
```

Expected: all four tests pass.

- [ ] **Step 5: Run all TUI tests to confirm no regression**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && npm test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/mouse-mode.test.ts
git commit -m "feat(tui): add refcounted mouse-mode acquire/release"
```

---

## Chunk 3: OverlayHandle.onPointer (pi-mono)

### Task 3: Per-overlay pointer subscription with hit-test

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/overlay-pointer.test.ts`

- [ ] **Step 1: Write failing test**

Create `/Users/robert/dev/pi-mono/packages/tui/test/overlay-pointer.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component } from "../src/tui.js";
import { TUI } from "../src/tui.js";
import type { PointerEvent } from "../src/pointer-events.js";
import { VirtualTerminal } from "./virtual-terminal.js";

class StaticOverlay implements Component {
	constructor(private lines: string[]) {}
	render(): string[] { return this.lines; }
	invalidate(): void {}
}

class EmptyContent implements Component {
	render(): string[] { return []; }
	invalidate(): void {}
}

async function flush(tui: TUI, terminal: VirtualTerminal): Promise<void> {
	tui.requestRender(true);
	await new Promise<void>((resolve) => process.nextTick(resolve));
	await terminal.waitForRender();
}

describe("OverlayHandle.onPointer", () => {
	it("delivers structured events when the pointer lands inside the overlay rect", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new StaticOverlay(["AAAAA", "BBBBB", "CCCCC"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 5, height: 3, anchor: "top-left" });
			await flush(tui, terminal);
			const events: PointerEvent[] = [];
			handle.onPointer((ev) => events.push(ev));

			// SGR press at row=1, col=2 (inside the 5x3 rect at top-left)
			tui.feedInput("\x1b[<0;3;2M");

			assert.strictEqual(events.length, 1);
			assert.strictEqual(events[0]!.type, "pointerdown");
			assert.strictEqual(events[0]!.row, 1);
			assert.strictEqual(events[0]!.col, 2);
		} finally {
			tui.stop();
		}
	});

	it("does not deliver events that land outside the overlay rect", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new StaticOverlay(["AAAAA"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 5, height: 1, anchor: "top-left" });
			await flush(tui, terminal);
			const events: PointerEvent[] = [];
			handle.onPointer((ev) => events.push(ev));

			// Press at row=10, col=10 — outside the 5x1 overlay
			tui.feedInput("\x1b[<0;11;11M");

			assert.strictEqual(events.length, 0);
		} finally {
			tui.stop();
		}
	});

	it("auto-releases the listener when the overlay is hidden", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new StaticOverlay(["AAAAA"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 5, height: 1, anchor: "top-left" });
			await flush(tui, terminal);
			const events: PointerEvent[] = [];
			handle.onPointer((ev) => events.push(ev));

			handle.hide();
			await flush(tui, terminal);

			tui.feedInput("\x1b[<0;3;1M");
			assert.strictEqual(events.length, 0);
		} finally {
			tui.stop();
		}
	});

	it("acquires mouse mode on first onPointer and releases on last unsubscribe", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new StaticOverlay(["AAAAA"]);
		tui.start();
		try {
			const written: string[] = [];
			const origWrite = terminal.write.bind(terminal);
			terminal.write = (data: string) => { written.push(data); origWrite(data); };

			const handle = tui.showOverlay(overlay, { width: 5, height: 1, anchor: "top-left" });
			await flush(tui, terminal);

			assert.ok(!written.some((d) => d.includes("\x1b[?1002h")));

			const off = handle.onPointer(() => {});
			assert.ok(written.some((d) => d.includes("\x1b[?1002h")));

			off();
			assert.ok(written.some((d) => d.includes("\x1b[?1002l")));
		} finally {
			tui.stop();
		}
	});
});
```

(Note: `tui.feedInput` is a test helper. If it doesn't exist on TUI, see step 3.)

- [ ] **Step 2: Run test and verify it fails**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/overlay-pointer.test.ts
```

Expected: fails with "handle.onPointer is not a function" (or "tui.feedInput is not a function").

- [ ] **Step 3: Add `feedInput` test helper if absent**

Find how existing tests inject input. If there is no public input-injection method, add a minimal one to TUI:

```ts
	/** Test helper: feed a complete input sequence into the input pipeline as if it came from stdin. */
	feedInput(data: string): void {
		this.handleInput(data);
	}
```

(If a public equivalent already exists, use that in the test instead.)

- [ ] **Step 4: Extend the OverlayHandle interface**

Modify `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts` around line 195:

```ts
export interface OverlayHandle {
	hide(): void;
	setHidden(hidden: boolean): void;
	isHidden(): boolean;
	focus(): void;
	unfocus(): void;
	isFocused(): boolean;
	getRect(): OverlayRect | undefined;
	onRectChange(listener: (rect: OverlayRect | undefined) => void): () => void;
	onPointer(listener: (event: PointerEvent) => void): () => void;
}
```

Import `PointerEvent` at the top of the file:

```ts
import { parsePointerEvent, type PointerEvent } from "./pointer-events.js";
```

- [ ] **Step 5: Track pointer listeners on each `OverlayEntry`**

Extend the `OverlayEntry` type (around line 214):

```ts
type OverlayEntry = {
	component: Component;
	options?: OverlayOptions;
	preFocus: Component | null;
	hidden: boolean;
	focusOrder: number;
	lastRect: OverlayRect | undefined;
	rectListeners: Set<(rect: OverlayRect | undefined) => void>;
	pointerListeners: Set<(event: PointerEvent) => void>;
	mouseModeRelease: (() => void) | undefined;
};
```

In `showOverlay`, initialize the new fields (`pointerListeners: new Set(), mouseModeRelease: undefined`).

- [ ] **Step 6: Implement `onPointer` on the handle**

In the `showOverlay` method, where the handle is constructed (around line 363+), add:

```ts
			onPointer: (listener: (event: PointerEvent) => void) => {
				entry.pointerListeners.add(listener);
				if (entry.pointerListeners.size === 1) {
					entry.mouseModeRelease = this.acquireMouseMode();
				}
				return () => {
					if (!entry.pointerListeners.has(listener)) return;
					entry.pointerListeners.delete(listener);
					if (entry.pointerListeners.size === 0 && entry.mouseModeRelease) {
						entry.mouseModeRelease();
						entry.mouseModeRelease = undefined;
					}
				};
			},
```

In the overlay `hide()` path (and wherever overlays get cleaned up), release the mouse mode handle:

```ts
				if (entry.mouseModeRelease) {
					entry.mouseModeRelease();
					entry.mouseModeRelease = undefined;
				}
				entry.pointerListeners.clear();
```

- [ ] **Step 7: Dispatch parsed pointer events to overlays in `handleInput`**

In `handleInput` (around line 602), before the existing focused-component dispatch, parse and dispatch pointer events:

```ts
	private handleInput(data: string): void {
		// ... existing inputListeners logic ...
		// ... existing consumeCellSizeResponse / debug-key logic ...

		const pointerEvent = parsePointerEvent(data);
		if (pointerEvent) {
			this.dispatchPointerEvent(pointerEvent);
			return;
		}

		// ... existing focused-component dispatch ...
	}

	private dispatchPointerEvent(event: PointerEvent): void {
		// Top-down by focusOrder
		const overlaysByFocus = [...this.overlayStack].sort((a, b) => b.focusOrder - a.focusOrder);
		for (const entry of overlaysByFocus) {
			if (entry.hidden) continue;
			if (!entry.lastRect) continue;
			if (!rectContains(entry.lastRect, event.row, event.col)) continue;
			if (entry.pointerListeners.size === 0) continue;
			for (const listener of entry.pointerListeners) {
				listener(event);
			}
			return;
		}
	}
```

Add the helper near the top of the file:

```ts
function rectContains(rect: OverlayRect, row: number, col: number): boolean {
	return row >= rect.row && row < rect.row + rect.rows && col >= rect.col && col < rect.col + rect.cols;
}
```

- [ ] **Step 8: Run tests and verify they pass**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/overlay-pointer.test.ts
```

Expected: all four tests pass.

- [ ] **Step 9: Run all TUI tests**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && npm test
```

Expected: all tests pass.

- [ ] **Step 10: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/overlay-pointer.test.ts
git commit -m "feat(tui): add OverlayHandle.onPointer with hit-test routing"
```

---

## Chunk 4: Click-to-Focus on Overlay Components (pi-mono)

### Task 4: Pointerdown inside an overlay focuses its component, click forwarded

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/overlay-click-focus.test.ts`

- [ ] **Step 1: Write failing test**

Create `/Users/robert/dev/pi-mono/packages/tui/test/overlay-click-focus.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component, Focusable } from "../src/tui.js";
import { TUI } from "../src/tui.js";
import type { PointerEvent } from "../src/pointer-events.js";
import { VirtualTerminal } from "./virtual-terminal.js";

class FocusableOverlay implements Component, Focusable {
	focused = false;
	constructor(private lines: string[]) {}
	render(): string[] { return this.lines; }
	invalidate(): void {}
}

class EmptyContent implements Component {
	render(): string[] { return []; }
	invalidate(): void {}
}

async function flush(tui: TUI, terminal: VirtualTerminal): Promise<void> {
	tui.requestRender(true);
	await new Promise<void>((resolve) => process.nextTick(resolve));
	await terminal.waitForRender();
}

describe("Click-to-focus on overlay", () => {
	it("pointerdown inside an overlay's rect sets focus to that overlay", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const editor = new FocusableOverlay(["EDITOR"]);
		tui.addChild(new EmptyContent());
		tui.setFocus(editor);
		const overlay = new FocusableOverlay(["OVERLAY"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 7, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			handle.onPointer(() => {});

			tui.feedInput("\x1b[<0;3;1M");
			await flush(tui, terminal);

			assert.strictEqual(editor.focused, false);
			assert.strictEqual(overlay.focused, true);
		} finally {
			tui.stop();
		}
	});

	it("the focusing pointerdown is also delivered to the overlay's onPointer listener", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const editor = new FocusableOverlay(["EDITOR"]);
		tui.addChild(new EmptyContent());
		tui.setFocus(editor);
		const overlay = new FocusableOverlay(["OVERLAY"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 7, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			const events: PointerEvent[] = [];
			handle.onPointer((ev) => events.push(ev));

			tui.feedInput("\x1b[<0;3;1M");

			assert.strictEqual(events.length, 1);
			assert.strictEqual(events[0]!.type, "pointerdown");
		} finally {
			tui.stop();
		}
	});

	it("pointerdown on a non-focusable component does not change focus", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const editor = new FocusableOverlay(["EDITOR"]);
		tui.addChild(new EmptyContent());
		tui.setFocus(editor);
		const overlay = new FocusableOverlay(["OVERLAY"]);
		tui.start();
		try {
			// Don't subscribe to pointer events; the overlay isn't a click-focus target unless it has a listener.
			const handle = tui.showOverlay(overlay, { width: 7, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);

			tui.feedInput("\x1b[<0;3;1M");
			await flush(tui, terminal);

			assert.strictEqual(editor.focused, true);
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 2: Run test and verify it fails**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/overlay-click-focus.test.ts
```

Expected: first two tests fail (focus does not change).

- [ ] **Step 3: Add click-to-focus to dispatch**

In `dispatchPointerEvent` (added in Chunk 3), set focus on `pointerdown` *before* delivering the event:

```ts
	private dispatchPointerEvent(event: PointerEvent): void {
		const overlaysByFocus = [...this.overlayStack].sort((a, b) => b.focusOrder - a.focusOrder);
		for (const entry of overlaysByFocus) {
			if (entry.hidden) continue;
			if (!entry.lastRect) continue;
			if (!rectContains(entry.lastRect, event.row, event.col)) continue;
			if (entry.pointerListeners.size === 0) continue;

			if (event.type === "pointerdown" && this.focusedComponent !== entry.component) {
				this.setPluginFocus(entry.component);
			}

			for (const listener of entry.pointerListeners) {
				listener(event);
			}
			return;
		}
	}
```

`setPluginFocus` is a wrapper around `setFocus` that records the focus as plugin-claimed. Add it now (we'll use the flag in Chunk 5):

```ts
	private pluginFocused = false;

	private setPluginFocus(component: Component): void {
		this.setFocus(component);
		this.pluginFocused = true;
	}
```

Also clear `pluginFocused` whenever focus changes elsewhere — modify `setFocus` to clear the flag:

```ts
	setFocus(component: Component | null): void {
		if (component !== this.focusedComponent) {
			this.pluginFocused = false;
		}
		// ... existing setFocus body ...
	}
```

(Be careful: `setPluginFocus` calls `setFocus`, which clears `pluginFocused`. Set `pluginFocused = true` *after* the `setFocus` call.)

- [ ] **Step 4: Run tests and verify they pass**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/overlay-click-focus.test.ts
```

Expected: all three tests pass.

- [ ] **Step 5: Run full TUI suite**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && npm test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/overlay-click-focus.test.ts
git commit -m "feat(tui): pointerdown inside subscribed overlay focuses its component"
```

---

## Chunk 5: Pi-Enforced Esc Release (pi-mono)

### Task 5: Esc with plugin focus returns to preFocus, plugin does not see Esc

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/plugin-focus-esc.test.ts`

- [ ] **Step 1: Write failing test**

Create `/Users/robert/dev/pi-mono/packages/tui/test/plugin-focus-esc.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component, Focusable } from "../src/tui.js";
import { TUI } from "../src/tui.js";
import { VirtualTerminal } from "./virtual-terminal.js";

class FocusableOverlay implements Component, Focusable {
	focused = false;
	inputs: string[] = [];
	constructor(private lines: string[]) {}
	handleInput(data: string): void { this.inputs.push(data); }
	render(): string[] { return this.lines; }
	invalidate(): void {}
}

class EmptyContent implements Component {
	render(): string[] { return []; }
	invalidate(): void {}
}

async function flush(tui: TUI, terminal: VirtualTerminal): Promise<void> {
	tui.requestRender(true);
	await new Promise<void>((resolve) => process.nextTick(resolve));
	await terminal.waitForRender();
}

describe("Pi-enforced Esc release for plugin focus", () => {
	it("Esc with plugin focus returns to preFocus and is not delivered to plugin", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const editor = new FocusableOverlay(["EDITOR"]);
		tui.addChild(new EmptyContent());
		tui.setFocus(editor);
		const overlay = new FocusableOverlay(["OVERLAY"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 7, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			handle.onPointer(() => {});

			tui.feedInput("\x1b[<0;3;1M");
			await flush(tui, terminal);
			assert.strictEqual(overlay.focused, true);

			overlay.inputs.length = 0;
			tui.feedInput("\x1b");
			await flush(tui, terminal);

			assert.strictEqual(editor.focused, true);
			assert.strictEqual(overlay.focused, false);
			assert.strictEqual(overlay.inputs.length, 0, "plugin must not see Esc that returned focus");
		} finally {
			tui.stop();
		}
	});

	it("Esc with non-plugin focus is delivered to focused component as before", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const editor = new FocusableOverlay(["EDITOR"]);
		tui.addChild(new EmptyContent());
		tui.setFocus(editor);
		tui.start();
		try {
			tui.feedInput("\x1b");
			await flush(tui, terminal);

			assert.deepStrictEqual(editor.inputs, ["\x1b"]);
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 2: Run test and verify it fails**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/plugin-focus-esc.test.ts
```

Expected: first test fails (Esc reaches the plugin or focus does not return).

- [ ] **Step 3: Track preFocus on plugin focus and intercept Esc**

In `setPluginFocus` (added in Chunk 4), record the previously-focused component:

```ts
	private pluginPreFocus: Component | null = null;

	private setPluginFocus(component: Component): void {
		const previous = this.focusedComponent;
		this.setFocus(component);
		this.pluginFocused = true;
		this.pluginPreFocus = previous;
	}
```

In `handleInput`, intercept Esc when plugin focus is active. Place this after the existing inputListeners loop and *before* the focused-component dispatch:

```ts
		if (this.pluginFocused && data === "\x1b") {
			const target = this.pluginPreFocus;
			this.setFocus(target);
			this.pluginPreFocus = null;
			this.pluginFocused = false;
			return;
		}
```

- [ ] **Step 4: Run tests and verify they pass**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/plugin-focus-esc.test.ts
```

Expected: both tests pass.

- [ ] **Step 5: Run full TUI suite**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && npm test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/plugin-focus-esc.test.ts
git commit -m "feat(tui): Esc returns plugin-focused component to its preFocus"
```

---

## Chunk 6: Click-Outside Release and Auto-Release on Hide (pi-mono)

### Task 6: Click outside any focusable plugin component returns focus

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/plugin-focus-click-outside.test.ts`

- [ ] **Step 1: Write failing tests**

Create `/Users/robert/dev/pi-mono/packages/tui/test/plugin-focus-click-outside.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component, Focusable } from "../src/tui.js";
import { TUI } from "../src/tui.js";
import { VirtualTerminal } from "./virtual-terminal.js";

class FocusableOverlay implements Component, Focusable {
	focused = false;
	constructor(private lines: string[]) {}
	render(): string[] { return this.lines; }
	invalidate(): void {}
}

class EmptyContent implements Component {
	render(): string[] { return []; }
	invalidate(): void {}
}

async function flush(tui: TUI, terminal: VirtualTerminal): Promise<void> {
	tui.requestRender(true);
	await new Promise<void>((resolve) => process.nextTick(resolve));
	await terminal.waitForRender();
}

describe("Plugin focus auto-release", () => {
	it("clicking outside any subscribed overlay returns focus to preFocus", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const editor = new FocusableOverlay(["EDITOR"]);
		tui.addChild(new EmptyContent());
		tui.setFocus(editor);
		const overlay = new FocusableOverlay(["OVERLAY"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 7, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			handle.onPointer(() => {});

			tui.feedInput("\x1b[<0;3;1M");
			await flush(tui, terminal);
			assert.strictEqual(overlay.focused, true);

			tui.feedInput("\x1b[<0;40;20M");
			await flush(tui, terminal);

			assert.strictEqual(editor.focused, true);
			assert.strictEqual(overlay.focused, false);
		} finally {
			tui.stop();
		}
	});

	it("hiding a plugin-focused overlay returns focus to preFocus", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const editor = new FocusableOverlay(["EDITOR"]);
		tui.addChild(new EmptyContent());
		tui.setFocus(editor);
		const overlay = new FocusableOverlay(["OVERLAY"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 7, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			handle.onPointer(() => {});
			tui.feedInput("\x1b[<0;3;1M");
			await flush(tui, terminal);
			assert.strictEqual(overlay.focused, true);

			handle.hide();
			await flush(tui, terminal);

			assert.strictEqual(editor.focused, true);
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 2: Run tests and verify they fail**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/plugin-focus-click-outside.test.ts
```

Expected: both tests fail.

- [ ] **Step 3: Implement click-outside release**

In `dispatchPointerEvent`, when no overlay matched and the event is a `pointerdown` with plugin focus active, release:

```ts
	private dispatchPointerEvent(event: PointerEvent): void {
		const overlaysByFocus = [...this.overlayStack].sort((a, b) => b.focusOrder - a.focusOrder);
		for (const entry of overlaysByFocus) {
			if (entry.hidden) continue;
			if (!entry.lastRect) continue;
			if (!rectContains(entry.lastRect, event.row, event.col)) continue;
			if (entry.pointerListeners.size === 0) continue;

			if (event.type === "pointerdown" && this.focusedComponent !== entry.component) {
				this.setPluginFocus(entry.component);
			}
			for (const listener of entry.pointerListeners) listener(event);
			return;
		}

		// No overlay claimed the event.
		if (event.type === "pointerdown" && this.pluginFocused) {
			const target = this.pluginPreFocus;
			this.setFocus(target);
			this.pluginPreFocus = null;
			this.pluginFocused = false;
		}
	}
```

- [ ] **Step 4: Implement auto-release on hide**

In the `hide()` path of the overlay handle, after clearing pointer listeners (Chunk 3), also release plugin focus if this overlay holds it:

```ts
				if (this.focusedComponent === entry.component && this.pluginFocused) {
					this.setFocus(this.pluginPreFocus);
					this.pluginPreFocus = null;
					this.pluginFocused = false;
				}
```

- [ ] **Step 5: Run tests and verify they pass**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/plugin-focus-click-outside.test.ts
```

Expected: both tests pass.

- [ ] **Step 6: Run full TUI suite**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && npm test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/plugin-focus-click-outside.test.ts
git commit -m "feat(tui): release plugin focus on click-outside or overlay hide"
```

---

## Chunk 7: Wheel Routing (pi-mono)

### Task 7: Wheel events default to the existing input pipeline; opt-in delivers them to the plugin

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/overlay-wheel.test.ts`

- [ ] **Step 1: Write failing test**

Create `/Users/robert/dev/pi-mono/packages/tui/test/overlay-wheel.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component, Focusable } from "../src/tui.js";
import { TUI } from "../src/tui.js";
import type { PointerEvent } from "../src/pointer-events.js";
import { VirtualTerminal } from "./virtual-terminal.js";

class FocusableOverlay implements Component, Focusable {
	focused = false;
	inputs: string[] = [];
	constructor(private lines: string[]) {}
	handleInput(data: string): void { this.inputs.push(data); }
	render(): string[] { return this.lines; }
	invalidate(): void {}
}

class EmptyContent implements Component {
	render(): string[] { return []; }
	invalidate(): void {}
}

async function flush(tui: TUI, terminal: VirtualTerminal): Promise<void> {
	tui.requestRender(true);
	await new Promise<void>((resolve) => process.nextTick(resolve));
	await terminal.waitForRender();
}

describe("Wheel routing", () => {
	it("wheel events do not reach a default-subscription pointer listener", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new FocusableOverlay(["X"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 1, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			const events: PointerEvent[] = [];
			handle.onPointer((ev) => events.push(ev));

			tui.feedInput("\x1b[<64;1;1M"); // wheel up

			assert.strictEqual(events.length, 0);
		} finally {
			tui.stop();
		}
	});

	it("wheel events reach a wheel-opt-in subscription", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new FocusableOverlay(["X"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 1, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			const events: PointerEvent[] = [];
			handle.onPointer((ev) => events.push(ev), { wheel: true });

			tui.feedInput("\x1b[<64;1;1M");

			assert.strictEqual(events.length, 1);
			assert.strictEqual(events[0]!.type, "wheel");
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 2: Run test and verify it fails**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/overlay-wheel.test.ts
```

Expected: second test fails (no second arg to onPointer); first test may pass or fail.

- [ ] **Step 3: Extend `onPointer` signature with options**

Update the `OverlayHandle` interface:

```ts
	onPointer(
		listener: (event: PointerEvent) => void,
		options?: { wheel?: boolean },
	): () => void;
```

In the implementation, store the wheel flag on the listener entry. Change `pointerListeners` from a `Set<fn>` to a `Set<{listener, wheel}>`:

```ts
type PointerListenerEntry = {
	listener: (event: PointerEvent) => void;
	wheel: boolean;
};
```

Update `OverlayEntry.pointerListeners` to `Set<PointerListenerEntry>` and adjust call sites accordingly. In `dispatchPointerEvent`, filter wheel events:

```ts
			for (const ple of entry.pointerListeners) {
				if (event.type === "wheel" && !ple.wheel) continue;
				ple.listener(event);
			}
```

If, after filtering, no listener consumed a wheel event, fall through to the rest of `handleInput` so the event continues as a raw pointer event the existing pipeline ignores. (No change needed there — wheel events the new path drops simply don't get re-emitted as raw input. That is acceptable for v1: terminal scrollback is not yet driven by wheel inside the TUI.)

- [ ] **Step 4: Run tests and verify they pass**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/overlay-wheel.test.ts
```

Expected: both tests pass.

- [ ] **Step 5: Run full TUI suite**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/tui && npm test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/overlay-wheel.test.ts
git commit -m "feat(tui): wheel events require explicit opt-in on onPointer"
```

---

## Chunk 8: Rewrite `terminal-surface-demo` to use new APIs (pi-mono)

### Task 8: Replace manual SGR + manual mouse-mode in the demo with `OverlayHandle.onPointer` + click-to-focus

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/coding-agent/examples/extensions/terminal-surface-demo.ts`

**Context for the implementer:** The current file contains the contortion v1 supersedes — the extension parses SGR mouse itself (`parseSgrMouse`), writes mouse-mode bytes itself (`ENABLE_SGR_MOUSE` / `DISABLE_SGR_MOUSE`), routes mouse via `ctx.ui.onTerminalInput` + a custom `handleTerminalInput` method. After v1 Chunks 1–7, all of that is provided by TUI. The rewrite replaces those mechanisms with `handle.onPointer(...)` and the new click-to-focus + arrow-key navigation, while keeping the existing image rendering pipeline (`onRectChange`, `afterNextRender`, `writeRaw`, `scheduleDraw`, `uploaded` flag) unchanged.

- [ ] **Step 1: Rewrite the file**

Replace `/Users/robert/dev/pi-mono/packages/coding-agent/examples/extensions/terminal-surface-demo.ts` with:

```ts
/**
 * Terminal Surface Demo
 *
 * A bordered Pi overlay that draws a Kitty image inside an inner viewport
 * and exercises Pi's structured pointer-event API: click-to-focus,
 * click-to-mark with cell→pixel mapping, and arrow-key navigation while
 * focused. Esc is host-enforced and returns focus to the composer; the
 * demo never sees Esc.
 *
 * Usage:
 *   pi --extension packages/coding-agent/examples/extensions/terminal-surface-demo.ts
 *   /terminal-surface-demo
 */

import type { ExtensionAPI, ExtensionCommandContext, Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, type OverlayHandle, type PointerEvent, visibleWidth } from "@earendil-works/pi-tui";

const ESC = "\x1b";
const ST = "\x1b\\";
const IMAGE_ID_BASE = 424200;
const PLACEMENT_ID_BASE = 424201;
const IMAGE_WIDTH = 192;
const IMAGE_HEIGHT = 128;

const PANEL_WIDTH = 56;
const PANEL_MARGIN = 1;
const PANEL_MAX_HEIGHT = "90%" as const;

const IMAGE_VIEWPORT = {
	cols: 36,
	rows: 12,
	rowOffset: 3,
	colOffset: 4,
	insetRow: 1,
	insetCol: 1,
} as const;

let activeClose: (() => void) | undefined;

export default function (pi: ExtensionAPI) {
	pi.registerCommand("terminal-surface-demo", {
		description: "Show a bordered overlay panel with a Kitty image; exercises pointer events and click-to-focus",
		handler: async (_args: string, ctx: ExtensionCommandContext) => {
			if (activeClose) {
				activeClose();
				return;
			}

			let component: TerminalSurfaceDemoComponent | undefined;
			let rectUnsubscribe: (() => void) | undefined;
			let pointerUnsubscribe: (() => void) | undefined;
			const inputUnsubscribe = ctx.ui.onTerminalInput((data) => {
				if (matchesKey(data, "ctrl+g")) {
					activeClose?.();
					return { consume: true };
				}
				return undefined;
			});

			const surfacePromise = ctx.ui.custom<void>(
				(tui, theme, _keybindings, done) => {
					activeClose = done;
					component = new TerminalSurfaceDemoComponent(tui, theme);
					return component;
				},
				{
					overlay: true,
					overlayOptions: {
						anchor: "right-center",
						width: PANEL_WIDTH,
						maxHeight: PANEL_MAX_HEIGHT,
						margin: PANEL_MARGIN,
						nonCapturing: true,
					},
					onHandle: (handle: OverlayHandle) => {
						rectUnsubscribe = handle.onRectChange((rect) => component?.setOverlayRect(rect));
						pointerUnsubscribe = handle.onPointer((event) => component?.onPointer(event, handle));
					},
				},
			);

			void surfacePromise
				.catch((err: unknown) => {
					const message = err instanceof Error ? err.message : String(err);
					ctx.ui.notify(`Terminal surface demo failed: ${message}`, "error");
				})
				.finally(() => {
					activeClose = undefined;
					inputUnsubscribe();
					rectUnsubscribe?.();
					pointerUnsubscribe?.();
				});
		},
	});
}

class TerminalSurfaceDemoComponent {
	readonly width = PANEL_WIDTH;
	focused = false;
	private readonly imageId = IMAGE_ID_BASE + Math.floor(Math.random() * 1000);
	private readonly placementId = PLACEMENT_ID_BASE + Math.floor(Math.random() * 1000);
	private overlayRect: { row: number; col: number; rows: number; cols: number } | undefined;
	private drawScheduled = false;
	private uploaded = false;
	private markerRow = Math.floor(IMAGE_VIEWPORT.rows / 2);
	private markerCol = Math.floor(IMAGE_VIEWPORT.cols / 2);
	private lastPixel: { x: number; y: number } | undefined;

	constructor(
		private readonly tui: {
			writeRaw(data: string): void;
			afterNextRender(callback: () => void): void;
			requestRender(): void;
		},
		private readonly theme: Theme,
	) {}

	setOverlayRect(rect: { row: number; col: number; rows: number; cols: number } | undefined): void {
		this.overlayRect = rect;
		if (!rect) {
			this.tui.writeRaw(deletePlacement(this.imageId, this.placementId));
			return;
		}
		this.scheduleDraw();
	}

	render(_width: number): string[] {
		const w = this.width;
		const innerW = w - 2;
		const lines: string[] = [];
		const th = this.theme;

		const pad = (s: string, len: number) => s + " ".repeat(Math.max(0, len - visibleWidth(s)));
		const row = (content: string) => th.fg("border", "│") + pad(content, innerW) + th.fg("border", "│");

		lines.push(th.fg("border", `╭${"─".repeat(innerW)}╮`));
		lines.push(row(` ${th.fg("accent", "🖼️ Terminal Surface Demo")}`));
		lines.push(
			row(
				` ${th.fg("dim", `Click box to focus + mark; arrows move; Esc releases.${this.focused ? " [focused]" : ""}`)}`,
			),
		);

		for (let r = 0; r < IMAGE_VIEWPORT.rows + 2; r++) {
			const prefix = " ".repeat(IMAGE_VIEWPORT.colOffset);
			if (r === 0) {
				const box = th.fg("accent", `╭${"─".repeat(IMAGE_VIEWPORT.cols)}╮`);
				lines.push(row(prefix + box));
			} else if (r === IMAGE_VIEWPORT.rows + 1) {
				const box = th.fg("accent", `╰${"─".repeat(IMAGE_VIEWPORT.cols)}╯`);
				lines.push(row(prefix + box));
			} else {
				const body = th.fg("accent", "│") + " ".repeat(IMAGE_VIEWPORT.cols) + th.fg("accent", "│");
				lines.push(row(prefix + body));
			}
		}

		const status = this.lastPixel
			? ` cell(${this.markerCol},${this.markerRow}) → px(${this.lastPixel.x},${this.lastPixel.y})`
			: ` (click inside the box)`;
		lines.push(row(` ${th.fg("dim", status)}`));
		lines.push(row(` ${th.fg("dim", "Ctrl+G closes; command toggles.")}`));
		lines.push(th.fg("border", `╰${"─".repeat(innerW)}╯`));

		this.scheduleDraw();
		return lines;
	}

	invalidate(): void {}

	/** Arrow keys move the marker while focused. Esc is intercepted by Pi and never reaches us. */
	handleInput(data: string): void {
		const r = IMAGE_VIEWPORT.rows;
		const c = IMAGE_VIEWPORT.cols;
		if (data === "\x1b[A") this.markerRow = Math.max(0, this.markerRow - 1);
		else if (data === "\x1b[B") this.markerRow = Math.min(r - 1, this.markerRow + 1);
		else if (data === "\x1b[D") this.markerCol = Math.max(0, this.markerCol - 1);
		else if (data === "\x1b[C") this.markerCol = Math.min(c - 1, this.markerCol + 1);
		else return;
		this.recomputePixel();
		this.tui.requestRender();
	}

	onPointer(event: PointerEvent, _handle: OverlayHandle): void {
		if (event.type !== "pointerdown") return;
		const imageRect = this.imageScreenRect();
		if (!imageRect) return;
		if (event.row < imageRect.row || event.row >= imageRect.row + imageRect.rows) return;
		if (event.col < imageRect.col || event.col >= imageRect.col + imageRect.cols) return;
		this.markerRow = event.row - imageRect.row;
		this.markerCol = event.col - imageRect.col;
		this.recomputePixel();
		this.tui.requestRender();
	}

	dispose(): void {
		this.tui.writeRaw(deletePlacement(this.imageId, this.placementId));
	}

	private recomputePixel(): void {
		this.lastPixel = {
			x: Math.floor(((this.markerCol + 0.5) / IMAGE_VIEWPORT.cols) * IMAGE_WIDTH),
			y: Math.floor(((this.markerRow + 0.5) / IMAGE_VIEWPORT.rows) * IMAGE_HEIGHT),
		};
	}

	private scheduleDraw(): void {
		if (this.drawScheduled) return;
		this.drawScheduled = true;
		this.tui.afterNextRender(() => {
			this.drawScheduled = false;
			this.drawImage();
		});
	}

	private imageScreenRect(): { row: number; col: number; rows: number; cols: number } | undefined {
		const rect = this.overlayRect;
		if (!rect || rect.rows < IMAGE_VIEWPORT.rowOffset + IMAGE_VIEWPORT.rows + 2 || rect.cols < PANEL_WIDTH) {
			return undefined;
		}
		return {
			row: rect.row + IMAGE_VIEWPORT.rowOffset + IMAGE_VIEWPORT.insetRow,
			col: rect.col + IMAGE_VIEWPORT.colOffset + IMAGE_VIEWPORT.insetCol + 1,
			rows: IMAGE_VIEWPORT.rows,
			cols: IMAGE_VIEWPORT.cols,
		};
	}

	private drawImage(): void {
		const imageRect = this.imageScreenRect();
		if (!imageRect) {
			this.tui.writeRaw(deletePlacement(this.imageId, this.placementId));
			return;
		}

		const row = imageRect.row + 1;
		const col = imageRect.col + 1;
		let commands = "";
		if (!this.uploaded) {
			commands += transmitRgbaGradient(this.imageId);
			this.uploaded = true;
		}
		commands +=
			cursorTo(row, col) + placeImage(this.imageId, this.placementId, IMAGE_VIEWPORT.cols, IMAGE_VIEWPORT.rows);
		this.tui.writeRaw(commands);
	}
}

function apc(params: string, payload?: string): string {
	return `${ESC}_G${params}${payload ? `;${payload}` : ""}${ST}`;
}

function transmitRgbaGradient(imageId: number): string {
	const payload = buildGradientRgba(IMAGE_WIDTH, IMAGE_HEIGHT).toString("base64");
	return apc(`a=t,f=32,s=${IMAGE_WIDTH},v=${IMAGE_HEIGHT},i=${imageId},q=2`, payload);
}

function placeImage(imageId: number, placementId: number, cols: number, rows: number): string {
	return apc(`a=p,C=1,i=${imageId},p=${placementId},c=${cols},r=${rows},q=2`);
}

function deletePlacement(imageId: number, placementId: number): string {
	return apc(`a=d,d=I,i=${imageId},p=${placementId},q=2`);
}

function cursorTo(row: number, col: number): string {
	return `${ESC}[${row};${col}H`;
}

function buildGradientRgba(width: number, height: number): Buffer {
	const out = Buffer.alloc(width * height * 4);
	for (let y = 0; y < height; y++) {
		for (let x = 0; x < width; x++) {
			const i = (y * width + x) * 4;
			const fx = x / Math.max(1, width - 1);
			const fy = y / Math.max(1, height - 1);
			const wave = Math.sin(fx * Math.PI * 4) * 0.5 + 0.5;
			out[i + 0] = Math.round(255 * fx);
			out[i + 1] = Math.round(255 * fy);
			out[i + 2] = Math.round(255 * wave * (1 - fy * 0.35));
			out[i + 3] = 255;
		}
	}
	return out;
}
```

- [ ] **Step 2: Verify build (and biome) pass**

Run:
```bash
cd /Users/robert/dev/pi-mono/packages/coding-agent && npm run build
```

Expected: clean build, no TypeScript errors. If biome flags formatting, run `npx biome check --write packages/coding-agent/examples/extensions/terminal-surface-demo.ts` from the repo root and re-build.

- [ ] **Step 3: Manual smoke — open the demo**

Run Pi with the demo extension:
```bash
cd /Users/robert/dev/pi-mono
node --import tsx packages/coding-agent/src/cli.ts --extension packages/coding-agent/examples/extensions/terminal-surface-demo.ts
```

(Adjust the launch command if your local convention differs.)

In the Pi prompt:
```text
/terminal-surface-demo
```

Expected: a panel appears on the right with a Kitty gradient image inside the inner box.

- [ ] **Step 4: Manual smoke — click-to-focus + cell→pixel mapping**

With the panel open:

| Action | Expected |
|---|---|
| Click inside the inner image box | Status line updates to `cell(X,Y) → px(W,H)` with values matching the click position. Header shows `[focused]`. |
| Press arrow keys | Marker advances cell-by-cell within the image rect. Status updates each press. |
| Press Esc | `[focused]` indicator disappears. Subsequent arrow keys do not move the marker. |
| Click inside the box again | `[focused]` returns; arrows work again. |
| Click far outside the panel (e.g., into the chat area) | `[focused]` clears; arrows stop affecting the marker. |
| Press Ctrl+G | Panel closes. |
| Type `/terminal-surface-demo` | Panel re-opens cleanly. |
| Type `/terminal-surface-demo` again | Panel closes via the toggle path. |

If any step fails, surface which one before committing.

- [ ] **Step 5: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/coding-agent/examples/extensions/terminal-surface-demo.ts
git commit -m "feat(extensions): rewrite terminal-surface-demo on OverlayHandle.onPointer + click-to-focus"
```

---

## v2 Scope (next plan)

The work below is intentionally deferred to a follow-up plan because each item depends on understanding `interactive-mode.ts` chat-message rendering, which has not yet been investigated:

- `MessageHandle` for `registerMessageRenderer` components: rect awareness (analogous to `OverlayHandle.getRect` / `onRectChange`), `onPointer`, `focus` / `unfocus`.
- Click-to-focus extended to inline message components.
- Auto-release on inline-message scroll-out-of-view.
- Inline variant of `/surface-lab inline`.

The first task in v2 is an investigation: read `interactive-mode.ts` and document where chat messages are rendered, how their viewport position is tracked, and where the cleanest hook point is for `MessageRect` tracking. After that, v2 follows the same TDD structure as v1.

---

## Self-Review

**Spec coverage:**

- [x] Structured pointer events with cell coordinates → Chunks 1, 3
- [x] Mouse mode lifecycle owned by TUI → Chunk 2
- [x] Per-handle pointer subscription on `OverlayHandle` → Chunk 3
- [ ] Per-handle pointer subscription on `MessageHandle` → **deferred to v2** (documented above)
- [x] Click-to-focus on overlay components → Chunk 4
- [ ] Click-to-focus on inline components → **deferred to v2**
- [x] Pi-enforced Esc release → Chunk 5
- [x] Click-outside release → Chunk 6
- [x] Auto-release on overlay hide → Chunk 6
- [ ] Auto-release on inline scroll-out → **deferred to v2**
- [x] Wheel routing default to Pi, opt-in for plugin → Chunk 7
- [x] Test extension exercising the floating path → Chunk 8
- [ ] Test extension exercising the inline path → **deferred to v2**

**Placeholder scan:** searched for "TBD", "TODO", "implement later"; only references are inside the v2 deferral block where they are explicit scope deferrals, not gaps in v1 coverage.

**Type consistency check:**

- `PointerEvent` defined in Chunk 1 / Task 1 / Step 3 with fields `{type, row, col, button, buttons, deltaX, deltaY, shiftKey, altKey, ctrlKey, metaKey}`. Used unchanged in Chunks 3, 4, 5, 6, 7, 8.
- `OverlayHandle.onPointer` signature added in Chunk 3 / Task 3 / Step 4 as `(listener, options?: { wheel?: boolean }) => () => void`. The options parameter is added in Chunk 7; tests in Chunks 3-6 use the single-arg form. Consistent.
- `setPluginFocus` / `pluginFocused` / `pluginPreFocus` introduced in Chunk 4 / Task 4 / Step 3, used in Chunks 5 and 6 with consistent semantics.
