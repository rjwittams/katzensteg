# Chat-rendering rect tracking — investigation notes

## Goal

For Surface Lab v2, identify the cleanest hook in pi-mono's interactive-mode chat
rendering path where per-`CustomMessageComponent` viewport rects can be tracked
and delivered to a `MessageHandle.onRectChange` listener.

## Context

Spec: `docs/superpowers/specs/2026-05-10-surface-lab-v2-design.md`. The contract
is: `MessageHandle.getRect()` returns the visible portion of the rendered
message in the current viewport, or undefined if fully scrolled out;
`onRectChange` fires when the rect changes (scroll, resize, rebuild).

## Findings

### How `CustomMessageComponent` is currently rendered

**File:** `packages/coding-agent/src/modes/interactive/components/custom-message.ts`

`CustomMessageComponent` extends `Container` (from `packages/tui/src/tui.ts`, line 253).
It is constructed in `interactive-mode.ts` at line 3017 (inside `addMessageToChat`,
the `"custom"` role branch) and added directly to `this.chatContainer` at line 3024.
The `chatContainer` is itself a bare `Container` (constructed at line 366, added as a
direct child of the root `TUI` at line 639).

The renderer factory (the function the plugin passed to `pi.registerMessageRenderer`)
is invoked **eagerly at construction time** — in `rebuild()` at line 62 of
`custom-message.ts`. The call is:

```ts
const component = this.customRenderer(this.message, { expanded: this._expanded, tui: this.tui }, theme);
```

The returned `Component` is stored as `this.customComponent` and added as a child of
the `CustomMessageComponent` container. The factory is called again (i.e., a new
component is created) whenever `rebuild()` is triggered — which happens in the
constructor, on `setExpanded()` (line 39), and on `invalidate()` (line 46).

Rendering is via the normal TUI `render(width)` cascade. The root `TUI.doRender()`
(line 1224 in `tui.ts`) calls `this.render(width)` (inherited from `Container`), which
walks children recursively. `chatContainer.render(width)` collects lines from every
child in insertion order; each child's line count depends on its content and current
width. No component in this chain records or receives its own starting line offset.

The TUI then optionally composites overlays and writes the full line buffer to the
terminal. The "viewport" — i.e., which lines are visible — is determined by how many
total lines there are relative to `terminal.rows`: the visible portion is always the
bottom `height` lines of the buffer (see `doRender` line 1206 for the
`viewportTop = Math.max(0, lines.length - height)` computation). There is no
user-controlled scroll; the chat grows downward and the bottom is always visible.

### Where per-message viewport positions are known

**File:** `packages/tui/src/tui.ts`

Currently, no code records each component's row range during render. The
`Container.render()` (line 277) concatenates child line arrays without annotating
offsets. The `TUI.doRender()` only knows `newLines.length` as a whole after the
render pass.

The position of a given `CustomMessageComponent`'s output in the full line buffer
is computable as the sum of line counts of all `chatContainer` children rendered
before it, plus the line count of any `TUI` children rendered before `chatContainer`
(i.e., `headerContainer`). However, nothing in the current codebase captures this
as a per-child value.

The overlay subsystem (`compositeOverlays`, line 1009; `updateOverlayRect`, line 599)
provides the model we want: after calling `component.render(width)` for each overlay,
it records the resulting row/col rect and calls `updateOverlayRect`, which diffs against
the previous rect and notifies listeners (line 605). The inline message path has no
equivalent.

The mapping from buffer line index to screen row is:
`screen_row = buffer_line - viewportTop`, where `viewportTop = max(0, totalLines - termHeight)`.
This is stable within a single render pass and changes whenever content is added or
the terminal is resized.

### Candidate hook points

#### Candidate A: Tracking render with a thin wrapper around `Container.render`

Introduce a `TrackingContainer` subclass (or a wrapper render function on the existing
`Container` in `tui.ts`) that, after calling each child's `render(width)`, records the
child's start and end line index in a side table. At the end of `TUI.doRender()`, after
`this.render(width)` returns but before `compositeOverlays`, walk the side table for any
registered `CustomMessageComponent` instances: compute their screen rect using
`viewportTop = max(0, newLines.length - height)`, and call per-component rect listeners
if the rect changed (same diffing logic as `updateOverlayRect`).

Files affected:
- `packages/tui/src/tui.ts` — add `TrackingContainer` or augment `Container.render`;
  extend `TUI.doRender` with a post-render rect-notify pass.
