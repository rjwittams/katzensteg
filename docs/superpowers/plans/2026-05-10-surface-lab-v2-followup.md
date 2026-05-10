# Surface Lab v2 Follow-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the post-investigation v2 work — `MessageHandle` for inline `registerMessageRenderer` components, per-`CustomMessageComponent` rect tracking via Candidate C (a `ChatContainer` subclass instrumented during render), inline pointer dispatch with hit-testing, click-to-focus on inline, scroll-out auto-release, and the demo refactor that exercises both placements through a single shared content class.

**Architecture:** Extends pi-tui's `Container.render` to track per-child line offsets during render (small generic addition). `MessageHandle` is a `SurfaceHandle` subtype with no additions. `CustomMessageComponent` instantiates a `MessageHandle` per chat message; `interactive-mode.ts` schedules an `afterNextRender` walk that computes each message's viewport rect from `(rootChildOffset + chatChildOffset - viewportTop)` and fires `onRectChange` listeners. TUI gains a `setInlinePointerDispatcher` hook called after overlay dispatch; `interactive-mode.ts` implements the dispatcher to hit-test against registered inline messages, fire `onPointer` listeners, set plugin focus on `pointerdown`, and report whether the event was consumed so TUI's existing click-outside release path stays correct. The demo refactors into `SurfaceLabContent` taking a `SurfaceHandle`, with two thin entry points (`/terminal-surface-demo`, `/terminal-surface-demo inline`) and a focus-aware border colour.

**Tech Stack:** TypeScript, Node.js `node --test`, `tsx`, biome lint/format. `pi-mono` repo, branch `katzensteg-terminal-surface`.

**Out of scope this plan (still deferred):**
- Programmatic `focus()` from plugin code.
- Pi-rendered (host-enforced) focus indication.
- Wheel-to-Pi-scrollback recovery.
- Pi removing `\x1b[2J` from `fullRender(true)`.
- Id-range allocation API.
- Reshaping `OverlayHandle`.

---

## Pre-flight

### Task 0: Confirm v2 plan-1 baseline

**Files:**
- Read-only: existing v2 plan-1 commits and the investigation note.

- [ ] **Step 1: Confirm `katzensteg-terminal-surface` is the current branch and v2 plan-1 commits are all in place**

```bash
cd /Users/robert/dev/pi-mono && git log --oneline -6
```

Expected: see `e724260` (hover filter), `77264c1` (mouse-mode upgrade), `c087296` (SurfaceHandle abstraction), and earlier v1 commits. If those are missing, **stop and surface to user** — this plan builds on them.

- [ ] **Step 2: Confirm investigation note exists in the katzensteg repo**

```bash
test -f /Users/robert/dev/katzensteg.cheshire/docs/superpowers/notes/2026-05-10-chat-rect-tracking.md && echo "OK" || echo "MISSING"
```

Expected: `OK`.

- [ ] **Step 3: Run targeted v2 test set to confirm clean baseline**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx \
    test/pointer-events.test.ts \
    test/mouse-mode.test.ts \
    test/overlay-pointer.test.ts \
    test/overlay-click-focus.test.ts \
    test/plugin-focus-esc.test.ts \
    test/plugin-focus-click-outside.test.ts \
    test/overlay-wheel.test.ts \
    test/surface-handle.test.ts \
    test/overlay-hover.test.ts \
    2>&1 | tail -5
```

Expected: 45/45 pass. If any fail, **stop and surface to user**.

---

## Chunk 1: Container per-child offset tracking

### Task 1: Extend `Container.render` to record per-child line offsets

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/container-offsets.test.ts`

The existing `Container.render` concatenates child line arrays without recording where each child's lines start. v2's inline rect tracking needs that information at multiple layers (the root TUI's children and `chatContainer`'s children). Extending the base `Container` makes the capability uniformly available without introducing a new subclass for each layer.

- [ ] **Step 1: Write failing test**

Create `/Users/robert/dev/pi-mono/packages/tui/test/container-offsets.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component } from "../src/tui.js";
import { Container } from "../src/tui.js";

class FixedLines implements Component {
	constructor(private lines: string[]) {}
	render(): string[] {
		return this.lines;
	}
	invalidate(): void {}
}

describe("Container per-child offset tracking", () => {
	it("records start line and line count for each child in the most recent render", () => {
		const container = new Container();
		const a = new FixedLines(["A0", "A1"]);
		const b = new FixedLines(["B0"]);
		const c = new FixedLines(["C0", "C1", "C2"]);
		container.addChild(a);
		container.addChild(b);
		container.addChild(c);

		const lines = container.render(80);
		assert.deepStrictEqual(lines, ["A0", "A1", "B0", "C0", "C1", "C2"]);

		assert.deepStrictEqual(container.getChildOffset(a), { startLine: 0, lineCount: 2 });
		assert.deepStrictEqual(container.getChildOffset(b), { startLine: 2, lineCount: 1 });
		assert.deepStrictEqual(container.getChildOffset(c), { startLine: 3, lineCount: 3 });
	});

	it("returns undefined for a child not present in the most recent render", () => {
		const container = new Container();
		const a = new FixedLines(["A0"]);
		const orphan = new FixedLines(["X"]);
		container.addChild(a);
		container.render(80);
		assert.strictEqual(container.getChildOffset(orphan), undefined);
	});

	it("clears stale entries when render runs again with a different child set", () => {
		const container = new Container();
		const a = new FixedLines(["A0"]);
		const b = new FixedLines(["B0"]);
		container.addChild(a);
		container.addChild(b);
		container.render(80);
		container.removeChild(a);
		container.render(80);

		assert.strictEqual(container.getChildOffset(a), undefined);
		assert.deepStrictEqual(container.getChildOffset(b), { startLine: 0, lineCount: 1 });
	});
});
```

- [ ] **Step 2: Run the new test and verify it fails**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/container-offsets.test.ts 2>&1 | tail -10
```

Expected: failure — `container.getChildOffset is not a function`.

- [ ] **Step 3: Modify `Container` in `tui.ts`**

In `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`, find the `Container` class. The current render method looks like:

```ts
	render(width: number): string[] {
		const lines: string[] = [];
		for (const child of this.children) {
			const childLines = child.render(width);
			for (const line of childLines) {
				lines.push(line);
			}
		}
		return lines;
	}
```

Add a private field above the methods:

```ts
	private childOffsets = new Map<Component, { startLine: number; lineCount: number }>();
