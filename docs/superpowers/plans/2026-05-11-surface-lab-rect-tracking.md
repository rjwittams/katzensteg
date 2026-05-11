# Surface Lab Rect Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move inline `MessageHandle` rect computation out of `interactive-mode.ts` (reconstructed sum of `getChildOffset` calls) and into the TUI itself, mirroring `OverlayHandle`'s authoritative-by-construction model.

**Architecture:** `Container` gains a `forEachChild(visitor)` method that encapsulates child iteration with per-child offsets. `TUI` gains a `trackComponent(component, listener)` API and an internal map of tracked components. At the end of `doRender`, a single recursive walk traverses the component tree, computes each tracked component's absolute buffer offset, maps to screen rect via the existing `viewportTop` getter, and queues listener fires via `afterNextRender`. Overlay rect-listener fires move from synchronous to `afterNextRender`-deferred to unify timing. `MessageHandleImpl` registers via `trackComponent` from its constructor; `deliverInlineMessageRects` and `scheduleInlineRectDelivery` are deleted from `interactive-mode.ts`.

**Tech Stack:** TypeScript, Node.js, `node:test` test runner, `node --test --import tsx` for direct execution. Workspaces: `packages/tui` (rendering, handles, terminal) and `packages/coding-agent` (interactive mode, message handle implementation).

**Spec:** `/Users/robert/dev/katzensteg.cheshire/docs/superpowers/specs/2026-05-11-surface-lab-rect-tracking-design.md` — read this first.

**Repo + branch:** `/Users/robert/dev/pi-mono`, branch `katzensteg-terminal-surface`. All work happens here.

**Resource constraint:** Do **not** run `npm test` or `vitest` at the repo root — it fans out across packages and consumes many GB of memory. Run only targeted files via `node --test --import tsx <path>`. Do not use `--no-verify` to bypass pre-commit hooks.

---

## File responsibilities

- **`packages/tui/src/tui.ts`** — owns `Container`, `TUI`, `OverlayEntry`, `updateOverlayRect`, `compositeOverlays`, `doRender`. Gains `Container.forEachChild`, `TUI.trackComponent`, `TUI.trackedComponents`, the tracking walk method, and the change to defer `OverlayHandle` rect-listener fires.
- **`packages/coding-agent/src/modes/interactive/components/custom-message.ts`** — owns `MessageHandleImpl` and `CustomMessageComponent`. `MessageHandleImpl` registers via `trackComponent`, exposes a `dispose()` method to unregister, and absorbs the scroll-out focus-release logic that currently lives in `interactive-mode.ts`.
- **`packages/coding-agent/src/modes/interactive/interactive-mode.ts`** — `deliverInlineMessageRects`, `scheduleInlineRectDelivery`, and the call to `scheduleInlineRectDelivery` are removed.
- **`packages/tui/test/container-offsets.test.ts`** — extended with `forEachChild` tests.
- **`packages/tui/test/track-component.test.ts`** — new file, tests for the registration API and the tracking walk.
- **`packages/tui/test/overlay-rect-timing.test.ts`** — new file, tests that overlay rect-listener fires are deferred via `afterNextRender`.

---

## Task 1: `Container.forEachChild`

**Files:**
- Modify: `packages/tui/src/tui.ts` — `Container` class (around lines 262-311)
- Test: `packages/tui/test/container-offsets.test.ts` — extend existing file

- [ ] **Step 1: Write the failing test**

Append at the end of the `describe("Container per-child offset tracking", ...)` block in `packages/tui/test/container-offsets.test.ts`:

