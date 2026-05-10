# Surface Lab v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the pre-investigation v2 work — `SurfaceHandle` as the shared abstraction, mouse-mode upgrade to `?1003h`, hover-as-delivery-filter on `OverlayHandle.onPointer` — plus a written investigation of `interactive-mode.ts`'s chat-rendering path that informs the follow-up plan covering `MessageHandle` integration and the demo refactor.

**Architecture:** v1's existing `OverlayHandle` already exposes most of the surface API. v2 extracts that into a named `SurfaceHandle` interface that `OverlayHandle` extends. The mouse-mode bytes change to `?1003h` so motion-without-button arrives at the dispatch loop, where a per-listener `hover` filter (parallel to the existing `wheel` filter) decides whether each subscriber receives those events. The chat-rendering investigation produces a written design note that the follow-up plan turns into `MessageHandle` plumbing.

**Tech Stack:** TypeScript, Node.js `node --test`, `tsx`, biome lint/format. Single repo: `~/dev/pi-mono`. Continues on the `katzensteg-terminal-surface` branch.

**Out of scope this plan (deferred to v2 follow-up):**
- `MessageHandle` interface + per-`CustomMessageComponent` instantiation
- Inline pointer dispatch + scroll-out release
- Demo refactor + inline command + cooperative focus-border indication
- `MessageRenderOptions.handle?` plumbing

The follow-up plan starts with the investigation deliverable from Chunk 4 of this plan.

---

## Pre-flight

### Task 0: Confirm v1 baseline

**Files:**
- Read-only: existing v1 test files

- [ ] **Step 1: Confirm `katzensteg-terminal-surface` is the current branch**

```bash
cd /Users/robert/dev/pi-mono && git status -sb 2>&1 | head -1
```

Expected output starts with `## katzensteg-terminal-surface`.

- [ ] **Step 2: Run the v1 test suite (single targeted command, no full `npm test`)**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx \
    test/pointer-events.test.ts \
    test/mouse-mode.test.ts \
    test/overlay-pointer.test.ts \
    test/overlay-click-focus.test.ts \
    test/plugin-focus-esc.test.ts \
    test/plugin-focus-click-outside.test.ts \
    test/overlay-wheel.test.ts \
    2>&1 | tail -10
```

Expected: all v1 tests pass (28 tests across 7 files). If any fail, **stop and surface to user** — v2 should not be built on a broken baseline.

---

## Chunk 1: `SurfaceHandle` abstraction

### Task 1: Extract `SurfaceHandle` from `OverlayHandle`; rename `OverlayRect` to `SurfaceRect`

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/index.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/surface-handle.test.ts`

This task is type-level only. It must not change runtime behaviour; all v1 tests continue to pass without modification.

- [ ] **Step 1: Write failing structural test**

Create `/Users/robert/dev/pi-mono/packages/tui/test/surface-handle.test.ts`:

```ts
import assert from "node:assert";
import { describe, it } from "node:test";
import type { Component } from "../src/tui.js";
import { TUI } from "../src/tui.js";
import type { OverlayHandle, SurfaceHandle } from "../src/index.js";
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

describe("SurfaceHandle abstraction", () => {
	it("OverlayHandle is assignable to SurfaceHandle", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		tui.start();
		try {
			const handle: OverlayHandle = tui.showOverlay(new StaticOverlay(), {
				width: 1,
				height: 1,
				anchor: "top-left",
			});
			const surface: SurfaceHandle = handle;
			await flush(tui, terminal);
			// Use a surface-only method to verify the structural type carries.
			const rect = surface.getRect();
			assert.ok(rect, "surface.getRect must return a rect for a visible overlay");
			assert.strictEqual(rect.row, 0);
			assert.strictEqual(rect.col, 0);
		} finally {
			tui.stop();
		}
	});

	it("SurfaceHandle exposes getRect, onRectChange, onPointer, focus, unfocus, isFocused", () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		tui.start();
		try {
			const handle = tui.showOverlay(new StaticOverlay(), { width: 1, height: 1, anchor: "top-left" });
			const surface: SurfaceHandle = handle;
			assert.strictEqual(typeof surface.getRect, "function");
			assert.strictEqual(typeof surface.onRectChange, "function");
			assert.strictEqual(typeof surface.onPointer, "function");
			assert.strictEqual(typeof surface.focus, "function");
			assert.strictEqual(typeof surface.unfocus, "function");
			assert.strictEqual(typeof surface.isFocused, "function");
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 2: Run the new test and verify it fails**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/surface-handle.test.ts 2>&1 | tail -10
```