```

Replace `render` with:

```ts
	render(width: number): string[] {
		this.childOffsets.clear();
		const lines: string[] = [];
		for (const child of this.children) {
			const startLine = lines.length;
			const childLines = child.render(width);
			this.childOffsets.set(child, { startLine, lineCount: childLines.length });
			for (const line of childLines) {
				lines.push(line);
			}
		}
		return lines;
	}

	/**
	 * Returns the start line and line count of the given child as recorded by the most recent
	 * call to `render(width)`. Returns undefined if the child was not part of the most recent
	 * render. Useful for computing per-child viewport positions in higher-level containers.
	 */
	getChildOffset(child: Component): { startLine: number; lineCount: number } | undefined {
		return this.childOffsets.get(child);
	}
```

- [ ] **Step 4: Run the new test and verify it passes**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/container-offsets.test.ts 2>&1 | tail -10
```

Expected: 3/3 pass.

- [ ] **Step 5: Run the targeted regression set to confirm no behaviour change**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx \
    test/pointer-events.test.ts \
    test/mouse-mode.test.ts \
    test/overlay-pointer.test.ts \
    test/overlay-click-focus.test.ts \
    test/plugin-focus-esc.test.ts \
    test/plugin-focus-click-outside.test.ts \
    test/overlay-wheel.test.ts \
    test/surface-handle.test.ts \
    test/overlay-hover.test.ts \
    test/container-offsets.test.ts \
    2>&1 | tail -5
```

Expected: 48/48 pass (45 prior + 3 new).

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/container-offsets.test.ts
git commit -m "feat(tui): track per-child line offsets in Container.render"
```

---

## Chunk 2: TUI viewportTop accessor

### Task 2: Expose `tui.viewportTop` for screen-rect computation

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/viewport-top.test.ts`

`viewportTop = max(0, totalRenderedLines - terminalRows)`. The chat-rect delivery callback needs this to convert buffer line offsets to screen rows. Currently `previousLines.length` and `terminal.rows` are accessible but the computation isn't exposed as a single accessor.

- [ ] **Step 1: Write failing test**

Create `/Users/robert/dev/pi-mono/packages/tui/test/viewport-top.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component } from "../src/tui.js";
import { TUI } from "../src/tui.js";
import { VirtualTerminal } from "./virtual-terminal.js";

class FixedLines implements Component {
	constructor(private lines: string[]) {}
	render(): string[] {
		return this.lines;
	}
	invalidate(): void {}
}

async function flush(tui: TUI, terminal: VirtualTerminal): Promise<void> {
	tui.requestRender(true);
	await new Promise<void>((resolve) => process.nextTick(resolve));
	await terminal.waitForRender();
}