```ts
	it("forEachChild visits each rendered child with its startLine and lineCount", () => {
		const container = new Container();
		const a = new FixedLines(["A0", "A1"]);
		const b = new FixedLines(["B0"]);
		const c = new FixedLines(["C0", "C1", "C2"]);
		container.addChild(a);
		container.addChild(b);
		container.addChild(c);
		container.render(80);

		const visits: Array<{ child: unknown; startLine: number; lineCount: number }> = [];
		container.forEachChild((child, startLine, lineCount) => {
			visits.push({ child, startLine, lineCount });
		});
		assert.deepStrictEqual(visits, [
			{ child: a, startLine: 0, lineCount: 2 },
			{ child: b, startLine: 2, lineCount: 1 },
			{ child: c, startLine: 3, lineCount: 3 },
		]);
	});

	it("forEachChild skips children with no recorded offset", () => {
		const container = new Container();
		const a = new FixedLines(["A0"]);
		container.addChild(a);
		// No render() — childOffsets is empty.

		const visits: unknown[] = [];
		container.forEachChild((child) => {
			visits.push(child);
		});
		assert.deepStrictEqual(visits, []);
	});

	it("forEachChild is a no-op on an empty Container", () => {
		const container = new Container();
		let called = false;
		container.forEachChild(() => {
			called = true;
		});
		assert.strictEqual(called, false);
	});
```

- [ ] **Step 2: Run test to verify it fails**

Run from `/Users/robert/dev/pi-mono`:

```bash
node --test --import tsx packages/tui/test/container-offsets.test.ts
```

Expected: three new tests fail with `TypeError: container.forEachChild is not a function`.

- [ ] **Step 3: Add `forEachChild` to `Container`**

In `packages/tui/src/tui.ts`, after the `getChildOffset` method (around line 308-310), add:

```ts
	/**
	 * Iterates this container's rendered children, invoking `visitor` once per child
	 * with its start line and line count from the most recent render. Children that
	 * have no recorded offset (i.e., were not part of the most recent render) are skipped.
	 *
	 * This is the encapsulated iteration protocol used by `TUI.trackComponent`'s walk.
	 * External code should prefer this over reading `children` and calling `getChildOffset`
	 * directly.
	 */
	forEachChild(visitor: (child: Component, startLine: number, lineCount: number) => void): void {
		for (const child of this.children) {
			const offset = this.childOffsets.get(child);
			if (offset === undefined) continue;
			visitor(child, offset.startLine, offset.lineCount);
		}
	}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
node --test --import tsx packages/tui/test/container-offsets.test.ts
```

Expected: all tests pass (including the three new ones).

- [ ] **Step 5: Commit**

```bash
git add packages/tui/src/tui.ts packages/tui/test/container-offsets.test.ts
git commit -m "feat(tui): add Container.forEachChild for encapsulated child iteration"
```

---

## Task 2: `TUI.trackComponent` + tracking walk

**Files:**
- Modify: `packages/tui/src/tui.ts` — `TUI` class, `doRender`
- Test: `packages/tui/test/track-component.test.ts` — new file

This task adds the registration API, the per-frame walk, and the `afterNextRender`-deferred listener firing. The walk uses `Container.forEachChild` (from Task 1) and `instanceof Container` for descent.

- [ ] **Step 1: Write the failing test**

