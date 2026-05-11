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

## Resolved: placement at viewport edges

The protocol now carries `clip_cells` (and `terminal_cells`) alongside `rect_cells` for both `attach` and `viewport` messages (PR #24, then applied in pi-extension on the `pi-clip-cells` branch). `rect_cells` is the full unclipped logical body; `clip_cells` is the visible intersection; a zero-sized `clip_cells` means "emit no placements". The producer composes at the full body size and crops to the clip — no scaling, no chrome-offset accounting when the chrome has scrolled off.

Inline panels in `katzensteg-panel.ts` derive both rects from `SurfaceRect.rows`/`totalRows`/`row` and emit a zero-clip when the rect goes undefined. The floating overlay path uses the same machinery (clip is `undefined` in practice since overlays don't scroll).

## Open gaps

### Occlusions between inline / floating panels

The pi-extension does not send `occlusion_rects` to producers, so a floating overlay covering part of an inline panel is invisible to the inline panel's producer — it still emits placements behind the overlay. Kitty's z-ordering hides the worst symptoms, but the producer is wasting work and the layering is not declared.

What we want: pi-extension computes per-producer occlusion rects from the set of other higher-z surfaces overlapping its rect, and includes them in `viewport`/`attach` messages. Existing protocol field is `occlusion_rects` (already plumbed through the producer); pi-side just needs to populate it.

### Image alignment within the bounding box

Producer's `aspect: "fit"` centers the image inside `rect_cells`. For an inline panel the cell-grid bounding box is usually wider than tall and the centered placement leaves visible gutters on either side that look awkward in chat flow. Left-alignment would read better; potentially top-alignment too for tall panels.

What we want: an `align` (or `gravity`) hint on `attach`/`viewport`, with values like `center` (current), `start` (left/top), `end`. Producer's `batchFitCellRect` in `frame_builder.zig` is the implementation site.

### pi-tui clearing full redraw wipes graphics

When `firstChanged < prevViewportTop` (a `previousLines` line above the viewport changed), pi-tui takes its `differential-fullrender` branch, which emits `\x1b[2J\x1b[H\x1b[3J`. Both kitty and ghostty delete all graphics placements on `2J`, so every inline image on screen flickers as producers re-place on their next frame batch.

Current mitigation in `InlinePanelController.onFrame` is narrow: don't mutate the chrome status line (and don't `requestRender()`) when the status row is above the viewport. This stops the panel from causing the redraw itself. It does not protect against other above-viewport mutations (e.g. assistant token streaming above a clipped panel) — those still trigger the same path.

A real fix would land in pi-tui — likely making the off-viewport branch update `previousLines` in memory without a clearing terminal write. That branch is defending something about scrollback contents whose exact intent isn't documented; needs a conversation with pi-tui owners before changing.

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