Expected: failure — `SurfaceHandle` is not exported from `../src/index.js`.

- [ ] **Step 3: Define `SurfaceRect` and `SurfaceHandle` in `tui.ts`; refactor `OverlayHandle` to extend**

In `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`, locate the existing `OverlayRect` interface (around line 184) and the `OverlayHandle` interface that follows it. Replace the block from `OverlayRect`'s `export interface` declaration through the end of the `OverlayHandle` declaration with:

```ts
export interface SurfaceRect {
	/** Zero-based row within the visible terminal viewport. */
	row: number;
	/** Zero-based column within the visible terminal viewport. */
	col: number;
	/** Visible row count (may be smaller than the surface's full row count if partially scrolled). */
	rows: number;
	/** Visible column count. */
	cols: number;
}

/** Backwards-compatible alias for code referring to the v1 name. */
export type OverlayRect = SurfaceRect;

/**
 * Plugin-facing API for an interactive surface (overlay or inline message).
 * Subtypes may add lifecycle methods specific to their placement model.
 */
export interface SurfaceHandle {
	/** Get the current visible viewport rect for this surface, or undefined if hidden / not rendered / fully scrolled out. */
	getRect(): SurfaceRect | undefined;
	/** Listen for visible rect changes. Listener is called immediately with current state. */
	onRectChange(listener: (rect: SurfaceRect | undefined) => void): () => void;
	/** Subscribe to pointer events that hit this surface's rect. */
	onPointer(
		listener: (event: PointerEvent) => void,
		options?: { wheel?: boolean; hover?: boolean },
	): () => void;
	/** Focus this surface and bring it to the visual front for keyboard dispatch. */
	focus(): void;
	/** Release focus to the previous target. */
	unfocus(): void;
	/** Check if this surface currently has focus. */
	isFocused(): boolean;
}

/**
 * Handle returned by showOverlay. Extends SurfaceHandle with overlay-specific
 * programmatic lifecycle methods.
 */
export interface OverlayHandle extends SurfaceHandle {
	/** Permanently remove the overlay (cannot be shown again). */
	hide(): void;
	/** Temporarily hide or show the overlay. */
	setHidden(hidden: boolean): void;
	/** Check if the overlay is temporarily hidden. */
	isHidden(): boolean;
}
```

- [ ] **Step 4: Update `index.ts` exports**

In `/Users/robert/dev/pi-mono/packages/tui/src/index.ts`, find the existing exports for `OverlayHandle` and `OverlayRect` and add `SurfaceHandle` and `SurfaceRect` alongside. The export line should look like:

```ts
export { /* ... existing exports ... */, type OverlayHandle, type OverlayRect, type SurfaceHandle, type SurfaceRect, /* ... */ } from "./tui.js";
```

