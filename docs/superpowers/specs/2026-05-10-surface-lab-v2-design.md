# Surface Lab v2 Design: Inline `MessageHandle` and Hover

## Goal

Extend Pi's plugin event surface so that an inline-rendered chat message can be a first-class focusable surface — receive structured pointer events, participate in click-to-focus, surface its viewport rect — by analogy with the existing floating `OverlayHandle`. Pull out the shared abstraction (`SurfaceHandle`) so the same plugin content class can run unchanged in either placement.

The motivating use case is making *minimal luchs interaction* viable inside Pi's chat: an HTML fragment rendered by KS as terminal-graphics frames, embedded inline as a chat message, that responds to clicks and hover with proper DOM-event semantics on the luchs side. v2 builds the Pi-side plumbing that the eventual KS plugin update will consume.

## Scope

1. **`SurfaceHandle`** — explicit shared interface for all plugin-facing surface APIs. `OverlayHandle` extends it; the new `MessageHandle` extends it without additions.
2. **`MessageHandle`** — per-`CustomMessageComponent` handle delivered to plugins via `MessageRenderOptions.handle`. Same focus/click/Esc/release semantics as `OverlayHandle`.
3. **Hover motion via `?1003h`** — Pi's mouse-mode acquire upgrades from `?1002h` to `?1003h` (a strict superset). Hover delivery is a per-listener opt-in, parallel to the existing `wheel` filter — default subscriptions don't see no-button-held motion; `{ hover: true }` subscriptions do.
4. **Cooperative focus indication in the demo** — `terminal-surface-demo` renders a different border colour when `focused === true`. This is the v2 demo's "the user can tell where keys are going" demonstration. Host-enforced indication remains deferred.
5. **Single shared demo component**, exercised in both placements — one component class owns marker, cell→pixel mapping, drag handling, focus rendering. Takes a `SurfaceHandle` parameter; doesn't care which subtype it has. Two entry points (`/terminal-surface-demo`, `/terminal-surface-demo inline`) wire the same content into either an overlay or an inline chat message. The original "surface lab" framing: one piece of content, two placements, comparable.

## Out of scope

These items remain deferred from v1 and are not addressed by v2. They are tracked but not on the critical path for inline-luchs interaction:

- Programmatic `focus()` from plugin code. v2 keeps the click-only-focus rule.
- Pi-rendered (host-enforced) focus indication. v2 demo is cooperative.
- Wheel-to-Pi-scrollback fall-through. Mouse-mode capture is all-or-nothing per protocol; native terminal scroll is unrecoverable while plugins want clicks. The KS plugin can opt in to wheel events when its surface is focused, which is enough for inline luchs page scroll.
- Pi removing `\x1b[2J` from `fullRender(true)` to preserve extension-managed image data. v1 demo's defensive re-upload remains the workaround.
- Id-range allocation API for plugins (the `wm_host.zig`-style attach protocol).
- Reshaping `OverlayHandle` to split out container concerns (sidebar / attention stack). v2 leaves `OverlayHandle` as-is because v2's work doesn't depend on changing it; the surface-vs-container split lands when there's container work that needs it.

## API surface

```ts
interface SurfaceRect {
  row: number;       // 0-based viewport row of the surface's first visible line
  col: number;       // 0-based viewport column of the left edge
  rows: number;      // visible row count (may be < total when partially scrolled)
  cols: number;      // visible column count
  totalRows: number; // total rendered row count of the surface
}

interface SurfaceHandle {
  getRect(): SurfaceRect | undefined;
  onRectChange(listener: (rect: SurfaceRect | undefined) => void): () => void;
  onPointer(
    listener: (event: PointerEvent) => void,
    options?: { wheel?: boolean; hover?: boolean }
  ): () => void;
  focus(): void;
  unfocus(): void;
  isFocused(): boolean;
}

interface OverlayHandle extends SurfaceHandle {
  hide(): void;
  setHidden(hidden: boolean): void;
  isHidden(): boolean;
}

interface MessageHandle extends SurfaceHandle {
  // No additions in v2. Inline message lifecycle is tied to its CustomMessageComponent.
}
```

Both subtypes export from `packages/tui/src/index.ts`; `MessageRenderOptions.handle?: MessageHandle` follows the WIP pattern that already threads `tui` through the same options object.

The `OverlayRect` and `MessageRect` types collapse into one `SurfaceRect`. `OverlayRect` becomes a deprecated alias if anything outside `packages/tui` still imports it; otherwise just delete the alias.

## Mouse-mode change

`acquireMouseMode()` writes `\x1b[?1003h\x1b[?1006h` (was `\x1b[?1002h\x1b[?1006h`). `?1003h` reports all motion, including no-button-held; `?1002h` reported only motion-while-button-held; the former is a strict superset of the latter at the protocol level.

Hover delivery is a per-subscription filter, not a mode-level distinction. Each `pointerListeners` entry already carries `{ wheel: boolean }`; v2 adds `{ hover: boolean }` to the same entry shape. In `dispatchPointerEvent`, before invoking each listener:

- if `event.type === "wheel"` and `!entry.wheel` → skip
- if `event.type === "pointermove"` and `event.buttons === 0` (no-button motion = hover) and `!entry.hover` → skip

If no listener consumes the event after both filters, the existing fall-through behaviour (continue to next overlay) is preserved.

This means v1's refcount in `acquireMouseMode` does not need any "mode level" tracking. Subscription count == on/off. The byte string is just a constant.

## `MessageHandle` lifecycle