Create `packages/tui/test/track-component.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component } from "../src/tui.js";
import type { SurfaceRect } from "../src/index.js";
import { Container, TUI } from "../src/tui.js";
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

describe("TUI.trackComponent", () => {
	it("delivers a rect after the next render for a tracked component in the tree", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const target = new FixedLines(["one", "two", "three"]);
		tui.addChild(target);
		tui.start();
		try {
			const calls: Array<SurfaceRect | undefined> = [];
			const unregister = tui.trackComponent(target, (rect) => calls.push(rect));
			await flush(tui, terminal);
			// Expected: lines.length=3, terminal.rows=24, viewportTop=max(0, 3-24)=0,
			// bufferOffset=0, top=0, visTop=0, visBottom=3, rows=3.
			assert.strictEqual(calls.length, 1, "listener should fire once after first render");
			const rect = calls[0];
			assert.ok(rect, "rect should be defined for a visible component");
			assert.strictEqual(rect.row, 0);
			assert.strictEqual(rect.col, 0);
			assert.strictEqual(rect.rows, 3);
			assert.strictEqual(rect.cols, 80);
			assert.strictEqual(rect.totalRows, 3);
			unregister();
		} finally {
			tui.stop();
		}
	});

	it("does not re-fire when the rect is unchanged across renders", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const target = new FixedLines(["x"]);
		tui.addChild(target);
		tui.start();
		try {
			const calls: Array<SurfaceRect | undefined> = [];
			tui.trackComponent(target, (rect) => calls.push(rect));
			await flush(tui, terminal);
			assert.strictEqual(calls.length, 1);
			await flush(tui, terminal);
			assert.strictEqual(calls.length, 1, "second render with identical layout should not re-fire");
		} finally {
			tui.stop();
		}
	});

	it("fires undefined when a tracked component is no longer in the tree", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const target = new FixedLines(["x"]);
		tui.addChild(target);
		tui.start();
		try {
			const calls: Array<SurfaceRect | undefined> = [];
			tui.trackComponent(target, (rect) => calls.push(rect));
			await flush(tui, terminal);
			assert.strictEqual(calls.length, 1);
			assert.ok(calls[0] !== undefined);

			tui.removeChild(target);
			await flush(tui, terminal);
			assert.strictEqual(calls.length, 2);
			assert.strictEqual(calls[1], undefined);
		} finally {
			tui.stop();
		}
	});

	it("descends into Container children to find nested tracked components", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const outer = new Container();
		const target = new FixedLines(["nested"]);
		outer.addChild(new FixedLines(["sib"]));
		outer.addChild(target);
		tui.addChild(outer);
		tui.start();
		try {
			const calls: Array<SurfaceRect | undefined> = [];
			tui.trackComponent(target, (rect) => calls.push(rect));
			await flush(tui, terminal);
			assert.strictEqual(calls.length, 1);
			const rect = calls[0];
			assert.ok(rect);
			assert.strictEqual(rect.row, 1, "nested target sits after 1-line sibling");
			assert.strictEqual(rect.rows, 1);
			assert.strictEqual(rect.totalRows, 1);
		} finally {
			tui.stop();
		}
	});

	it("unregister stops further listener fires", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		const target = new FixedLines(["x"]);
		tui.addChild(target);
		tui.start();
		try {
			const calls: Array<SurfaceRect | undefined> = [];
			const unregister = tui.trackComponent(target, (rect) => calls.push(rect));
			await flush(tui, terminal);
			assert.strictEqual(calls.length, 1);
			unregister();
			tui.removeChild(target);
			await flush(tui, terminal);
			assert.strictEqual(calls.length, 1, "no further fires after unregister");
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
node --test --import tsx packages/tui/test/track-component.test.ts
```

Expected: all tests fail with `tui.trackComponent is not a function` or equivalent.

- [ ] **Step 3: Add state, method, and walk to `TUI`**

In `packages/tui/src/tui.ts`, inside the `TUI` class, add (place near the other private state declarations around lines 322-348):

```ts
	private trackedComponents = new Map<
		Component,
		{
			listener: (rect: SurfaceRect | undefined) => void;
			lastRect: SurfaceRect | undefined;
		}
	>();
```

Add this public method to `TUI` (near other public registration methods, e.g., after `setInlinePointerDispatcher` around line 455):

```ts
	/**
	 * Register a component for rect tracking. The listener fires via
	 * `afterNextRender` whenever the rect changes (field-by-field diff). On the
	 * first render after registration, if the component is in the tree, the
	 * listener fires once with the computed rect (undefined → defined is a
	 * change). Returns an unregister thunk; safe to call repeatedly (idempotent).
	 *
	 * Tracked components are resolved by walking `Container.children` from the
	 * TUI root via `Container.forEachChild`; descendants reachable only outside
	 * that protocol (e.g., rendered "manually" inside a non-Container's render
	 * output) are not trackable.
	 *
	 * This is an internal-ish API for handle implementations (`OverlayHandle`,
	 * `MessageHandle`). Plugins consume rect updates via the handle's own
	 * `onRectChange`, which performs synchronous initial delivery.
	 */
	trackComponent(
		component: Component,
		listener: (rect: SurfaceRect | undefined) => void,
	): () => void {
		const entry = { listener, lastRect: undefined as SurfaceRect | undefined };
		this.trackedComponents.set(component, entry);
		let released = false;
		return () => {
			if (released) return;
			released = true;
			if (this.trackedComponents.get(component) === entry) {
				this.trackedComponents.delete(component);
			}
		};
	}
```

