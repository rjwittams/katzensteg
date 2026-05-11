# pi-extension: future policies and known placement issues

Captured for later. Nothing here is committed work — these are intentions and observations.

## Resolved: multi-producer pause

Pi-extension defaulted `KATZENSTEG_WINDOW_POLICY=mirror` and `KATZENSTEG_REAL_WINDOW=show`, which kept each producer's real SDL window visible. On macOS, real SDL windows layered by spawn order, with later spawns on top; the obscured (earlier-spawned) window's Cocoa/Metal presentation thread got throttled by the WindowServer. That throttle is at ~1Hz, which matches the observed sonic stall pattern (60 frames in burst then ~1000ms gap, exactly 60 chunks/sec during the silent window). Vulkan-path producers (jsr) were not throttled because MoltenVK keeps its present thread alive independently.

The pi-extension no longer forces these env vars; the producer/profile's own defaults apply. Codex investigation 2026-05-11 confirmed.

## Direction: hide / minimize / offscreen real windows

Currently, real SDL windows are visible per the producer profile. We want the default for pi-extension producers to make them invisible:

1. **Phase 1**: explicit policy setting from pi-extension to hide / minimize real windows when running under pi. Keep visible only if the user opts in.
2. **Phase 2**: resize real windows to the "presented" cell-derived pixel size so the producer renders at exactly the size we display. Avoids wasting GPU on offscreen pixels.
3. **Phase 3**: render entirely offscreen (Vulkan headless / OpenGL FBO). Requires producer-side support.

## Placement issues at viewport edges

### Top-edge partial clip

When an inline message scrolls so that its top is past viewport row 0, `MessageHandle.onRectChange` delivers a `SurfaceRect` with `rect.rows < rect.totalRows` and `rect.row == 0`.

Current `innerViewport()` in `tools/pi-extension/extensions/katzensteg-panel.ts` computes:

```ts
const row = rect.row + 1 + VIEWPORT_ROW_OFFSET;
const rows = rect.rows - FRAME_OVERHEAD_ROWS;
```

The `+ VIEWPORT_ROW_OFFSET` and `- FRAME_OVERHEAD_ROWS` assume the panel chrome (top border + title + status, 3 rows) is on-screen. When the chrome has scrolled off, this still subtracts chrome overhead. The producer ends up rendering its image into a viewport smaller than the panel's true body, scaling the image down.

What we'd want: the producer keeps rendering at the full body size, the placement crops to whatever is currently visible at the viewport edge.

Two possible mechanisms:

1. **Negative row in `rect_cells`** — `render_batch_protocol.zig` uses `i32` for rect fields, so negative is representable. Need to check whether `runtime.zig` / `frame_builder.zig` handle `row < 0` correctly (probably needs a small fix; today's code likely uses unsigned arithmetic somewhere along the kitty-placement path).
2. **Explicit clip rect in attach/viewport** — add a `clip_cells` field that bounds the visible portion of `rect_cells`. The producer composes at `rect_cells` size, places only the `clip_cells` intersection. The existing `occlusion_rects` is the opposite direction (parts to *avoid*) so it could be expressed as occlusion of (`rect_cells` minus `clip_cells`), but a positive clip is clearer.

### Off-screen entirely

When the message scrolls past the top, `rect` goes undefined. `onRectChange` early-returns without sending the producer anything. The producer's last known viewport was when the message was barely visible at the top edge, so it keeps emitting placements there. Pi keeps the producer running (correct), but the producer thinks it should still be drawing at the top edge.

What we'd want: an explicit "detach / hidden" signal to the producer when the rect goes undefined, so it stops emitting placements. The producer can keep running (avoid restart cost) but suppress placements until a new rect arrives.

The protocol already has `type:"detach"` and `type:"shutdown"` messages. A new `type:"hide"` or a zero-sized rect message would express "you exist but you have no visible viewport right now" cleanly.

## Future: lifecycle policies for off-screen producers

For panels that scroll out of view permanently (or for long periods), the producer is wasting CPU/GPU rendering frames nobody can see. Per-profile policy:

- **suspend** (when supported) — send the producer a pause signal. For full programs that don't support pause natively, this could be process-level `SIGSTOP` (Ctrl-Z equivalent). For cooperative producers (e.g. luchs), a targeted "pause" control message.
- **eventual kill / restart on demand** — after some idle time, kill the producer; restart it (re-attach state) when the message scrolls back into view.
- **start paused** — when a producer is created but the message isn't yet visible (e.g. created from agent output offscreen), start in a paused state.

For now: simplest is "kill them once they go off screen" if we can reliably detect off-screen (rect undefined for long enough).

## Future: interactive resize

We want users to be able to resize panels with the mouse. The behavior on resize is profile-dependent:

- **Text-heavy** (HTML renderers, markdown viewers, etc.) — resize the *underlying window's pixel size* so text reflows at the new size. The image rendered by the producer reflects the new layout.
- **Fixed-resolution / non-resizable** (most retro emulators) — keep the underlying pixel size; scale the image into the new placement size. Producer doesn't know it was resized.
- **Vector-ish** (luchs, future Skia-based renderers) — same as text-heavy; resize underlying.

Implementation sketch: profile metadata declares whether the underlying window is resizable; pi-extension sends a resize control message (existing `viewport` already conveys new `rect_cells`); the producer interprets that against its profile metadata.

## Future: connect-within-host

Idea: an env var (`KATZENSTEG_PI_PANEL_ID=…`) lets an agent running in a Bash tool launch a program that automatically shows up in pi as a panel. The "display" of that pi command panel is extended to include the spawned program. Possibly done via the bash tool itself, possibly a separate tool/extension point.

## Future: content-handler / inline markdown render

Idea: a KS-side "content handler" mechanism — start or forward content to something that can make a window, then show that in the right place. Specifically for inline markdown blocks: when pi renders one, instead of pi's default rendering, route the markdown into a KS producer that renders it as a real layout-engine view. Pi shows it inline as a placement.