- One handle per `CustomMessageComponent` instance.
- Created when Pi instantiates the component for a chat message; disposed when that component dismounts.
- Threaded through `MessageRenderOptions.handle` alongside `MessageRenderOptions.tui`.
- Plugin's `pi.registerMessageRenderer(type, factory)` factory subscribes inside its body via `options.handle?.onPointer(...)` etc. Subscriptions live for the component's lifetime.
- If the same chat message is re-rendered (e.g. compaction rebuild creates a new `CustomMessageComponent` for it), the old handle disposes and a new one is created. The factory runs again on the new component and re-subscribes.
- The `?` (optional) on `handle` reflects environment dependence: in print/RPC modes there is no rendered TUI and no handle. Plugins must guard.

## Z-order at hit-test

Floating overlays are conceptually on top of inline content. `dispatchPointerEvent` iterates overlays first (top-down by `focusOrder`), then inline messages. First match wins.

Inline messages don't compete with each other for overlap (they stack vertically in scrollback) so iteration order among them is "whichever rendered message contains the cell" — at most one match per event in normal cases.

## Pi-enforced release paths

The four release paths from v1 apply identically to `MessageHandle`:

1. Esc returns focus to composer (Pi-intercepted before the focused plugin sees it).
2. Click anywhere outside any subscribed surface returns focus.
3. Component dismount / surface close auto-releases focus.
4. Session shutdown auto-releases focus.

Plus a new path specific to inline:

5. **Inline message fully scrolled out of view auto-releases focus.** When a `CustomMessageComponent` whose component is the focused component scrolls so its visible row count drops to zero, Pi releases via the same `releasePluginFocus()` helper.

Path 3 covers the case where a chat message is removed entirely (compaction discards old messages, etc.).

## Rect tracking — implementation question

`MessageHandle.getRect()` must return the message's current visible viewport rect. The implementation question is *where* in `interactive-mode.ts` and the chat-rendering pipeline that information lives, and what hook lets us update each handle's rect when scroll/resize/rebuild changes it.

This question is not pre-decided in the spec because it depends on chat-renderer internals. v2's first task is an investigation task: read `interactive-mode.ts`'s render path for `CustomMessageComponent`, identify the place where each component's viewport row range is known, and document the cleanest hook point. The investigation outcome shapes the implementation, not the API. The API contract (`getRect` returns the visible portion or undefined) stands regardless of how it's wired.

## Demo strategy

A single shared content component class `SurfaceLabContent` (or similar) owns:

- declared cell + pixel geometry
- marker state (`markerRow`, `markerCol`, `lastPixel`)
- pointer event handler (click + drag + cell→pixel mapping)
- arrow-key handler when focused
- render method (returns the bordered box with marker, status line, focus-state-dependent colour)

Two entry points:

- `/terminal-surface-demo` (or `/terminal-surface-demo floating`) — opens the existing top-right floating overlay; instantiates `SurfaceLabContent`, paired with the `OverlayHandle`.
- `/terminal-surface-demo inline` — sends a custom chat message; the `registerMessageRenderer` factory instantiates `SurfaceLabContent`, paired with the `MessageHandle`.

`SurfaceLabContent` takes a `SurfaceHandle` constructor parameter. It does not branch on subtype.

Cooperative focus indication: in `render()`, if `this.focused`, the bordered box uses an `accent` colour for the border; otherwise the default `border` colour. That's it — no Pi-side support needed; just a render-time read of `Focusable.focused`.

The demo therefore simultaneously demonstrates:

- inline placement of plugin content via `MessageHandle`
- click-to-focus on inline (the focused-border indication shows it)
- hover (drag-to-paint already works; the demo can also show hover-driven marker by opting in)
- cell→pixel mapping inside the plugin (existing v1 feature)

## Investigation tasks (v2 prerequisites)

1. **Inline message viewport rect tracking.** Read `interactive-mode.ts`'s message-rendering path to identify the cleanest hook for keeping each `CustomMessageComponent`'s rect up to date. Outcome documented; informs the implementation plan but not the API.

## Repos and branches

- Pi changes: `~/dev/pi-mono`. `packages/tui` for `SurfaceHandle`, `MessageHandle`, mouse-mode change, hover filter. `packages/coding-agent` for `MessageRenderOptions.handle` plumbing and rect-tracking integration in `interactive-mode.ts`. Continues on `katzensteg-terminal-surface` branch (or successor).
- Demo: same repo, `packages/coding-agent/examples/extensions/terminal-surface-demo.ts`. Refactored to share content class between modes.

## Verification

- Unit tests for `MessageHandle` paralleling v1's `OverlayHandle.onPointer` tests: rect-aware delivery, hit-test routing, click-to-focus, Esc release, click-outside release, dismount auto-release, scroll-out auto-release.
- Unit tests for the hover filter: `pointermove` with `buttons === 0` not delivered to default subscriptions; delivered to `{ hover: true }` subscriptions.
- Manual smoke for the demo: floating mode (existing v1 checklist still passes), inline mode (focus-on-click works, drag works, focused-border lights up, scroll-out releases focus, terminal resize keeps the demo visible inline).

## Decisions taken in brainstorming

| Decision | Choice |
|---|---|
| Shared abstraction | Named `SurfaceHandle`; `OverlayHandle` and `MessageHandle` extend it |
| Mouse-mode bytes | Always `?1003h + ?1006h`; no mode-level refcount |
| Hover delivery | Per-listener filter, parallel to `wheel` |
| `MessageHandle` lifetime | Per `CustomMessageComponent` instance |
| `MessageHandle` access | `MessageRenderOptions.handle?` (optional, env-dependent) |
| Z-order at hit-test | Overlays first (top-down by `focusOrder`), then inline |
| New release path | Fully-scrolled-out releases plugin focus |
| Demo strategy | One shared content class, two entry points |
| Cooperative focus indication | Border-colour change in the demo's `render()` |
| `OverlayHandle` shape | Unchanged in v2 (v2's work doesn't depend on reshaping it) |