Add this private method to `TUI` (near other render-phase helpers):

```ts
	/**
	 * After Container render has populated childOffsets across the tree, walk the
	 * tree once and deliver per-frame rect updates to all tracked components.
	 * Unvisited tracked components (no longer in the tree) receive `undefined`.
	 */
	private updateTrackedRects(): void {
		if (this.trackedComponents.size === 0) return;
		const unvisited = new Set(this.trackedComponents.keys());
		const walk = (container: Container, abs: number): void => {
			container.forEachChild((child, startLine, lineCount) => {
				const childAbs = abs + startLine;
				if (this.trackedComponents.has(child)) {
					this.deliverTrackedRect(child, childAbs, lineCount);
					unvisited.delete(child);
				}
				if (child instanceof Container) walk(child, childAbs);
			});
		};
		walk(this, 0);
		for (const stale of unvisited) {
			this.deliverTrackedRect(stale, undefined, 0);
		}
	}

	/**
	 * Compute the screen rect from absolute buffer offset + line count, diff
	 * against lastRect, and queue listener fire via afterNextRender on change.
	 * Passing `undefined` for bufferOffset signals "not in tree" → rect undefined.
	 */
	private deliverTrackedRect(
		component: Component,
		bufferOffset: number | undefined,
		lineCount: number,
	): void {
		const entry = this.trackedComponents.get(component);
		if (!entry) return;
		let nextRect: SurfaceRect | undefined;
		if (bufferOffset !== undefined && lineCount > 0) {
			const viewportTop = this.viewportTop;
			const termRows = this.terminal.rows;
			const top = bufferOffset - viewportTop;
			const bottom = top + lineCount;
			const visTop = Math.max(0, top);
			const visBottom = Math.min(termRows, bottom);
			if (visBottom > visTop) {
				nextRect = {
					row: visTop,
					col: 0,
					rows: visBottom - visTop,
					cols: this.terminal.columns,
					totalRows: lineCount,
				};
			}
		}
		const prev = entry.lastRect;
		const changed =
			!!prev !== !!nextRect ||
			prev?.row !== nextRect?.row ||
			prev?.col !== nextRect?.col ||
			prev?.rows !== nextRect?.rows ||
			prev?.cols !== nextRect?.cols ||
			prev?.totalRows !== nextRect?.totalRows;
		if (!changed) return;
		entry.lastRect = nextRect;
		this.afterNextRender(() => entry.listener(nextRect));
	}
```

In `TUI.doRender` (around line 1224 onwards), find the spot at the end of the render flow — after `compositeOverlays` is called and before `afterNextRenderCallbacks` are drained — and add a call:

```ts
		this.updateTrackedRects();
```

