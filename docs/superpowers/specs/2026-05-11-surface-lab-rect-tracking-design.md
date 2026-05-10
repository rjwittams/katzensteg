# Surface Lab Rect Tracking Design

## Goal

Move inline-message rect tracking from a reconstructed sum-of-offsets in `interactive-mode.ts` into the TUI itself, so `MessageHandle.getRect()` / `onRectChange()` are authoritative by construction the same way `OverlayHandle` is today.

## Background

The v2 design introduced inline `MessageHandle` and exposed `getRect()` / `onRectChange()`. The current implementation populates the rect via `deliverInlineMessageRects` in `interactive-mode.ts`, which reconstructs each `CustomMessageComponent`'s screen rect by summing three levels of `Container.getChildOffset()`: chatContainer → `CustomMessageComponent` → inner customComponent. Two problems with this:

1. **Fragile.** Any new sibling in the root TUI's child list, or any wrapper layer added to the chat path, silently breaks the math. There's no failure signal — the rect just drifts.
2. **Wrong layer.** The buffer-to-screen mapping (`screen row = bufferTop − viewportTop`) is baked into the consumer's call site. Pi's actual rendering owns that mapping; consumers should query it, not redo it.

The pattern we want is the one `OverlayHandle` already uses: TUI computes rect during render, stores it on the entry, fires listeners on change. Consumers read or subscribe. They never reconstruct.

## Scope

1. **`TUI.trackComponent(component, listener)`** — public API for handle implementations to register a component for rect tracking. Returns an unregister thunk.
2. **`Container.forEachChild(visitor)`** — encapsulates child iteration so the new tracking walk doesn't reach into Container's fields.
3. **A single per-frame walk** from root TUI through Containers, computing each tracked component's absolute buffer offset by accumulating each Container's recorded `getChildOffset`. O(N) per frame, where N = total component count in the tree.
4. **`afterNextRender` frame timing** for rect-change listener fires, applied uniformly to both `MessageHandle` and `OverlayHandle`. Replaces overlay's current synchronous-inside-`compositeOverlays` timing.
5. **Removal of `deliverInlineMessageRects`** and related call-site machinery from `interactive-mode.ts`.

## Out of scope

- The composer push-up / shrink bug in Pi's differential render. Separate Pi TUI issue; filed upstream. This work explicitly chooses parity with text rendering — whatever buffer-to-screen mapping the TUI applies to text, the same mapping applies to rect tracking. If text drifts, image drifts identically.
- The `SurfaceHandle` / `OverlayHandle` / `MessageHandle` API shape — already settled in `2026-05-10-surface-lab-v2-design.md`.
- Making `Container.children` and `Container.childOffsets` private. Encapsulation in this work is by adding new methods, not by removing field access. Existing reads-from-fields elsewhere are unchanged.
- Tracking for components rendered "inside" a non-Container (e.g., the editor's autocomplete list, which is appended directly into the editor's `render()` output). Such components are leaves from the tracking walk's perspective. If a future need arises, that component would extend `Container`.

## API surface

```ts
// On Container
forEachChild(
  visitor: (child: Component, startLine: number, lineCount: number) => void,
): void;

// On TUI
trackComponent(
  component: Component,
  listener: (rect: SurfaceRect | undefined) => void,
): () => void;  // returns unregister
```

Internal TUI state:

```ts
private trackedComponents: Map<Component, { listener; lastRect: SurfaceRect | undefined }>;
```

`Container.forEachChild` iterates `this.children` and calls the visitor with each child's `{startLine, lineCount}` from the most recent render. Children without recorded offsets (not rendered in the most recent pass) are skipped.

## Behavior

### Tracking lifecycle

- One `MessageHandle` per `CustomMessageComponent` instance. `MessageHandleImpl`'s constructor calls `tui.trackComponent(this.customComponent, this.deliverRect)`. The returned unregister thunk runs on handle release (component dismount, session shutdown).
- Plugin code never calls `trackComponent`. Plugins consume via `MessageHandle.onRectChange(listener)` and `MessageHandle.getRect()`, identical to `OverlayHandle`.

### Rect computation walk

At end of `doRender`, after Containers have populated their `childOffsets` via the render pass but before `afterNextRender` callbacks drain:

```ts
const walk = (container: Container, abs: number) => {
  container.forEachChild((child, startLine, lineCount) => {
    const childAbs = abs + startLine;
    if (this.trackedComponents.has(child)) {
      this.deliverRect(child, childAbs, lineCount);
    }
    if (child instanceof Container) walk(child, childAbs);
  });
};
walk(this, 0);
```

For each tracked component visited, `deliverRect` computes its screen rect:

```ts
const viewportTop = this.viewportTop;          // existing getter
const termRows = this.terminal.rows;
const top = bufferOffset - viewportTop;
const bottom = top + lineCount;
const visTop = Math.max(0, top);
const visBottom = Math.min(termRows, bottom);
if (visBottom <= visTop) return undefined;     // fully scrolled out
return {
  row: visTop,
  col: 0,
  rows: visBottom - visTop,
  cols: this.terminal.columns,
  totalRows: lineCount,
};
```