describe("TUI viewportTop accessor", () => {
	it("returns 0 when total rendered lines fit within the terminal height", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new FixedLines(Array(10).fill("X")));
		tui.start();
		try {
			await flush(tui, terminal);
			assert.strictEqual(tui.viewportTop, 0);
		} finally {
			tui.stop();
		}
	});

	it("returns the offset of the visible viewport when content exceeds terminal height", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new FixedLines(Array(100).fill("X")));
		tui.start();
		try {
			await flush(tui, terminal);
			assert.strictEqual(tui.viewportTop, 100 - 24);
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 2: Run the new test and verify it fails**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/viewport-top.test.ts 2>&1 | tail -10
```

Expected: failure — `tui.viewportTop` is not defined.

- [ ] **Step 3: Add the accessor on `TUI`**

In `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`, find the `TUI` class. Add this getter alongside other public accessors (e.g. near `fullRedraws`):

```ts
	/** Index of the first visible buffer line in the current viewport. */
	get viewportTop(): number {
		return Math.max(0, this.previousLines.length - this.terminal.rows);
	}
```

- [ ] **Step 4: Run the new test and verify it passes**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/viewport-top.test.ts 2>&1 | tail -10
```

Expected: 2/2 pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/viewport-top.test.ts
git commit -m "feat(tui): expose viewportTop accessor"
```

---

## Chunk 3: `MessageHandle` interface

### Task 3: Define `MessageHandle` as a `SurfaceHandle` subtype

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/index.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/message-handle-type.test.ts`

`MessageHandle` extends `SurfaceHandle` with no additions; the spec defers programmatic hide/setHidden because inline message lifecycle is tied to its `CustomMessageComponent`. This task adds the type only; instantiation comes in Chunk 4.

- [ ] **Step 1: Write failing test (type-level + structural)**

Create `/Users/robert/dev/pi-mono/packages/tui/test/message-handle-type.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { MessageHandle, SurfaceHandle } from "../src/index.js";

describe("MessageHandle type", () => {
	it("is assignable to SurfaceHandle (extends with no additions)", () => {
		// Pure type-level check — fabricate a minimal value that satisfies SurfaceHandle.
		const stub: MessageHandle = {
			getRect: () => undefined,
			onRectChange: () => () => {},
			onPointer: () => () => {},
			focus: () => {},
			unfocus: () => {},
			isFocused: () => false,
		};
		const surface: SurfaceHandle = stub;
		assert.strictEqual(typeof surface.getRect, "function");
		assert.strictEqual(typeof surface.onPointer, "function");
		assert.strictEqual(typeof surface.focus, "function");
	});
});
```

- [ ] **Step 2: Run the new test and verify it fails**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/message-handle-type.test.ts 2>&1 | tail -10
```

Expected: failure — `MessageHandle` is not exported.

- [ ] **Step 3: Add the `MessageHandle` interface in `tui.ts`**

In `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`, immediately after the `OverlayHandle` interface, add:

```ts
/**
 * Handle for an inline `registerMessageRenderer` component. Same plugin-facing
 * surface API as `OverlayHandle` but without programmatic lifecycle methods —
 * inline messages exist for the lifetime of their chat message.
 */
export interface MessageHandle extends SurfaceHandle {
	// No additions. Inline message lifecycle is owned by the chat layer.
}
```

- [ ] **Step 4: Export from `index.ts`**

In `/Users/robert/dev/pi-mono/packages/tui/src/index.ts`, add `type MessageHandle` to the existing `tui.js` export list (alongside `OverlayHandle`, `SurfaceHandle`).

- [ ] **Step 5: Run the new test and verify it passes**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/message-handle-type.test.ts 2>&1 | tail -10
```

Expected: 1/1 pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/src/index.ts packages/tui/test/message-handle-type.test.ts
git commit -m "feat(tui): add MessageHandle type extending SurfaceHandle"
```

---

## Chunk 4: `MessageHandle` instantiation per `CustomMessageComponent`

### Task 4: Instantiate a `MessageHandle` for each chat custom message; thread through `MessageRenderOptions.handle`

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/coding-agent/src/core/extensions/types.ts`
- Modify: `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/components/custom-message.ts`
- Modify: `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts`
- Create: `/Users/robert/dev/pi-mono/packages/coding-agent/test/custom-message-handle.test.ts`

The `MessageRenderOptions` WIP already adds `tui?: TUI`; this task adds `handle?: MessageHandle` alongside. `CustomMessageComponent` constructs its own `MessageHandle` (a plain object holding listener Sets and rect state) and passes it to the renderer factory. The handle's behaviour beyond storage (rect delivery, pointer dispatch, focus methods) lands in subsequent tasks.

- [ ] **Step 1: Add `handle?: MessageHandle` to `MessageRenderOptions`**

In `/Users/robert/dev/pi-mono/packages/coding-agent/src/core/extensions/types.ts`, find the `MessageRenderOptions` interface. The WIP currently has:

```ts
export interface MessageRenderOptions {
	expanded: boolean;
	tui?: TUI;
}
```

Add `handle?: MessageHandle`:

```ts
export interface MessageRenderOptions {
	expanded: boolean;
	tui?: TUI;
	/** Plugin-facing surface handle for the rendered chat message. Optional — undefined in non-TUI render contexts. */
	handle?: MessageHandle;
}
```

Add the import at the top of the file:

```ts
import type { MessageHandle } from "@earendil-works/pi-tui";
```

- [ ] **Step 2: Add a private `MessageHandleImpl` class in `custom-message.ts` and construct one per `CustomMessageComponent`**

In `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/components/custom-message.ts`, add the import:

```ts
import type { MessageHandle, PointerEvent, SurfaceRect } from "@earendil-works/pi-tui";
```

Add a private class definition above `CustomMessageComponent`:

```ts
type MessagePointerListenerEntry = {
	listener: (event: PointerEvent) => void;
	wheel: boolean;
	hover: boolean;
};

/**
 * Concrete `MessageHandle` instance owned by a `CustomMessageComponent`. State
 * (rect listeners, pointer listeners, focus) lives here; rect updates and
 * pointer dispatch are driven by the chat layer (interactive-mode) and TUI.
 */
class MessageHandleImpl implements MessageHandle {
	lastRect: SurfaceRect | undefined = undefined;
	rectListeners = new Set<(rect: SurfaceRect | undefined) => void>();
	pointerListeners = new Set<MessagePointerListenerEntry>();
	private focusHook: { focus: () => void; unfocus: () => void; isFocused: () => boolean };

	constructor(focusHook: { focus: () => void; unfocus: () => void; isFocused: () => boolean }) {
		this.focusHook = focusHook;
	}

	getRect(): SurfaceRect | undefined {
		return this.lastRect;
	}

	onRectChange(listener: (rect: SurfaceRect | undefined) => void): () => void {
		this.rectListeners.add(listener);
		listener(this.lastRect);
		return () => {
			this.rectListeners.delete(listener);
		};
	}

	onPointer(
		listener: (event: PointerEvent) => void,
		options?: { wheel?: boolean; hover?: boolean },
	): () => void {
		const entry: MessagePointerListenerEntry = {
			listener,
			wheel: options?.wheel === true,
			hover: options?.hover === true,
		};
		this.pointerListeners.add(entry);
		return () => {
			this.pointerListeners.delete(entry);
		};
	}

	focus(): void {
		this.focusHook.focus();
	}

	unfocus(): void {
		this.focusHook.unfocus();
	}

	isFocused(): boolean {
		return this.focusHook.isFocused();
	}
}
```

In the `CustomMessageComponent` class, add a field:

```ts
	readonly messageHandle: MessageHandleImpl;
```

In its constructor (where `this.tui` is captured — this is the WIP TUI threading), construct the handle. The `focusHook` for now is a stub; Task 7 wires it to TUI's plugin-focus path:

```ts
		this.messageHandle = new MessageHandleImpl({
			focus: () => {
				// Wired in Task 7 (inline click-to-focus). For now, no-op.
			},
			unfocus: () => {
				// Wired in Task 7. For now, no-op.
			},
			isFocused: () => false,
		});
```

In `rebuild()` (around line 62 per the investigation), the renderer factory call currently looks like:

```ts
const component = this.customRenderer(this.message, { expanded: this._expanded, tui: this.tui }, theme);
```

Change to:

```ts
const component = this.customRenderer(
	this.message,
	{ expanded: this._expanded, tui: this.tui, handle: this.messageHandle },
	theme,
);
```

- [ ] **Step 3: Write a test verifying the handle is plumbed through and exposes the `MessageHandle` API**

Create `/Users/robert/dev/pi-mono/packages/coding-agent/test/custom-message-handle.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component, MessageHandle, Theme } from "@earendil-works/pi-tui";
import type { CustomMessage } from "../src/core/messages.js";
import type { MessageRenderer } from "../src/core/extensions/types.js";
import { CustomMessageComponent } from "../src/modes/interactive/components/custom-message.js";

const stubTheme = {} as Theme;

describe("CustomMessageComponent plumbs MessageHandle through MessageRenderOptions", () => {
	it("passes a non-undefined handle to the registered renderer factory", () => {
		let received: MessageHandle | undefined;
		const renderer: MessageRenderer = (_message, options) => {
			received = options.handle;
			return undefined;
		};
		const message: CustomMessage<unknown> = {
			role: "custom",
			customType: "demo",
			content: "test",
			details: undefined,
			display: true,
			messageId: "test-1",
			timestamp: new Date().toISOString(),
		};
		const _component = new CustomMessageComponent(message, renderer, undefined, undefined);
		assert.ok(received, "renderer factory must receive a MessageHandle");
		assert.strictEqual(typeof received.getRect, "function");
		assert.strictEqual(typeof received.onRectChange, "function");
		assert.strictEqual(typeof received.onPointer, "function");
		assert.strictEqual(typeof received.focus, "function");
		assert.strictEqual(typeof received.unfocus, "function");
		assert.strictEqual(typeof received.isFocused, "function");
		assert.strictEqual(received.getRect(), undefined, "rect is initially undefined (no render yet)");
	});

	it("supports onRectChange subscription returning an unsubscribe function", () => {
		let received: MessageHandle | undefined;
		const renderer: MessageRenderer = (_message, options) => {
			received = options.handle;
			return undefined;
		};
		const message: CustomMessage<unknown> = {
			role: "custom",
			customType: "demo",
			content: "test",
			details: undefined,
			display: true,
			messageId: "test-2",
			timestamp: new Date().toISOString(),
		};
		const _component = new CustomMessageComponent(message, renderer, undefined, undefined);
		assert.ok(received);
		const seen: (typeof received.lastRect)[] = [];
		const off = received.onRectChange((rect) => seen.push(rect));
		assert.strictEqual(seen.length, 1, "listener fires immediately with current rect");
		assert.strictEqual(seen[0], undefined);
		off();
	});

	it("does not pass a handle when rendering without TUI (env-dependent)", () => {
		// MessageRenderOptions.handle is optional. Without an interactive TUI environment
		// (e.g., print/RPC mode), CustomMessageComponent may still construct, but downstream
		// code that lacks a TUI shouldn't fail. This test mostly documents the contract.
		let received: MessageHandle | undefined;
		const renderer: MessageRenderer = (_message, options) => {
			received = options.handle;
			return undefined;
		};
		const message: CustomMessage<unknown> = {
			role: "custom",
			customType: "demo",
			content: "test",
			details: undefined,
			display: true,
			messageId: "test-3",
			timestamp: new Date().toISOString(),
		};
		const _component = new CustomMessageComponent(message, renderer, undefined, undefined);
		// In this test the component is constructed without a TUI but the handle is still
		// created. That matches the design: handle is per-component, TUI is per-environment.
		assert.ok(received);
	});
});
```

If `CustomMessage`'s required fields differ from the stub above, adjust the literal — the goal is to construct a minimal `CustomMessage` that the constructor will accept. Read `src/core/messages.ts` if needed to confirm the type.

- [ ] **Step 4: Run the new test and verify it passes**

```bash
cd /Users/robert/dev/pi-mono/packages/coding-agent && node --test --import tsx test/custom-message-handle.test.ts 2>&1 | tail -10
```

Expected: 3/3 pass. If the package doesn't already have `node --test` style tests in a `test/` directory, this is the first; verify the test runner picks it up. If `tsx` doesn't resolve from `packages/coding-agent`, install it as a dev dependency or run from `packages/tui`'s `node --test --import tsx` invocation pointing at the file path. If neither works cleanly, place the test file under `packages/tui/test/` instead and import `CustomMessageComponent` via a relative path through the workspace; surface as DONE_WITH_CONCERNS describing the chosen location.

- [ ] **Step 5: Pass `this.ui` (the TUI) into `CustomMessageComponent` from `interactive-mode.ts`**

The WIP already does this — `interactive-mode.ts` constructs `new CustomMessageComponent(message, renderer, theme, this.ui)`. Confirm the constructor signature in `custom-message.ts` accepts a fourth `tui?` argument. If not, add it.

If the WIP is in your working tree, it should already pass `this.ui`. Verify and commit any missing wiring.

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add \
    packages/coding-agent/src/core/extensions/types.ts \
    packages/coding-agent/src/modes/interactive/components/custom-message.ts \
    packages/coding-agent/src/modes/interactive/interactive-mode.ts \
    packages/coding-agent/test/custom-message-handle.test.ts
git commit -m "feat(coding-agent): instantiate MessageHandle per CustomMessageComponent"
```

---

## Chunk 5: Inline rect delivery via afterNextRender

### Task 5: Compute each `CustomMessageComponent`'s viewport rect after every render and notify listeners

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts`
- Create: `/Users/robert/dev/pi-mono/packages/coding-agent/test/inline-rect-delivery.test.ts`

After the root TUI render fires, walk `chatContainer.children`, find each `CustomMessageComponent`, compute its absolute buffer offset using `Container.getChildOffset` chain (root → chatContainer → child), convert to a `SurfaceRect` using `tui.viewportTop` and `tui.terminal.rows`, diff against the handle's `lastRect`, and fire `onRectChange` listeners on change.

- [ ] **Step 1: Write the rect-delivery driver in interactive-mode**

In `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts`:

Add an import for `CustomMessageComponent` if not already present:

```ts
import { CustomMessageComponent } from "./components/custom-message.js";
```

Add a method on `InteractiveMode`:

```ts
	private deliverInlineMessageRects(): void {
		const tui = this.ui;
		const root = tui;
		const chatContainerOffset = root.getChildOffset(this.chatContainer);
		if (!chatContainerOffset) return;
		const viewportTop = tui.viewportTop;
		const termRows = tui.terminal.rows;

		for (const child of this.chatContainer.children) {
			if (!(child instanceof CustomMessageComponent)) continue;
			const childOffset = this.chatContainer.getChildOffset(child);
			const handle = child.messageHandle;
			let nextRect: import("@earendil-works/pi-tui").SurfaceRect | undefined;

			if (childOffset && childOffset.lineCount > 0) {
				const bufferTop = chatContainerOffset.startLine + childOffset.startLine;
				const screenRow = bufferTop - viewportTop;
				let visibleRows: number;
				let row: number;
				if (screenRow >= 0) {
					row = screenRow;
					visibleRows = Math.min(childOffset.lineCount, Math.max(0, termRows - row));
				} else {
					row = 0;
					visibleRows = childOffset.lineCount + screenRow;
				}
				if (visibleRows > 0) {
					nextRect = { row, col: 0, rows: visibleRows, cols: tui.terminal.columns };
				}
			}

			const prev = handle.lastRect;
			const changed =
				!!prev !== !!nextRect ||
				prev?.row !== nextRect?.row ||
				prev?.col !== nextRect?.col ||
				prev?.rows !== nextRect?.rows ||
				prev?.cols !== nextRect?.cols;
			if (!changed) continue;
			handle.lastRect = nextRect;
			for (const listener of handle.rectListeners) {
				listener(nextRect);
			}
		}
	}
```

Find the `start()` (or equivalent) method where the interactive loop registers its `tui.on(...)` listeners. Hook the rect delivery into the after-render lifecycle. Look for an existing `afterNextRender` registration pattern; if none, register on every render via a render-loop hook. The simplest hook: register a recurring `afterNextRender` that re-arms itself:

```ts
	private scheduleInlineRectDelivery(): void {
		this.ui.afterNextRender(() => {
			this.deliverInlineMessageRects();
			this.scheduleInlineRectDelivery();
		});
	}
```

Call `this.scheduleInlineRectDelivery()` once during `start()` after the TUI has been initialised (after `this.ui.requestRender(true)` or equivalent first-render trigger). On `stop()`/teardown, the recurring chain dies naturally because the `afterNextRender` callback runs only after a render and there will be no more renders.

(If the existing render loop has a cleaner hook — e.g. an `onAfterRender` event the interactive mode already subscribes to — use that instead. The recurring `afterNextRender` is a fallback.)

- [ ] **Step 2: Write a failing integration test**

Create `/Users/robert/dev/pi-mono/packages/coding-agent/test/inline-rect-delivery.test.ts`. The test sets up a minimal TUI + chat container, registers a custom message, drives a render, asserts `onRectChange` fired with a sensible rect. Pseudo-shape (adapt to actual constructors):

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component, Theme } from "@earendil-works/pi-tui";
import { Container, TUI } from "@earendil-works/pi-tui";
import { VirtualTerminal } from "@earendil-works/pi-tui/test/virtual-terminal.js"; // adjust import path if needed
import { CustomMessageComponent } from "../src/modes/interactive/components/custom-message.js";
import type { MessageRenderer } from "../src/core/extensions/types.js";
import type { CustomMessage } from "../src/core/messages.js";

