# Surface Lab and Pi Pointer Events Design

## Goal

Drive pointer events and inline focus into Pi (`pi-mono`) as a generally useful capability, with a Pi-contained test extension (`surface-lab`) as the first consumer that demonstrates "a plugin can use events in a cares-about-pixels way."

The Pi changes are the deliverable. The lab is the forcing function: it cannot work without those changes, so its existence pressures them into shape and verifies them end-to-end.

## Why this exists

Previous design iterations treated Pi-side changes as out-of-scope and tried to build the lab as a self-contained extension. That inverted the goal: the lab became a workaround rather than a consumer of new Pi capability.

The KS-side bytes-generation path already works. The current `katzensteg-panel` extension is a thin pipe: Pi opens a non-capturing overlay, Pi forwards `OverlayHandle.onRectChange` to a `katzensteg --embed-jsonl` child, KS sends back pre-encoded terminal byte chunks (`deletes` / `uploads` / `placements` / `after`), Pi `writeRaw`s them. KS owns the Kitty protocol entirely.

The window-manager host (`src/katzensteg/wm_host.zig`) already does the equivalent of input redirection in Zig: `parseSgrMouseAt`, hit-testing via `mouseHitTest` / `rectContainsCell`, focused-session forwarding via `forwardInputToSession`. In WM mode this works because the host owns `/dev/tty`. In Pi mode, Pi owns the terminal, and currently does not expose any equivalent capability to extensions. That asymmetry is the gap this work closes.

## End-state context

The eventual target is heterogeneous live content embedded in chat: the agent emits content-type-tagged blocks (mermaid, pygame, react, zig+opengl, etc.), the plugin layer routes by content type to a renderer (KS for SDL apps, luchs for HTML, others later), and placement is heterogeneous — inline in scrollback, promoted to floating panel, or queued in an attention stack. For any of that to be interactive, Pi has to deliver structured input to plugins. That is what this work enables. The end-state work is not in scope for this spec.

## Pi-side changes

### 1. Structured pointer events in TUI

`stdin-buffer.ts` already half-parses SGR mouse so events arrive as one chunk. Promote the parsing the rest of the way: produce typed events with cell coordinates, button, modifier bits, and event type (`pointerdown` / `pointermove` / `pointerup` / `wheel`). Raw `addInputListener` keeps working; structured events are a new delivery path.

```ts
interface PointerEvent {
  type: "pointerdown" | "pointermove" | "pointerup" | "wheel";
  row: number;       // 0-based terminal row
  col: number;       // 0-based terminal column
  button: number;    // 0=left, 1=middle, 2=right, 3=none (move/wheel)
  buttons: number;   // bitmask of currently-pressed buttons
  deltaX: number;    // wheel x (0 if not wheel)
  deltaY: number;    // wheel y (0 if not wheel)
  shiftKey: boolean;
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
}
```

### 2. Mouse mode lifecycle owned by TUI

TUI emits the SGR mouse mode bytes (`?1002h + ?1006h` to enable, `?1002l + ?1006l` to disable). Refcounted on the active set of pointer-listener subscriptions: first subscription enables; last unsubscription disables. Cleared on TUI shutdown.

### 3. Per-handle pointer subscription on `OverlayHandle`

```ts
interface OverlayHandle {
  // existing: hide, setHidden, isHidden, focus, unfocus, isFocused, getRect, onRectChange
  onPointer(listener: (event: PointerEvent) => void): () => void;
}
```

The handle owns its subscription. TUI hit-tests against the overlay's current rect before delivery; pointer events outside the rect are not delivered through that handle. Listeners returned from `onPointer` auto-release when the overlay disposes.

### 4. `MessageHandle` for inline message-renderer components

`registerMessageRenderer` components currently get a `Component` API but no rect awareness or focus. Introduce a handle with the same shape as `OverlayHandle`:

```ts
interface MessageHandle {
  getRect(): MessageRect | undefined;     // visible portion only
  onRectChange(listener: (rect: MessageRect | undefined) => void): () => void;
  onPointer(listener: (event: PointerEvent) => void): () => void;
  focus(): void;
  unfocus(): void;
  isFocused(): boolean;
}

interface MessageRect {
  row: number;       // 0-based viewport row of first visible line
  col: number;       // 0-based viewport column of left edge
  rows: number;      // visible row count (may be < component's full row count if partially scrolled)
  cols: number;      // visible column count
  totalRows: number; // total row count of the rendered component (for plugins that need it)
}
```

Delivery to extensions: `registerMessageRenderer` callback signature gains a `MessageHandle` parameter, available alongside `tui` and `theme`.

### 5. Click-to-focus across overlay and inline components

Pi's existing `focusedComponent` model handles overlay components today. Extend it so an inline component can also be the focused component. On pointer down inside a component's rect, that component becomes the focused component. The focusing click is delivered as a pointer event to the now-focused component (not swallowed). Focus is keyboard-only — pointer routing is independent.

Programmatic `focus()` from plugin logic is *not* permitted in this pass. Focus changes are user-driven via click; plugin code can call `unfocus()` to release.

### 6. Pi-enforced focus release paths

Pi guarantees the user is never locked into a plugin. Four release paths, all enforced by TUI:

- Esc returns focus to the composer (intercepted before any focused plugin sees it).
- Click anywhere outside a focusable plugin component returns focus.
- Plugin component dismount / overlay close / inline message scrolled fully out of view auto-releases focus.
- Session shutdown auto-releases focus.

### 7. Wheel-event routing

Default `onPointer` subscriptions do not receive wheel events. Plugins opt in via `{ wheel: true }` if they want wheel events. Wheel events that no listener consumed fall through the dispatch loop.

**Known limitation (manual-testing finding):** The "preserves normal scrollback scroll" framing in earlier drafts of this spec was wrong. SGR mouse capture (`?1002h + ?1006h`) is essentially all-or-nothing — once any pointer subscription enables it, the terminal stops doing native wheel→scrollback because wheel comes through as captured mouse events. v1 silently drops wheel events that no plugin opted in for; the terminal will not handle them either. To recover scroll behavior while plugins want clicks, a future revision can either (a) translate fall-through wheel into a Pi-side scrollback action when Pi has a scrollable buffer concept, or (b) use `?1000h` (X11 button-only) when no listener wants motion or wheel and rely on terminal-specific behavior leaving native wheel alone — non-portable. Tracking as v2 follow-up.

## Out of scope this pass

- Programmatic `focus()` from plugin code.
- Pi-rendered focus indicators (border, dim, badge). Plugins may render their own indication for now (cooperative). Host-enforced indication can land later without changing the focus model.
- Pixel-coordinate mouse events. Cells only.
- Keyboard input forwarding from non-focused components.
- Forwarding pointer events from a plugin to KS over JSONL. That is a `katzensteg-panel`-side concern, downstream of this work.
- Multi-pointer / touch input.
- **Hover motion** (mouse moving with no buttons held). v1 acquires `?1002h` (motion-while-button-held only), so drag works but hover does not. A v2 follow-up should add an `onPointer` option like `{ hover: true }` that escalates the acquired mode to `?1003h` for any-event tracking. The TUI must then refcount mode-level (`?1002` vs `?1003`) and downgrade when no listener wants hover anymore.
- **Pi-side image-cache survival across full redraws.** Pi's `fullRender(true)` currently runs `deleteKittyImages(this.previousKittyImageIds)` (correctly, deleting only Pi-tracked image ids) and then emits `\x1b[2J\x1b[H\x1b[3J`. The `2J` is redundant for Pi-owned ids (Pi already deleted them) and destructive for everything else: per the Kitty graphics protocol §"Interaction with other terminal actions", `2J` clears all *images* (the data resources, not just placements; Kitty's `screen.c:screen_erase_in_display` → `grman_clear` → `filter_refs(..., free_images=true, ...)`). v1 worked around this by having `terminal-surface-demo.ts` re-transmit the image bytes on every draw. v2 should replace `2J` in Pi's full-redraw path with per-line text clears (`\x1b[2K` per cursor-positioned row) so extension-managed image data survives Pi-internal redraws, and the always-re-upload contortion in the demo can go away. Compliance characterisation lives at `kitty-image-tests/smoke screen-clear-cache`.
- **Id-range allocation for plugins.** Plugins (and KS via a plugin) currently invent their own image-id and placement-id values, hoping no other plugin / Pi-internal renderer collides. v2 should let plugins request reserved id ranges from Pi at registration, and let Pi enforce non-overlap and reserve its own internal range. With ranges in place, Pi can do precise deletion of its own ids and never needs the sledgehammer `2J` clear. Models the existing `wm_host.zig` attach protocol (`id_ranges: { image: [[lo, hi]], placement: [[lo, hi]] }`).