For tracked components **not** visited by the walk (their component is not in the tree, e.g., dismounted), the rect is delivered as `undefined`. Implementation: before the walk, mark all tracked entries as "not yet visited"; during walk, mark visited; after walk, deliver `undefined` to any unvisited entries.

The diff between the new rect and the entry's `lastRect` is field-by-field on `row`, `col`, `rows`, `cols`, `totalRows`. `undefined ↔ undefined` is no change. On change, the entry's `lastRect` is updated and the listener fire is queued via `afterNextRender`.

### Listener semantics

- **Diff:** field-by-field equality. No change → no fire.
- **Initial delivery:** synchronous inside `MessageHandle.onRectChange(listener)` — listener is called immediately with the handle's current `lastRect` (possibly `undefined`), then added to the subscriber set. Mirrors `OverlayHandle.onRectChange` at `packages/tui/src/tui.ts:579-585`.
- **Frame timing:** rect-change listener fires (both `MessageHandle` and `OverlayHandle`) are queued via `afterNextRender`, not invoked synchronously during render. Plugins that `writeRaw` from inside a rect listener (the common case for image-placement handlers) can do so directly without their own `afterNextRender` deferral.

### Container changes

`Container.forEachChild(visitor)` is the only new method. Existing `children` and `childOffsets` fields stay as-is. New code (the TUI walk) uses `forEachChild` exclusively; existing field-access patterns elsewhere in the codebase are not part of this rework.

## Migration

Removed from `packages/coding-agent/src/modes/interactive/interactive-mode.ts`:

- `deliverInlineMessageRects` function.
- `scheduleInlineRectDelivery` and the self-rearming `afterNextRender` chain that drives it.
- Direct `Container.getChildOffset` call sites used for rect reconstruction.

Modified in `packages/coding-agent/src/modes/interactive/components/custom-message.ts`:

- `MessageHandleImpl` constructor calls `tui.trackComponent(this.customComponent, ...)` and stores the unregister thunk.
- Handle release runs the unregister thunk.

Modified in `packages/tui/src/tui.ts`:

- `OverlayHandle.onRectChange` listener fires (currently inside `updateOverlayRect`, called synchronously from `compositeOverlays`) move to `afterNextRender` queuing.
- `TUI.trackComponent` added.
- `Container.forEachChild` added.
- `doRender` gains a tracking-walk step after Container render returns but before `afterNextRender` callbacks drain.

## Verification

### Unit tests

- `Container.forEachChild`: visits each child once with the recorded `startLine` and `lineCount`; skips children not rendered in the most recent pass; no-op on empty children.
- `TUI.trackComponent`: initial subscribe with no prior render returns `undefined` rect on first listener call; subsequent render delivers the computed rect; second render with same layout does not fire; render with changed layout fires; component dismount fires `undefined`; unregister stops firing.
- `OverlayHandle.onRectChange` tests updated to expect deferred (afterNextRender) firing instead of synchronous. Any test asserting synchronous timing of overlay rect listeners updated.

### Manual smoke

- v2 manual checklist (focus-on-click, drag, focused-border, scroll-out releases focus, terminal resize) still passes for both floating and inline placements of `terminal-surface-demo`.
- Inline image-placement plugin renders at correct cell positions across scroll, resize, and chat-message addition. Parity check: with this work alone, the composer push-up / shrink-bug symptom is unchanged (image drifts identically to text, not in addition to text).
- Floating `terminal-surface-demo` continues to track terminal resize via `OverlayHandle.onRectChange` (now deferred).

### Overlay-consumer audit

Before merging, grep pi-mono for `onRectChange` consumers and verify none depend on synchronous firing of the listener. The known in-repo consumer (`tools/pi-extension/extensions/katzensteg-panel.ts`) already defers its own logic via `afterNextRender`, so the timing change is a no-op for it.

## Decisions taken in brainstorming

| Decision | Choice |
|---|---|
| Tracking unit | Inner `customComponent`, not `CustomMessageComponent` wrapper |
| Registration | Implicit via `MessageHandle` lifecycle; plugins don't call `trackComponent` |
| Container iteration API | `forEachChild(visitor)` — generic iteration, not targeted query |
| Walk granularity | Single recursive walk per frame; O(N) where N = component count |
| Container detection | `instanceof Container` — no separate `RectHost` interface |
| Buffer-to-screen mapping | Same as TUI uses for text; no corrections for shrink-bug parity |
| Diff granularity | Field-by-field equality |
| Initial delivery | Synchronous inside `onRectChange`, mirror overlay |
| Frame timing | `afterNextRender` for both `MessageHandle` and `OverlayHandle` |
| `cols` of inline rect | `terminal.columns` — line-oriented hit-test, unchanged from v2 |

## Repos and branches

- All changes in `~/dev/pi-mono`. `packages/tui` for `Container.forEachChild`, `TUI.trackComponent`, the tracking walk, and overlay rect-listener deferral. `packages/coding-agent` for `MessageHandleImpl` registration and `interactive-mode.ts` cleanup.
- Continues on `katzensteg-terminal-surface` branch.