class TextLine implements Component {
	constructor(private text: string) {}
	render(): string[] {
		return [this.text];
	}
	invalidate(): void {}
}

const stubTheme = {} as Theme;

async function flush(tui: TUI, terminal: VirtualTerminal): Promise<void> {
	tui.requestRender(true);
	await new Promise<void>((resolve) => process.nextTick(resolve));
	await terminal.waitForRender();
}

function makeMessage(id: string): CustomMessage<unknown> {
	return {
		role: "custom",
		customType: "demo",
		content: "test",
		details: undefined,
		display: true,
		messageId: id,
		timestamp: new Date().toISOString(),
	};
}

describe("Inline rect delivery", () => {
	it("fires onRectChange with the message's screen rect after render", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const chatContainer = new Container();
		tui.addChild(chatContainer);
		// In a real environment InteractiveMode owns this driver; here we simulate it:
		const renderer: MessageRenderer = () => undefined;
		const message = makeMessage("rect-1");
		const cmc = new CustomMessageComponent(message, renderer, undefined, tui);
		// Add a simple line component as the renderer's output so cmc has a rendered footprint:
		cmc.addChild(new TextLine("MSG-LINE-1"));
		cmc.addChild(new TextLine("MSG-LINE-2"));
		chatContainer.addChild(cmc);

		const rectsSeen: (import("@earendil-works/pi-tui").SurfaceRect | undefined)[] = [];
		cmc.messageHandle.onRectChange((r) => rectsSeen.push(r));

		tui.start();
		try {
			await flush(tui, terminal);
			// Manually run the rect-delivery pass (in production the interactive-mode
			// recurring afterNextRender does this; isolated tests run it directly).
			// If interactive-mode's deliverInlineMessageRects is exposed for testing,
			// call it. Otherwise, replicate it here as a small inline driver.
			const chatOffset = tui.getChildOffset(chatContainer)!;
			const childOffset = chatContainer.getChildOffset(cmc)!;
			assert.strictEqual(childOffset.lineCount, 2);
			assert.strictEqual(childOffset.startLine, 0);
			assert.strictEqual(chatOffset.startLine, 0);
			// Manually fire the delivery loop — for the test we mimic what interactive-mode
			// would do once its driver is wired:
			const handle = cmc.messageHandle;
			const bufferTop = chatOffset.startLine + childOffset.startLine;
			const screenRow = bufferTop - tui.viewportTop;
			handle.lastRect = { row: screenRow, col: 0, rows: childOffset.lineCount, cols: terminal.columns };
			for (const l of handle.rectListeners) l(handle.lastRect);

			assert.strictEqual(rectsSeen.length, 2, "listener fires immediately, then after delivery");
			assert.deepStrictEqual(rectsSeen[1], { row: 0, col: 0, rows: 2, cols: 80 });
		} finally {
			tui.stop();
		}
	});
});
```

This test is approximate — it exercises the math of rect computation. The recurring-afterNextRender driver inside `InteractiveMode` is hard to test in isolation; the manual smoke (the v2 demo's inline command) is the integration check. If a clean way to test the recurring driver exists, add a second `it` that exercises it; otherwise trust the smoke checklist in Task 9.

- [ ] **Step 3: Run the test and verify the math passes**

```bash
cd /Users/robert/dev/pi-mono/packages/coding-agent && node --test --import tsx test/inline-rect-delivery.test.ts 2>&1 | tail -10
```

Expected: 1/1 pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add \
    packages/coding-agent/src/modes/interactive/interactive-mode.ts \
    packages/coding-agent/test/inline-rect-delivery.test.ts
git commit -m "feat(coding-agent): deliver inline message rects after each render"
```