## Test extension: `terminal-surface-demo`

Lives in-tree at `pi-mono/packages/coding-agent/examples/extensions/terminal-surface-demo.ts`. The file already exists and currently demonstrates a bordered overlay with a Kitty image inside it; v1 rewrites it to use the new `OverlayHandle.onPointer` + click-to-focus instead of the existing manual SGR parsing + manual mouse-mode bytes (the WIP checkpointed in commit `912374fa`).

```text
/terminal-surface-demo
```

The rewrite:

- Keeps the existing bordered overlay + inner image rect + Kitty image rendering.
- Subscribes to `handle.onPointer(...)` instead of parsing SGR in the extension.
- On `pointerdown` inside the inner image rect: places a marker at that cell, computes the pixel coordinate using the declared image-pixel geometry, and shows it as a status line. Click-to-focus comes for free from the new TUI path.
- While focused: arrow keys move the marker by one cell. Esc is host-enforced and never reaches the demo; focus returns to the composer.
- Drops `ENABLE_SGR_MOUSE` / `DISABLE_SGR_MOUSE` constants, the inline `parseSgrMouse` helper, and the `handleTerminalInput` workaround. Mouse mode is owned by TUI.

The "cares about pixels" demonstration is the cell→pixel mapping inside the plugin: Pi delivers a cell coordinate, the plugin owns its surface geometry, the plugin computes the pixel coordinate. The image rendering is unchanged — it's already there and exercises the existing `writeRaw` + `afterNextRender` path.

The inline variant of the demo is deferred to v2 along with `MessageHandle`.

## Decisions taken in brainstorming

| Decision | Choice |
|---|---|
| Pointer subscription shape | Per-handle (`onPointer` on `OverlayHandle` and `MessageHandle`) |
| Programmatic focus | Not permitted in first pass; click-only |
| Focusing click forwarded | Yes — same click delivers as pointer event to now-focused component |
| Wheel routing | Pi by default; per-subscription opt-in for plugins |
| Partial scroll rect | Visible portion only; full scroll-out → no rect, focus releases |
| Focus indication | Plugin-cooperative for now; host-enforced deferred |
| KS window-close semantics for scroll-out | Deferred (real-KS concern, not Pi) |

## Repos and branches

- Pi changes: `~/dev/pi-mono` on main (or current default branch). `packages/tui` for parsing, mouse mode, focus model. `packages/coding-agent` for extension API surface (per-handle hooks, `MessageHandle`).
- Lab extension: `~/dev/katzensteg.cheshire` on the current working branch (`cheshire`). New file in `tools/pi-extension/extensions/`.

The Pi changes ship first; the lab can land in the same branch state once the Pi changes are published locally and the extension can `npm link` to them.

## Verification

- Pi-side unit tests for the SGR parser, mouse mode refcount, and focus release rules. Existing TUI tests (e.g. `overlay-non-capturing.test.ts`) are the right precedent.
- Manual smoke checklist exercised by `surface-lab` covering both inline and floating paths, all four release mechanisms, click-forwarding, and wheel-default behavior.