- `packages/coding-agent/src/modes/interactive/components/custom-message.ts` — add
  `MessageHandle` plumbing (rect listeners, pointer listeners, focus state).
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts` — register each new
  `CustomMessageComponent` with the tracking system when adding it to `chatContainer`.

Complexity: **medium**. The tracking mechanism requires a new concept in `tui.ts`
(per-child line-range recording), but it is self-contained. The render-loop change is
minimal: one post-render pass over a small map. The `TrackingContainer` approach keeps
the change isolated to a subclass rather than modifying `Container` directly.

Trade-offs: This is precise — it computes rects from the same line buffer that was
actually rendered. It handles resize naturally (each render recomputes the rect). The
weakness is that it requires `tui.ts` to gain awareness of a concept (per-child rect
tracking) that does not currently exist there, and the registration step in
`interactive-mode.ts` creates a coupling between the chat container and the TUI-level
tracking map.

#### Candidate B: Post-render line-scan in `interactive-mode.ts` using `tui.afterNextRender`

After each render, use `tui.afterNextRender` to schedule a scan that reconstructs
each `CustomMessageComponent`'s line range by calling `chatContainer`-scoped render
logic manually — essentially calling `child.render(width)` on each preceding sibling
of a custom-message child to count cumulative lines, then computing the viewport rect.

Files affected:
- `packages/coding-agent/src/modes/interactive/components/custom-message.ts` — add
  rect/listener state.
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts` — add a scan loop
  that fires via `afterNextRender` after any chat mutation or resize.

Complexity: **medium-to-large**. Re-rendering all chat children outside of the TUI's
normal render pass is expensive: it double-renders all components on every update.
Components with side effects in `render()` (e.g., the kitty-placeholder demo which
schedules `afterNextRender` callbacks from inside `render()`) would be called a second
time out of context. This approach is fragile and wasteful.

Trade-offs: It avoids touching `tui.ts` entirely, keeping the change local to
`coding-agent`. However, it breaks the single-render-per-cycle discipline and is
unreliable for components whose render is not pure.

#### Candidate C: Instrument `chatContainer.render` to emit per-child offsets

Override `render(width)` on the `chatContainer` instance (or on a `ChatContainer`
subclass introduced in `interactive-mode.ts`) to record each child's start line offset
as a side effect of the normal render pass. After the full TUI render (via
`tui.afterNextRender`), convert the recorded offsets to screen rects using the TUI's
current `previousViewportTop` (exposed or computable as `max(0, totalLines - height)`),
and notify any registered rect listeners on `CustomMessageComponent` instances.

Files affected:
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts` — replace
  `new Container()` at line 366 with a `ChatContainer` subclass that records per-child
  offsets during render; add an `afterNextRender` callback that walks the offset table
  and notifies `CustomMessageComponent` rect listeners.
- `packages/coding-agent/src/modes/interactive/components/custom-message.ts` — add
  rect/listener state and a method the chat container calls to deliver updates.
- `packages/tui/src/tui.ts` — expose `previousViewportTop` (currently private) or
  compute viewportTop from `previousLines.length` and `terminal.rows` (both already
  public).

Complexity: **small-to-medium**. The subclass change is local to `interactive-mode.ts`;
`tui.ts` needs at most a one-line accessor. The render override is straightforward:
iterate children, call `child.render(width)`, track cumulative offset. No new concept
is introduced into `tui.ts` itself. The `afterNextRender` callback pattern is already
established (used by the kitty-placeholder demo to sequence terminal writes after render).

Trade-offs: This is the most surgically narrow change. It does not require `tui.ts`
to know about message handles. The `ChatContainer` owns the offset bookkeeping for
its own children, which is the right layer. The only coupling to `tui.ts` is reading
`previousViewportTop` (or computing it from public fields), which is a stable, low-churn
value. The `afterNextRender` delivery ensures rects are notified after the terminal write,
so listeners that call `tui.writeRaw` (e.g., for kitty graphics) will sequence correctly.

## Recommendation

**Candidate C — `ChatContainer` subclass with `afterNextRender` rect delivery** is
the recommended approach.

It confines all new machinery to `interactive-mode.ts` and `custom-message.ts`:
the two files that already own the chat rendering pipeline. `tui.ts` requires at most
a one-line accessor for `previousViewportTop`; the library's own overlay-rect model
(`OverlayEntry.lastRect`, `updateOverlayRect`) is reused as the conceptual template
but not modified. Candidate A achieves similar precision but bakes a new tracking
concept into `tui.ts` itself, which is the wrong layer of ownership: the TUI library
should not need to know about `CustomMessageComponent` or message handles. Candidate B
is rejected outright because double-rendering is both expensive and unsafe for
components with render-time side effects (the kitty demo is an existing example of this).
Candidate C keeps the boundary clean, the change small, and the delivery pathway
(`afterNextRender`) is already proven in production use.

## Open questions

None — the recommended hook is implementable without further questions. The only
practical detail to confirm during implementation is whether to expose
`previousViewportTop` via a new `getViewportTop(): number` accessor on `TUI`, or to
compute it inline as `Math.max(0, tui.previousLines.length - tui.terminal.rows)`. Both
are equivalent; the accessor is cleaner. Neither requires a decision before the
implementation plan can be written.