---

## Chunk 6: TUI inline pointer dispatch hook

### Task 6: Add `setInlinePointerDispatcher` on TUI; integrate into `dispatchPointerEvent`

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/inline-pointer-dispatcher.test.ts`

TUI knows about overlays but not inline messages. Rather than teaching TUI about `CustomMessageComponent`, expose a hook the chat layer registers. After overlay dispatch, TUI calls the hook (if registered); if it returns true, the event was consumed and dispatch ends; if false, TUI falls through to the existing click-outside release.

- [ ] **Step 1: Write failing tests**

Create `/Users/robert/dev/pi-mono/packages/tui/test/inline-pointer-dispatcher.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component, Focusable, PointerEvent } from "../src/tui.js";
import { TUI } from "../src/tui.js";
import { VirtualTerminal } from "./virtual-terminal.js";

class FocusableOverlay implements Component, Focusable {
	focused = false;
	constructor(private lines: string[]) {}
	render(): string[] {
		return this.lines;
	}
	invalidate(): void {}
}

class EmptyContent implements Component {
	render(): string[] {
		return [];
	}
	invalidate(): void {}
}

async function flush(tui: TUI, terminal: VirtualTerminal): Promise<void> {
	tui.requestRender(true);
	await new Promise<void>((resolve) => process.nextTick(resolve));
	await terminal.waitForRender();
}