To find the exact insertion point: search for where `compositeOverlays` is called in `doRender` (around line 1292), then find the `afterNextRenderCallbacks` drain. `updateTrackedRects()` goes between them. The order matters: the tracking walk must run after `compositeOverlays` (in case overlays affect child offsets, though they don't today), and the queued `afterNextRender` listener fires must reach the same `afterNextRenderCallbacks` queue.

Note that `updateTrackedRects` itself queues listener fires via `this.afterNextRender(...)`. Those callbacks join the existing queue and fire after the current render's terminal write completes.

- [ ] **Step 4: Run test to verify it passes**

```bash
node --test --import tsx packages/tui/test/track-component.test.ts
```

Expected: all 5 tests pass.

Also run the existing tui-related tests to confirm no regression:

```bash
node --test --import tsx packages/tui/test/container-offsets.test.ts packages/tui/test/surface-handle.test.ts packages/tui/test/viewport-top.test.ts
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/tui/src/tui.ts packages/tui/test/track-component.test.ts
git commit -m "feat(tui): add TUI.trackComponent with deferred rect-change listener firing"
```

---

## Task 3: Defer `OverlayHandle.onRectChange` listener fires to `afterNextRender`

**Files:**
- Modify: `packages/tui/src/tui.ts` — `updateOverlayRect` (around line 640-650)
- Test: `packages/tui/test/overlay-rect-timing.test.ts` — new file

This task changes the timing of overlay rect-listener firing from synchronous (inside `compositeOverlays`) to `afterNextRender`-deferred, matching the new `MessageHandle` timing. The initial-delivery semantics (synchronous inside `onRectChange()`) are unchanged.

- [ ] **Step 1: Audit existing overlay-rect-listener consumers**

From `/Users/robert/dev/pi-mono`:

```bash
grep -rn "onRectChange" --include="*.ts" packages/ | grep -v "\.test\." | grep -v "/dist/"
```

Then also check the cheshire repo:

```bash
grep -rn "onRectChange" --include="*.ts" /Users/robert/dev/katzensteg.cheshire/tools/pi-extension/
```

For each consumer, confirm none depend on synchronous listener firing. The known in-repo consumer (`tools/pi-extension/extensions/katzensteg-panel.ts`) already defers its own logic via `afterNextRender` after receiving the rect, so this change is invisible to it. If any consumer does depend on sync timing, document it in the commit message but proceed (the spec calls for the timing change).

- [ ] **Step 2: Write the failing test**

Create `packages/tui/test/overlay-rect-timing.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component } from "../src/tui.js";
import type { SurfaceRect } from "../src/index.js";
import { TUI } from "../src/tui.js";
import { VirtualTerminal } from "./virtual-terminal.js";

class StaticOverlay implements Component {
	render(): string[] {
		return ["X"];
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

describe("OverlayHandle.onRectChange listener firing timing", () => {
	it("delivers the initial rect synchronously inside onRectChange", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		tui.start();
		try {
			const handle = tui.showOverlay(new StaticOverlay(), { width: 1, height: 1, anchor: "top-left" });
			await flush(tui, terminal);

			// At this point handle.lastRect is populated. A subscriber should receive it synchronously.
			const calls: Array<SurfaceRect | undefined> = [];
			handle.onRectChange((rect) => calls.push(rect));
			assert.strictEqual(calls.length, 1, "initial delivery must fire synchronously inside onRectChange()");
			assert.ok(calls[0], "initial rect should be defined for a visible overlay");
		} finally {
			tui.stop();
		}
	});

	it("does not fire change listeners synchronously during render", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		tui.start();
		try {
			const handle = tui.showOverlay(new StaticOverlay(), { width: 1, height: 1, anchor: "top-left" });
			await flush(tui, terminal);

			const seenSync: Array<{ duringRender: boolean }> = [];
			let inRender = false;
			handle.onRectChange(() => {
				seenSync.push({ duringRender: inRender });
			});
			// First call from subscribe fired synchronously — drain it.
			seenSync.length = 0;

			// Toggle hidden state to force a rect change on the next render.
			handle.setHidden(true);
			inRender = true;
			tui.requestRender(true);
			await new Promise<void>((resolve) => process.nextTick(resolve));
			inRender = false;
			await terminal.waitForRender();

			assert.ok(seenSync.length > 0, "listener should have fired for the rect change");
			for (const call of seenSync) {
				assert.strictEqual(
					call.duringRender,
					false,
					"change-fire listener must not run while inRender flag is set",
				);
			}
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 3: Run test to verify it fails**

```bash
node --test --import tsx packages/tui/test/overlay-rect-timing.test.ts
```

Expected: the second test fails because the current code fires `entry.rectListeners` synchronously inside `updateOverlayRect` (called from `compositeOverlays` mid-render). The first test passes (initial delivery already sync — that's unchanged).

- [ ] **Step 4: Defer listener fires in `updateOverlayRect`**

In `packages/tui/src/tui.ts`, find `updateOverlayRect` (around line 640):

```ts
	private updateOverlayRect(entry: OverlayEntry, rect: OverlayRect | undefined): void {
		const prev = entry.lastRect;
		const changed =
			prev?.row !== rect?.row || prev?.col !== rect?.col || prev?.rows !== rect?.rows || prev?.cols !== rect?.cols;
		if (!changed) return;
		entry.lastRect = rect;
		for (const listener of entry.rectListeners) {
			listener(rect);
		}
	}
```

Change to:

```ts
	private updateOverlayRect(entry: OverlayEntry, rect: OverlayRect | undefined): void {
		const prev = entry.lastRect;
		const changed =
			prev?.row !== rect?.row || prev?.col !== rect?.col || prev?.rows !== rect?.rows || prev?.cols !== rect?.cols;
		if (!changed) return;
		entry.lastRect = rect;
		// Defer listener fires to after the current render flushes, so that listener
		// callbacks can safely call `tui.writeRaw` and other terminal-touching APIs
		// without interleaving with this render's own write bytes.
		const listeners = Array.from(entry.rectListeners);
		this.afterNextRender(() => {
			for (const listener of listeners) {
				listener(rect);
			}
		});
	}
```

The `Array.from` snapshot is important: if a listener unsubscribes itself during fire, the set mutation would otherwise affect iteration order in a way that depends on Set internals.

- [ ] **Step 5: Run test to verify it passes**

```bash
node --test --import tsx packages/tui/test/overlay-rect-timing.test.ts
```

Expected: both tests pass.

Run all overlay-related tests to confirm no regression:

```bash
node --test --import tsx packages/tui/test/overlay-click-focus.test.ts packages/tui/test/overlay-hover.test.ts packages/tui/test/overlay-non-capturing.test.ts packages/tui/test/overlay-options.test.ts packages/tui/test/overlay-pointer.test.ts packages/tui/test/overlay-short-content.test.ts packages/tui/test/overlay-wheel.test.ts packages/tui/test/surface-handle.test.ts
```

Expected: all pass. If any test asserts synchronous listener firing on a rect change (vs. initial delivery), update it to await a render flush before checking the listener calls.

- [ ] **Step 6: Commit**

```bash
git add packages/tui/src/tui.ts packages/tui/test/overlay-rect-timing.test.ts
git commit -m "feat(tui): defer OverlayHandle rect-change listener fires to afterNextRender"
```

---

## Task 4: Switch `MessageHandleImpl` to use `TUI.trackComponent`; remove old machinery

**Files:**
- Modify: `packages/coding-agent/src/modes/interactive/components/custom-message.ts`
- Modify: `packages/coding-agent/src/modes/interactive/interactive-mode.ts`
- Test: `packages/tui/test/message-handle-type.test.ts` (verify still passes) and manual smoke (Task 5)

This task atomically replaces the old `deliverInlineMessageRects` machinery in `interactive-mode.ts` with `MessageHandleImpl` self-registering via `trackComponent`. The scroll-out focus-release logic moves into `MessageHandleImpl`'s tracking callback.

- [ ] **Step 1: Modify `MessageHandleImpl` to register via `trackComponent`**

In `packages/coding-agent/src/modes/interactive/components/custom-message.ts`, modify the `MessageHandleImpl` class. Replace the class body with:

```ts
class MessageHandleImpl implements MessageHandle {
	lastRect: SurfaceRect | undefined = undefined;
	rectListeners = new Set<(rect: SurfaceRect | undefined) => void>();
	pointerListeners = new Set<MessagePointerListenerEntry>();
	private focusHook: { focus: () => void; unfocus: () => void; isFocused: () => boolean };
	private tui: TUI | undefined;
	private mouseModeRelease: (() => void) | undefined;
	private rectUnregister: (() => void) | undefined;

	constructor(tui: TUI | undefined, focusHook: { focus: () => void; unfocus: () => void; isFocused: () => boolean }) {
		this.tui = tui;
		this.focusHook = focusHook;
	}

	/**
	 * Connect this handle to a `customComponent` so the TUI delivers rect updates
	 * here. Must be called once when the customComponent becomes known (after the
	 * extension's renderer returns it). Calling again with a different component
	 * unregisters the previous one.
	 */
	attachToComponent(component: Component): void {
		this.rectUnregister?.();
		this.rectUnregister = undefined;
		if (!this.tui) return;
		this.rectUnregister = this.tui.trackComponent(component, (rect) => {
			const wasVisible = !!this.lastRect;
			const isVisible = !!rect;
			this.lastRect = rect;
			for (const listener of this.rectListeners) {
				listener(rect);
			}
			if (wasVisible && !isVisible && this.focusHook.isFocused()) {
				// Scrolled fully out of view while focused — release plugin focus.
				this.focusHook.unfocus();
			}
		});
	}

	/**
	 * Detach from the currently tracked customComponent, if any. Called when the
	 * customComponent is being replaced (rebuild) or the handle is being disposed.
	 */
	detachFromComponent(): void {
		this.rectUnregister?.();
		this.rectUnregister = undefined;
	}

	/** Release all resources held by the handle. */
	dispose(): void {
		this.detachFromComponent();
		if (this.mouseModeRelease) {
			this.mouseModeRelease();
			this.mouseModeRelease = undefined;
		}
		this.pointerListeners.clear();
		this.rectListeners.clear();
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

	onPointer(listener: (event: PointerEvent) => void, options?: { wheel?: boolean; hover?: boolean }): () => void {
		const entry: MessagePointerListenerEntry = {
			listener,
			wheel: options?.wheel === true,
			hover: options?.hover === true,
		};
		this.pointerListeners.add(entry);
		if (this.pointerListeners.size === 1 && this.tui) {
			this.mouseModeRelease = this.tui.acquireMouseMode();
		}
		return () => {
			if (!this.pointerListeners.has(entry)) return;
			this.pointerListeners.delete(entry);
			if (this.pointerListeners.size === 0 && this.mouseModeRelease) {
				this.mouseModeRelease();
				this.mouseModeRelease = undefined;
			}
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

Now modify `CustomMessageComponent.rebuild()` in the same file to call `attachToComponent` after the customComponent is created. Find the existing `rebuild()` method (around lines 141-193), and inside the `if (component)` branch where `this.customComponent = component` is assigned, add the attach call:

```ts
			if (component) {
				// Custom renderer provides its own styled component
				this.customComponent = component;
				this.addChild(component);
				this.messageHandle.attachToComponent(component);
				return;
			}
```

Also modify the top of `rebuild()` to detach when removing the previous customComponent:

```ts
	private rebuild(): void {
		// Remove previous content component
		if (this.customComponent) {
			this.messageHandle.detachFromComponent();
			this.removeChild(this.customComponent);
			this.customComponent = undefined;
		}
		this.removeChild(this.box);
		// ... rest unchanged
```

Add an import for `TUI` (already imported) and the import for `Component` is already at the top. Confirm by reading the file's imports.

- [ ] **Step 2: Remove `deliverInlineMessageRects` and `scheduleInlineRectDelivery` from `interactive-mode.ts`**

In `packages/coding-agent/src/modes/interactive/interactive-mode.ts`:

1. Remove the call site at line 655 (`this.scheduleInlineRectDelivery();`).
2. Remove the entire `deliverInlineMessageRects` method (lines 5485-5540).
3. Remove the entire `scheduleInlineRectDelivery` method (lines 5542-5547).

Leave `dispatchInlinePointer` (starts around line 5549) — it still reads `handle.lastRect` for hit testing, which is now populated by the TUI tracking walk.

- [ ] **Step 3: Build to confirm no broken references**

```bash
cd /Users/robert/dev/pi-mono && npm run build 2>&1 | tail -10
```

Expected: clean build. If errors appear about missing methods or unused imports, fix them.

- [ ] **Step 4: Run all targeted tests**

```bash
cd /Users/robert/dev/pi-mono
node --test --import tsx packages/tui/test/container-offsets.test.ts packages/tui/test/track-component.test.ts packages/tui/test/overlay-rect-timing.test.ts packages/tui/test/surface-handle.test.ts packages/tui/test/message-handle-type.test.ts packages/tui/test/inline-pointer-dispatcher.test.ts packages/tui/test/viewport-top.test.ts
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/coding-agent/src/modes/interactive/components/custom-message.ts packages/coding-agent/src/modes/interactive/interactive-mode.ts
git commit -m "refactor(coding-agent): drive MessageHandle rect via TUI.trackComponent

Removes the reconstructed three-level getChildOffset sum from
interactive-mode.ts. MessageHandleImpl now registers its customComponent
with the TUI directly; rect updates and scroll-out focus release flow
through the handle's tracking callback."
```

---

## Task 5: Manual smoke verification

**Files:** None modified. Verification only.

- [ ] **Step 1: Run the v2 manual smoke checklist for the floating overlay**

From `/Users/robert/dev/pi-mono`, start Pi with the demo extension loaded:

```bash
node --import tsx packages/coding-agent/src/cli.ts --extension packages/coding-agent/examples/extensions/terminal-surface-demo.ts
```

In the Pi chat, type `/terminal-surface-demo` and verify:

1. The floating panel appears in the top-right with a 56-cell-wide bordered box.
2. Click inside the panel → border turns accent colour (focused).
3. Click outside the panel → border returns to default (unfocused).
4. Drag inside the panel → marker follows the cursor.
5. Resize the terminal → panel stays positioned correctly (top-right anchor); demo image redraws.
6. Press Esc while focused → returns focus to chat composer.

Expected: all behaviours match v1/v2 behaviour from before the rework.

- [ ] **Step 2: Run the v2 manual smoke checklist for the inline message**

In the same Pi session, type `/terminal-surface-demo inline`. Verify:

1. An inline custom message renders in the chat scrollback with a bordered panel that stretches to the chat-line width (Task in earlier work — width fix from commit `7776c854`).
2. Click inside the bordered area → border turns accent (focused).
3. Click outside the bordered area (in empty terminal space) → border returns to default (unfocused).
4. Drag inside → marker follows.
5. Scroll the chat (add messages) → image redraws at the new screen position.
6. Resize the terminal → image redraws correctly.
7. Scroll the inline message fully off-screen → focus is released to the chat composer (the spec's path 5).

Expected: all behaviours match v2 behaviour from before the rework. The composer push-up bug (filed upstream separately) is unchanged — the image continues to track text drift identically; that's the parity goal.

- [ ] **Step 3: Confirm the build is clean**

```bash
cd /Users/robert/dev/pi-mono && npm run build 2>&1 | tail -5
```

Expected: clean.

- [ ] **Step 4: Run all targeted tests one final time**

```bash
cd /Users/robert/dev/pi-mono
node --test --import tsx packages/tui/test/container-offsets.test.ts packages/tui/test/track-component.test.ts packages/tui/test/overlay-rect-timing.test.ts packages/tui/test/surface-handle.test.ts packages/tui/test/message-handle-type.test.ts packages/tui/test/inline-pointer-dispatcher.test.ts packages/tui/test/viewport-top.test.ts packages/tui/test/overlay-click-focus.test.ts packages/tui/test/overlay-hover.test.ts packages/tui/test/overlay-non-capturing.test.ts packages/tui/test/overlay-options.test.ts packages/tui/test/overlay-pointer.test.ts packages/tui/test/overlay-short-content.test.ts packages/tui/test/overlay-wheel.test.ts
```

Expected: all pass.

- [ ] **Step 5: Report**

Summarise the work in the final agent report with:
- All commit SHAs from Tasks 1-4.
- Result of the build verification.
- Result of the manual smoke (each numbered item from Steps 1-2 above with pass/fail/notes).
- Any overlay consumers found in Task 3 Step 1 that needed special attention.