(If the existing export is a single line, just add `SurfaceHandle` and `SurfaceRect` to its type list. If it's a multi-line `export {` ... `}`, add the two new types in the same shape as the existing entries. Keep alphabetic ordering only if the file is already sorted; otherwise group with the other surface-related types.)

- [ ] **Step 5: Run the new test and verify it passes**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/surface-handle.test.ts 2>&1 | tail -10
```

Expected: 2/2 pass.

- [ ] **Step 6: Run the v1 baseline test set to confirm no regression**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx \
    test/pointer-events.test.ts \
    test/mouse-mode.test.ts \
    test/overlay-pointer.test.ts \
    test/overlay-click-focus.test.ts \
    test/plugin-focus-esc.test.ts \
    test/plugin-focus-click-outside.test.ts \
    test/overlay-wheel.test.ts \
    2>&1 | tail -5
```

Expected: 28/28 pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/src/index.ts packages/tui/test/surface-handle.test.ts
git commit -m "feat(tui): extract SurfaceHandle abstraction from OverlayHandle"
```

---

## Chunk 2: Mouse-mode upgrade to `?1003h`

### Task 2: Change mouse-mode bytes from `?1002h` to `?1003h`

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Modify: `/Users/robert/dev/pi-mono/packages/tui/test/mouse-mode.test.ts`

The protocol-level change is one byte. `?1003h` is a strict superset of `?1002h` (reports all motion, including no-button-held). v1's mouse-mode tests assert the exact byte string and need updating.

- [ ] **Step 1: Update existing tests to expect `?1003h`/`?1003l`**

In `/Users/robert/dev/pi-mono/packages/tui/test/mouse-mode.test.ts`, replace every occurrence of `\x1b[?1002h` with `\x1b[?1003h` and every occurrence of `\x1b[?1002l` with `\x1b[?1003l`. Six string-literal updates total across the existing 6 test cases.

- [ ] **Step 2: Run the updated tests; they fail because the implementation still writes `?1002h`**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/mouse-mode.test.ts 2>&1 | tail -10
```

Expected: 6/6 fail with assertion errors about `?1003h`.

- [ ] **Step 3: Update `acquireMouseMode` to write `?1003h`/`?1003l`**

In `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`, find `acquireMouseMode()`. Replace `"\x1b[?1002h\x1b[?1006h"` with `"\x1b[?1003h\x1b[?1006h"`, and `"\x1b[?1002l\x1b[?1006l"` with `"\x1b[?1003l\x1b[?1006l"`. Also update the same `\x1b[?1002l\x1b[?1006l` write inside `stop()` if present.

- [ ] **Step 4: Run mouse-mode tests; they pass**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/mouse-mode.test.ts 2>&1 | tail -10
```

Expected: 6/6 pass.

- [ ] **Step 5: Run the v1 baseline test set to confirm no regression**

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
    2>&1 | tail -5
```

Expected: 30/30 pass (28 v1 + 2 SurfaceHandle).

- [ ] **Step 6: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/mouse-mode.test.ts
git commit -m "feat(tui): upgrade mouse-mode bytes to ?1003h (any-event tracking)"
```

---

## Chunk 3: Hover delivery filter

### Task 3: Add `hover` option to `onPointer`; filter no-button-held motion in dispatch

**Files:**
- Modify: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`
- Create: `/Users/robert/dev/pi-mono/packages/tui/test/overlay-hover.test.ts`

After Chunk 2, the terminal sends motion-without-button events as `pointermove` events with `buttons === 0`. v1's dispatch routes them to all subscribers because there's no hover filter yet. Chunk 3 adds the filter.

- [ ] **Step 1: Write failing tests**

Create `/Users/robert/dev/pi-mono/packages/tui/test/overlay-hover.test.ts`:

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

describe("Hover delivery filter", () => {
	it("hover-motion (no buttons held) does NOT reach a default-subscription pointer listener", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new FocusableOverlay(["X"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, {
				width: 1,
				height: 1,
				anchor: "top-left",
				nonCapturing: true,
			});
			await flush(tui, terminal);
			const events: PointerEvent[] = [];
			handle.onPointer((ev) => events.push(ev));

			// SGR motion-without-button: button code 35 (32 = motion, 3 = no button)
			tui.feedInput("\x1b[<35;1;1M");

			assert.strictEqual(events.length, 0);
		} finally {
			tui.stop();
		}
	});

	it("hover-motion DOES reach a hover-opt-in subscription", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new FocusableOverlay(["X"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, {
				width: 1,
				height: 1,
				anchor: "top-left",
				nonCapturing: true,
			});
			await flush(tui, terminal);
			const events: PointerEvent[] = [];
			handle.onPointer((ev) => events.push(ev), { hover: true });

			tui.feedInput("\x1b[<35;1;1M");

			assert.strictEqual(events.length, 1);
			assert.strictEqual(events[0]!.type, "pointermove");
			assert.strictEqual(events[0]!.buttons, 0);
		} finally {
			tui.stop();
		}
	});

	it("drag-motion (button held) reaches default subscriptions (it's not hover)", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const overlay = new FocusableOverlay(["X"]);
		tui.start();
		try {
			const handle = tui.showOverlay(overlay, {
				width: 1,
				height: 1,
				anchor: "top-left",
				nonCapturing: true,
			});
			await flush(tui, terminal);
			const events: PointerEvent[] = [];
			handle.onPointer((ev) => events.push(ev));

			// SGR motion-with-left-button: button code 32 (32 = motion, 0 = left)
			tui.feedInput("\x1b[<32;1;1M");

			assert.strictEqual(events.length, 1);
			assert.strictEqual(events[0]!.type, "pointermove");
			assert.strictEqual(events[0]!.buttons, 1);
		} finally {
			tui.stop();
		}
	});

	it("hover events fall through to a lower wheel-and-hover subscription if upper does not opt in", async () => {
		const terminal = new VirtualTerminal(80, 24);
		const tui = new TUI(terminal);
		tui.addChild(new EmptyContent());
		const lowerOverlay = new FocusableOverlay(["L"]);
		const upperOverlay = new FocusableOverlay(["U"]);
		tui.start();
		try {
			const lower = tui.showOverlay(lowerOverlay, {
				width: 1,
				height: 1,
				anchor: "top-left",
				nonCapturing: true,
			});
			const upper = tui.showOverlay(upperOverlay, {
				width: 1,
				height: 1,
				anchor: "top-left",
				nonCapturing: true,
			});
			await flush(tui, terminal);
			const lowerEvents: PointerEvent[] = [];
			const upperEvents: PointerEvent[] = [];
			lower.onPointer((ev) => lowerEvents.push(ev), { hover: true });
			upper.onPointer((ev) => upperEvents.push(ev)); // no hover

			tui.feedInput("\x1b[<35;1;1M");

			assert.strictEqual(upperEvents.length, 0, "upper has no hover-opt-in, must not receive");
			assert.strictEqual(lowerEvents.length, 1, "hover must fall through to lower hover-opt-in listener");
			assert.strictEqual(lowerEvents[0]!.type, "pointermove");
		} finally {
			tui.stop();
		}
	});
});
```

- [ ] **Step 2: Run the new tests; verify they fail**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/overlay-hover.test.ts 2>&1 | tail -15
```

Expected: at least the first and fourth tests fail (no hover filter yet). The second may also fail because `onPointer` doesn't accept the option yet (the call signature hasn't been extended for `hover`).

- [ ] **Step 3: Extend the `onPointer` signature in `OverlayHandle` and `SurfaceHandle`**

In `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts`, find the `SurfaceHandle.onPointer` declaration added in Chunk 1. The `options` already include `wheel?: boolean`; add `hover?: boolean`:

```ts
	onPointer(
		listener: (event: PointerEvent) => void,
		options?: { wheel?: boolean; hover?: boolean },
	): () => void;
```

- [ ] **Step 4: Add `hover` to the internal `PointerListenerEntry` type and capture it in the handle**

Find the `PointerListenerEntry` type. Add `hover: boolean`:

```ts
type PointerListenerEntry = {
	listener: (event: PointerEvent) => void;
	wheel: boolean;
	hover: boolean;
};
```

In the `onPointer` body inside `showOverlay`, where the entry is constructed, capture the new option:

```ts
				const ple: PointerListenerEntry = {
					listener,
					wheel: options?.wheel === true,
					hover: options?.hover === true,
				};
```

- [ ] **Step 5: Add the hover filter in `dispatchPointerEvent`**

Find the listener-delivery loop inside `dispatchPointerEvent` (the `for (const ple of entry.pointerListeners)` block). It already has the wheel filter:

```ts
			if (event.type === "wheel" && !ple.wheel) continue;
```

Add the hover filter immediately after:

```ts
			if (event.type === "pointermove" && event.buttons === 0 && !ple.hover) continue;
```

- [ ] **Step 6: Run the new tests; verify they pass**

```bash
cd /Users/robert/dev/pi-mono/packages/tui && node --test --import tsx test/overlay-hover.test.ts 2>&1 | tail -10
```

Expected: 4/4 pass.

- [ ] **Step 7: Run the v1 baseline + Chunk 1 + Chunk 2 tests to confirm no regression**

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

Expected: 34/34 pass.

- [ ] **Step 8: Commit**

```bash
cd /Users/robert/dev/pi-mono
git add packages/tui/src/tui.ts packages/tui/test/overlay-hover.test.ts
git commit -m "feat(tui): hover delivery requires explicit opt-in on onPointer"
```

---

## Chunk 4: Investigation — chat-rendering rect tracking

### Task 4: Read `interactive-mode.ts`'s chat render path; identify the cleanest hook for per-`CustomMessageComponent` rect tracking

**Files:**
- Read-only: `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts`
- Read-only: `/Users/robert/dev/pi-mono/packages/coding-agent/src/modes/interactive/components/custom-message.ts`
- Read-only: `/Users/robert/dev/pi-mono/packages/tui/src/tui.ts` (specifically the diff-render path and how `OverlayEntry.lastRect` is updated in `compositeOverlays`)
- Create: `/Users/robert/dev/katzensteg.cheshire/docs/superpowers/notes/2026-05-10-chat-rect-tracking.md`

This task produces no code changes. The deliverable is a written design note that the v2 follow-up plan will turn into implementation tasks.

- [ ] **Step 1: Read the chat-message render path**

Read `interactive-mode.ts`. Locate every place where `CustomMessageComponent` is created, rendered, mounted into a container, or replaced. Note line numbers and the parent container hierarchy. (`InteractiveMode` likely has a `chatContainer` or similar that holds the rendered messages.)

Read `custom-message.ts`. Note how `CustomMessageComponent` invokes the registered renderer (lazy on first `render`? on construction? per-render?), where `MessageRenderOptions` is constructed, and where the rendered `Component` is held.

- [ ] **Step 2: Read TUI's overlay rect tracking for comparison**

In `tui.ts`, locate `compositeOverlays`. This is where each visible overlay's rect is computed during render and `updateOverlayRect(entry, { row, col, rows, cols })` is called. The chat-message equivalent must track an analogous rect, but for components rendered as part of the normal scrollback flow rather than as overlay slots.

Note specifically: chat-message rects are *viewport positions* — they shift when the user scrolls. An overlay's rect is a layout decision per-render; an inline message's rect is a layout decision *plus* the current scroll state.

- [ ] **Step 3: Identify candidate hook points and write the design note**

Write `/Users/robert/dev/katzensteg.cheshire/docs/superpowers/notes/2026-05-10-chat-rect-tracking.md`:

```markdown
# Chat-rendering rect tracking — investigation notes

## Goal

For Surface Lab v2, identify the cleanest hook in pi-mono's interactive-mode chat
rendering path where per-`CustomMessageComponent` viewport rects can be tracked and
delivered to a `MessageHandle.onRectChange` listener.

## Context

(Brief recap of what `MessageHandle.getRect()` must return: visible portion of the
message's rendered lines in the current viewport, or undefined if fully scrolled
out. The v2 spec at docs/superpowers/specs/2026-05-10-surface-lab-v2-design.md is
the contract.)

## Findings

### How `CustomMessageComponent` is currently rendered

(File path + line numbers + a short prose explanation of the lifecycle: when the
component is constructed, when its `render(width)` is called, where its output
lines end up in the viewport, what triggers re-render on scroll/resize.)

### Where viewport positions are known

(File path + line numbers for the place(s) in `interactive-mode.ts` or its
collaborators where each rendered chat message's row range in the current viewport
is known. If the position is not directly tracked, identify the data structures
that *could* be made to compute it without restructuring.)

### Candidate hook points

For each candidate, give a one-paragraph description, files affected, complexity
estimate (small / medium / large), and trade-offs:

1. **Hook A: ...**
2. **Hook B: ...**
(at least two candidates; more if real)

### Recommendation

(Pick one candidate with a one-paragraph justification. The implementation plan
will be written against this recommendation.)

## Open questions

(Anything that came up during investigation that needs a user decision before the
implementation plan is written. If none, say so explicitly.)
```

Fill in each section with grounded findings — file paths, line numbers, prose. Do not leave placeholders.

- [ ] **Step 4: Surface findings to the user for review**

The investigation deliverable is a design decision with cost/benefit. The user must review and approve the recommended hook point before the v2 follow-up plan is written. Surface the note's key findings (recommendation + reasoning) in a chat message and pause for approval.

- [ ] **Step 5: Commit**

```bash
cd /Users/robert/dev/katzensteg.cheshire
git add docs/superpowers/notes/2026-05-10-chat-rect-tracking.md
git commit -m "docs: chat-rect-tracking investigation for surface-lab v2"
```

---

## After this plan

Once Chunk 4 is approved by the user, write the **v2 follow-up plan** covering:

- `MessageHandle` interface in `pi-tui` (extends `SurfaceHandle`, no additions).
- `MessageHandle` instantiation per `CustomMessageComponent`; rect tracking via the hook chosen in Chunk 4.
- `MessageRenderOptions.handle?` plumbing (alongside the existing `tui?` field).
- Inline pointer dispatch added to `dispatchPointerEvent` (overlays first, then inline).
- New release path: inline message fully scrolled out of view.
- Demo refactor: extract `SurfaceLabContent` shared component, add `/terminal-surface-demo inline` entry, wire cooperative focus-border indication.

That follow-up plan is written *after* Chunk 4 lands and the user approves the recommended hook point.

---

## Self-Review

**Spec coverage (this plan):**

- [x] `SurfaceHandle` as named interface → Chunk 1
- [x] `OverlayHandle` extends `SurfaceHandle` → Chunk 1
- [x] `OverlayRect` → `SurfaceRect` rename (with backwards-compatible alias) → Chunk 1
- [x] Mouse-mode upgrade to `?1003h` → Chunk 2
- [x] Hover delivery as per-listener filter → Chunk 3
- [x] Investigation deliverable for chat-rendering rect tracking → Chunk 4

**Spec coverage (deferred to follow-up plan):**
- [ ] `MessageHandle` interface
- [ ] `MessageHandle` per-`CustomMessageComponent` lifecycle
- [ ] `MessageRenderOptions.handle?`
- [ ] Inline pointer dispatch + new release path
- [ ] Demo refactor + inline entry + cooperative focus-border indication

These are explicitly tracked in the "After this plan" section.

**Placeholder scan:** No "TBD", "TODO", "implement later". Step 3 of Task 4 contains a markdown template with placeholder section names — that's the *file the engineer will fill in* during the investigation, not a placeholder in the plan itself. Each section in the template has explicit instructions.

**Type consistency:**

- `SurfaceHandle.onPointer` signature in Chunk 1 / Task 1 / Step 3 declares `options?: { wheel?: boolean; hover?: boolean }`. Chunk 3 / Task 3 / Step 3 extends this same signature. Consistent.
- `PointerListenerEntry` type in Chunk 3 / Task 3 / Step 4 adds `hover: boolean` to the existing `{ listener, wheel }` shape from v1. Consistent with the wheel pattern.
- `SurfaceRect` introduced in Chunk 1 with the field set `{row, col, rows, cols}`. Used unchanged in subsequent tests via the `getRect()` return type.

The v2 spec's `SurfaceRect` includes a `totalRows` field; the plan's interface definition in Chunk 1 / Task 1 / Step 3 omits it. This is a deliberate scope decision: `totalRows` is needed for inline messages (where the visible portion may be smaller than the rendered total) and will be added when `MessageHandle` lands in the follow-up plan. The overlay case never has `totalRows !== rows`, so the field is meaningless until inline. Mentioned here so the follow-up plan adds it without surprise.