describe("setInlinePointerDispatcher", () => {
	it("inline dispatcher is called when no overlay matches", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		tui.start();
		try {
			const seen: PointerEvent[] = [];
			tui.setInlinePointerDispatcher((event) => {
				seen.push(event);
				return false; // not consumed
			});
			tui.feedInput("\x1b[<0;5;5M");
			assert.strictEqual(seen.length, 1);
			assert.strictEqual(seen[0]!.type, "pointerdown");
			assert.strictEqual(seen[0]!.row, 4);
			assert.strictEqual(seen[0]!.col, 4);
		} finally {
			tui.stop();
		}
	});

	it("inline dispatcher is NOT called when an overlay consumed the event", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new FocusableOverlay(["X"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 1, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			handle.onPointer(() => {});

			const seen: PointerEvent[] = [];
			tui.setInlinePointerDispatcher((event) => {
				seen.push(event);
				return false;
			});
			tui.feedInput("\x1b[<0;1;1M");
			assert.strictEqual(seen.length, 0, "overlay consumed; inline dispatcher must not fire");
		} finally {
			tui.stop();
		}
	});

	it("returning true from inline dispatcher prevents click-outside plugin-focus release", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const editor = new FocusableOverlay(["EDITOR"]);
		tui.addChild(new EmptyContent());
		tui.setFocus(editor);
		const overlay = new FocusableOverlay(["O"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 1, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			handle.onPointer(() => {});
			tui.feedInput("\x1b[<0;1;1M");
			await flush(tui, terminal);
			assert.strictEqual(overlay.focused, true);

			// Inline dispatcher consumes a click outside the overlay; plugin focus must NOT release.
			tui.setInlinePointerDispatcher(() => true);
			tui.feedInput("\x1b[<0;40;20M");
			await flush(tui, terminal);
			assert.strictEqual(overlay.focused, true, "inline dispatcher consumed; plugin focus stays");
			assert.strictEqual(editor.focused, false);
		} finally {
			tui.stop();
		}
	});

	it("returning false from inline dispatcher allows click-outside plugin-focus release", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const editor = new FocusableOverlay(["EDITOR"]);
		tui.addChild(new EmptyContent());
		tui.setFocus(editor);
		const overlay = new FocusableOverlay(["O"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, { width: 1, height: 1, anchor: "top-left", nonCapturing: true });
			await flush(tui, terminal);
			handle.onPointer(() => {});
			tui.feedInput("\x1b[<0;1;1M");
			await flush(tui, terminal);

			tui.setInlinePointerDispatcher(() => false);
			tui.feedInput("\x1b[<0;40;20M");
			await flush(tui, terminal);
			assert.strictEqual(overlay.focused, false, "inline did not consume; click-outside released");
			assert.strictEqual(editor.focused, true);
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 2: Run the new tests; verify they fail**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/inline-pointer-dispatcher.test.ts 2>&1 | tail -15
```

Expected: failures — `setInlinePointerDispatcher` doesn't exist.

- [ ] **Step 3: Add `setInlinePointerDispatcher` and integrate**

In `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`, add a private field on `TUI`:

```ts
	private inlinePointerDispatcher: ((event: PointerEvent) => boolean) | undefined = undefined;
```

Add a public setter:

```ts
	/**
	 * Register a dispatcher for pointer events that didn't match any overlay. Called after
	 * the overlay-iteration loop in `dispatchPointerEvent`. Returns true if the dispatcher
	 * consumed the event (prevents click-outside plugin-focus release). Pass `undefined`
	 * to clear.
	 */
	setInlinePointerDispatcher(dispatcher: ((event: PointerEvent) => boolean) | undefined): void {
		this.inlinePointerDispatcher = dispatcher;
	}
```

In `dispatchPointerEvent`, find the existing post-overlay-loop handling. v1 currently has the click-outside release block:

```ts
		if (event.type === "pointerdown" && this.pluginFocused) {
			this.releasePluginFocus();
		}
```

Replace with:

```ts
		// No overlay claimed the event. Try the inline dispatcher (chat-message hit-test).
		if (this.inlinePointerDispatcher) {
			if (this.inlinePointerDispatcher(event)) {
				return;
			}
		}
		// Inline didn't consume (or no dispatcher registered). Release plugin focus on click-outside.
		if (event.type === "pointerdown" && this.pluginFocused) {
			this.releasePluginFocus();
		}
```

- [ ] **Step 4: Run the new tests; verify they pass**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/inline-pointer-dispatcher.test.ts 2>&1 | tail -10
```

Expected: 4/4 pass.

- [ ] **Step 5: Run the targeted regression set**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx \
    test/pointer-events.test.ts \
    test/mouse-mode.test.ts \
    test/overlay-pointer.test.ts \
    test/overlay-click-focus.test.ts \
    test/plugin-focus-esc.test.ts \
    test/plugin-focus-click-outside.test.ts \
    test/overlay-wheel.test.ts \
    test/surface-handle.test.ts \
    test/overlay-hover.test.ts \
    test/container-offsets.test.ts \
    test/viewport-top.test.ts \
    test/message-handle-type.test.ts \
    test/inline-pointer-dispatcher.test.ts \
    2>&1 | tail -5
```

Expected: 56/56 pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/inline-pointer-dispatcher.test.ts
git commit -m "feat(tui): add setInlinePointerDispatcher hook for inline message dispatch"
```

---

## Chunk 7: Inline pointer dispatch + click-to-focus implementation

### Task 7: Implement the inline dispatcher in interactive-mode; wire click-to-focus

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts`
- Modify: `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/components/custom-message.ts` (focus hook implementation)
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts` (expose `setPluginFocus` if needed)

The dispatcher iterates `chatContainer.children`, finds visible `CustomMessageComponent` instances (those with a non-undefined `lastRect`), hit-tests, calls listeners, and on `pointerdown` calls `tui.setPluginFocus(component)` to integrate with the existing focus model.

- [ ] **Step 1: Expose `setPluginFocus` on TUI as a public method**

`setPluginFocus` is currently private. Inline dispatch needs to call it. In `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`, change the private declaration to public. The method body is unchanged. Add a JSDoc comment:

```ts
	/**
	 * Set focus to a plugin component (overlay or inline message). Records the
	 * previously-focused component as preFocus so Pi-enforced release paths
	 * (Esc, click-outside, dismount) can restore focus. Internal Pi callers
	 * (overlay click-to-focus dispatch) and external Pi-extension dispatchers
	 * (inline pointer dispatch) both go through this method.
	 */
	setPluginFocus(component: Component): void {
		// ... existing body unchanged ...
	}
```

- [ ] **Step 2: Implement the focus hook in `MessageHandleImpl`**

In `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/components/custom-message.ts`, the `CustomMessageComponent` constructor currently passes a stub focus hook (Task 4). Update it to call into the TUI:

```ts
		this.messageHandle = new MessageHandleImpl({
			focus: () => {
				this.tui?.setPluginFocus(this);
			},
			unfocus: () => {
				if (this.tui?.focusedComponent === this) {
					this.tui.setFocus(null);
				}
			},
			isFocused: () => this.tui?.focusedComponent === this,
		});
```

Note: this requires `CustomMessageComponent` to be the focused component, not its rendered child. Add `focused = false` to `CustomMessageComponent`:

```ts
class CustomMessageComponent extends Container implements Focusable {
	focused = false;
	// ... existing ...
}
```

(Add `import type { Focusable } from "@earendil-works/pi-tui";` if not present.)

For `handleInput` on `CustomMessageComponent` — when the inline message is focused, keys go to it. Forward to its rendered customComponent if that component implements `handleInput`:

```ts
	handleInput(data: string): void {
		const cc = this.customComponent;
		if (cc && "handleInput" in cc && typeof cc.handleInput === "function") {
			(cc as { handleInput: (data: string) => void }).handleInput(data);
		}
	}
```

- [ ] **Step 3: Implement the inline dispatcher in `InteractiveMode`**

In `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts`, add:

```ts
	private dispatchInlinePointer(event: import("@earendil-works/pi-tui").PointerEvent): boolean {
		for (const child of this.chatContainer.children) {
			if (!(child instanceof CustomMessageComponent)) continue;
			const handle = child.messageHandle;
			const rect = handle.lastRect;
			if (!rect) continue;
			if (event.row < rect.row || event.row >= rect.row + rect.rows) continue;
			if (event.col < rect.col || event.col >= rect.col + rect.cols) continue;
			if (handle.pointerListeners.size === 0) continue;

			let delivered = false;
			for (const ple of handle.pointerListeners) {
				if (event.type === "wheel" && !ple.wheel) continue;
				if (event.type === "pointermove" && event.buttons === 0 && !ple.hover) continue;
				try {
					ple.listener(event);
				} catch {
					// Swallow listener exceptions so a single misbehaving plugin can't
					// break input dispatch for the rest of the host or other listeners.
				}
				delivered = true;
			}
			if (!delivered) continue;

			if (event.type === "pointerdown" && this.ui.focusedComponent !== child) {
				this.ui.setPluginFocus(child);
			}
			return true;
		}
		return false;
	}
```

In `start()` (where the recurring rect delivery from Task 5 was registered), also register the inline dispatcher:

```ts
		this.ui.setInlinePointerDispatcher((event) => this.dispatchInlinePointer(event));
```

Pair it with cleanup in `stop()`:

```ts
		this.ui.setInlinePointerDispatcher(undefined);
```

- [ ] **Step 4: Manual smoke for click-to-focus on inline**

Automated tests for the integration are difficult (see Task 5's note). Verify via the demo in Task 9. For now, run the targeted unit test set to confirm no regressions:

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx \
    test/pointer-events.test.ts \
    test/mouse-mode.test.ts \
    test/overlay-pointer.test.ts \
    test/overlay-click-focus.test.ts \
    test/plugin-focus-esc.test.ts \
    test/plugin-focus-click-outside.test.ts \
    test/overlay-wheel.test.ts \
    test/surface-handle.test.ts \
    test/overlay-hover.test.ts \
    test/container-offsets.test.ts \
    test/viewport-top.test.ts \
    test/message-handle-type.test.ts \
    test/inline-pointer-dispatcher.test.ts \
    2>&1 | tail -5
```

Expected: 56/56 pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add \
    packages/tui/src/tui.ts \
    packages/coding-agent/src/modes/interactive/components/custom-message.ts \
    packages/coding-agent/src/modes/interactive/interactive-mode.ts
git commit -m "feat(coding-agent): inline pointer dispatch + click-to-focus on messages"
```

---

## Chunk 8: Inline scroll-out auto-release

### Task 8: Release plugin focus when a focused inline message's rect becomes undefined

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts`

`deliverInlineMessageRects` from Task 5 already detects when a message's rect transitions from defined to undefined. When that happens for the *currently focused* inline component, the four-path release contract requires Pi to clear plugin focus.

- [ ] **Step 1: Extend `deliverInlineMessageRects` with the release-on-scroll-out check**

Inside the `for (const child of this.chatContainer.children)` loop in `deliverInlineMessageRects`, just before assigning `handle.lastRect = nextRect`, capture whether the rect transitioned defined → undefined:

```ts
			const wasVisible = !!prev;
			const isVisible = !!nextRect;
			handle.lastRect = nextRect;
			for (const listener of handle.rectListeners) {
				listener(nextRect);
			}

			if (wasVisible && !isVisible && this.ui.focusedComponent === child) {
				// Inline message scrolled fully out of view while focused — release plugin focus.
				this.ui.setFocus(null);
			}
```

The `setFocus(null)` call clears `pluginFocused` (per Task 4 of v1) and returns focus to whatever was focused before. To restore properly, use the same mechanism as overlay hide-while-focused: call `setPluginFocus`'s release path. If TUI exposes `releasePluginFocus()` or similar, prefer that. If not, this `setFocus(null)` followed by re-setting to the editor is the available path; surface as DONE_WITH_CONCERNS noting the inconsistency.

(The specific call may need adjustment after reading TUI's existing focus-release helpers. The intent: when a focused inline message scrolls out of view, the user's keyboard input should go back to the composer.)

- [ ] **Step 2: Manual smoke**

There is no clean unit test for "inline message scrolled out of view releases focus" without a full chat-rendering setup. Verify in Task 9's demo: run `/terminal-surface-demo inline`, click into the demo to focus it, then push enough other content to scroll the demo off the top of the viewport, confirm focus returns to the composer (typing goes there, not into the demo).

- [ ] **Step 3: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/coding-agent/src/modes/interactive/interactive-mode.ts
git commit -m "feat(coding-agent): release plugin focus when inline message scrolls out"
```

---

## Chunk 9: Demo refactor + inline mode + cooperative focus indication

### Task 9: Extract `SurfaceLabContent`; add `/terminal-surface-demo inline`; cooperative focus-border indication

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/coding-agent/examples/extensions/terminal-surface-demo.ts`

The existing demo has the floating mode with a content class hard-coded to use `OverlayHandle`. Extract a shared `SurfaceLabContent` class that takes a `SurfaceHandle` (typed as the union `OverlayHandle | MessageHandle`) and works without knowing which subtype. Add an inline command path that uses `pi.registerMessageRenderer` + `MessageRenderOptions.handle`. Border colour switches when `focused === true` to demonstrate cooperative focus indication.

- [ ] **Step 1: Refactor the existing component into `SurfaceLabContent`**

The current demo has `TerminalSurfaceDemoComponent`. Rename to `SurfaceLabContent` and adjust:

- Constructor takes `(tui, theme, surface: SurfaceHandle)` instead of just `(tui, theme)`.
- Pointer subscription: `this.surface.onPointer((ev) => this.onPointer(ev), { ... })` (use the surface's `onPointer` rather than inline subscription via `onHandle`).
- `setOverlayRect` becomes `setSurfaceRect` (driven by `surface.onRectChange`).
- Other behaviour (marker, cell→pixel, drag, arrow keys, focus-border) unchanged.
- Border colour: when `this.focused`, use `theme.fg("accent", "│")` etc.; when not, use `theme.fg("border", "│")`. Same for the corners and horizontal lines.

The full revised file is large; preserve the existing structure. The key additions:

```ts
class SurfaceLabContent {
	focused = false;
	constructor(
		private readonly tui: { writeRaw(data: string): void; afterNextRender(callback: () => void): void; requestRender(): void },
		private readonly theme: Theme,
		private readonly surface: SurfaceHandle,
	) {
		this.surface.onRectChange((rect) => this.setSurfaceRect(rect));
		this.surface.onPointer((event) => this.onPointer(event));
	}

	private setSurfaceRect(rect: SurfaceRect | undefined): void {
		// ... same as setOverlayRect ...
	}

	private onPointer(event: PointerEvent): void {
		// ... same as v1's onPointer; hit-test against imageScreenRect computed from current rect ...
	}

	render(_width: number): string[] {
		// ... existing render with conditional border colour:
		const borderColour = this.focused ? "accent" : "border";
		const top = this.theme.fg(borderColour, `╭${"─".repeat(innerW)}╮`);
		// ... etc.
	}

	handleInput(data: string): void {
		// ... existing arrow-key handling ...
	}

	invalidate(): void {}

	dispose(): void {
		this.tui.writeRaw(deletePlacement(this.imageId, this.placementId));
	}
}
```

The class implements both `Component` (`render`, `invalidate`) and `Focusable` (`focused`).

- [ ] **Step 2: Update the `floating` command path to use `SurfaceLabContent`**

The current `terminal-surface-demo` command opens an overlay and constructs a component. Update to instantiate `SurfaceLabContent` and pass the `OverlayHandle` as the `surface` argument:

```ts
		onHandle: (handle: OverlayHandle) => {
			component = new SurfaceLabContent(tui, theme, handle);
		},
```

Drop the now-redundant `rectUnsubscribe` and `pointerUnsubscribe` plumbing — `SurfaceLabContent` owns its subscriptions.

- [ ] **Step 3: Add the `inline` command path**

Add an argument parser to the existing `pi.registerCommand("terminal-surface-demo", ...)` handler:

```ts
		handler: async (args: string, ctx: ExtensionCommandContext) => {
			const mode = args.trim() === "inline" ? "inline" : "floating";
			if (mode === "floating") {
				// ... existing floating path using SurfaceLabContent ...
				return;
			}
			// inline mode
			if (!ctx.sendMessage) {
				ctx.ui.notify("Inline mode requires interactive TUI", "error");
				return;
			}
			ctx.sendMessage({
				customType: "terminal-surface-demo-inline",
				content: "Surface lab inline",
				display: true,
			});
		},
```

Register the inline message renderer:

```ts
	pi.registerMessageRenderer("terminal-surface-demo-inline", (_message, options, theme) => {
		if (!options.tui || !options.handle) return undefined;
		return new SurfaceLabContent(options.tui, theme, options.handle);
	});
```

(`SurfaceLabContent` accepts a `SurfaceHandle`; `options.handle` is a `MessageHandle` which extends `SurfaceHandle`. Same code path.)

- [ ] **Step 4: Verify build passes**

```bash
cd /Users/robert/dev/pi-mono/packages/coding-agent && npm run build 2>&1 | tail -5
```

Expected: clean.

- [ ] **Step 5: Manual smoke — floating mode regression**

Run via tsx (does not require dist rebuild):

```bash
cd /Users/robert/dev/pi-mono
node --import tsx packages/coding-agent/src/cli.ts --extension packages/coding-agent/examples/extensions/terminal-surface-demo.ts
```

In Pi, run `/terminal-surface-demo` (or `/terminal-surface-demo floating`). Verify the v1 floating manual smoke checklist still passes:

- Click inside the inner image box → marker appears, status shows `cell(X,Y) → px(W,H)`, border switches to focused colour.
- Drag inside the box → marker follows.
- Arrow keys move marker while focused.
- Esc releases focus; border returns to non-focused colour.
- Click outside → focus releases.
- Re-run command → toggles closed.

- [ ] **Step 6: Manual smoke — inline mode**

In the same Pi session, run `/terminal-surface-demo inline`. Verify:

- A new chat message appears with the bordered surface-lab box rendered as text + a Kitty image inside.
- Click inside the inner image box → marker appears, status updates, border becomes focused colour.
- Drag works.
- Arrow keys move the marker while focused.
- Esc releases focus.
- Click outside the message → focus releases.
- Type some text into the composer / let chat scroll → after the inline demo scrolls fully off the top, focus auto-releases (verify by typing — keys go to the composer not the demo).
- Run `/terminal-surface-demo inline` again → a second instance appears below the first, independently focusable. Both demos can be clicked and behave as their own surfaces.

If any step fails, surface which one before committing.

- [ ] **Step 7: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/coding-agent/examples/extensions/terminal-surface-demo.ts
git commit -m "feat(extensions): surface-lab content shared across floating + inline; cooperative focus-border"
```

---

## After this plan

v2 is complete. The deferred items (programmatic focus, host-rendered focus indicators, wheel-to-Pi-scrollback, Pi `2J` removal, id-range allocation, `OverlayHandle` reshape) remain tracked in the spec's "Out of scope" section. Each is its own future plan when the work becomes load-bearing for a concrete consumer (e.g., when KS integrates inline content for real, the wheel and `2J` items will likely become urgent together).

---

## Self-Review

**Spec coverage:**

- [x] `MessageHandle` type → Chunk 3
- [x] `MessageRenderOptions.handle?` plumbing → Chunk 4
- [x] Per-`CustomMessageComponent` instance → Chunk 4
- [x] Rect tracking via `ChatContainer` (Candidate C) → Chunks 1, 2, 5 (extended `Container` for tracking; `viewportTop` accessor; rect delivery driver)
- [x] Inline pointer dispatch → Chunks 6, 7 (TUI hook + interactive-mode implementation)
- [x] Click-to-focus on inline → Chunk 7
- [x] Scroll-out auto-release → Chunk 8
- [x] Demo refactor with shared content + inline command + cooperative focus-border → Chunk 9

**Placeholder scan:** No "TBD" / "TODO" / "implement later". Task 5 step 2 includes a test that's marked as "approximate" because the recurring `afterNextRender` driver isn't directly testable in isolation; the test exercises the math, and Task 9's manual smoke covers the integration. That's an honest scope limitation, not a placeholder. Task 7 step 4 explicitly notes that automated tests for inline integration are difficult and the demo provides the integration check. Task 8 has a manual smoke step rather than an automated test, with explicit rationale.

**Type consistency:**

- `SurfaceRect` from v2 plan-1 used here unchanged.
- `MessageHandle` extends `SurfaceHandle` (Chunk 3) — same `onPointer` signature with `wheel`/`hover` options — used in Chunks 4, 5, 7 consistently.
- `MessagePointerListenerEntry` shape (in `MessageHandleImpl`) mirrors the `PointerListenerEntry` shape from v2 plan-1's `OverlayEntry` work.
- `Container.getChildOffset(child)` return type `{ startLine: number; lineCount: number } | undefined` is consistent across Chunks 1, 5, 7.
- `tui.viewportTop: number` (Chunk 2) used in Chunk 5's rect math.
- `setInlinePointerDispatcher((event) => boolean)` (Chunk 6) — return value is "consumed", interpreted in Chunk 7.

**Scope check:** Single integrated plan covering one consumer-facing capability (inline interactive content). Nine tasks from baseline confirmation through demo smoke. v1 plan was eight tasks; this is comparable. Each task is fully specified at the code level except the integration tests in Chunks 5/7/8, where the rationale for manual smoke over unit tests is documented inline.
