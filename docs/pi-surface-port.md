# Pi terminal-surface port

The extension requires the separate pi `terminal-surfaces-upstream` worktree,
based on upstream `c1d4c8011` (0.85.1). The required pi APIs are not yet upstream.

Pi now provides generic committed geometry, mouse capture, ordered graphics writes, and custom-message/custom-overlay resource ownership. The `tools/pi-extension` entrypoint now uses these interfaces. Katzensteg remains an external extension.

## Implemented adapter changes

- Replace `options.tui` and `options.handle` with `options.ui.trackSurface(component)` and `options.ui.onDispose(callback)` for inline messages.
- For overlays, use the factory's TUI to track the returned component. Pi disposes these handles before calling the component's `dispose()`. Catch host cancellation of `ctx.ui.custom()`.
- Replace `onRectChange` with committed `SurfaceGeometry`: zero-based `bounds`, rectangular `clip`, and `contentOffset`. Derive the logical body directly from bounds. The old `row == 0` heuristic cannot distinguish top clipping from a component starting at row zero with its bottom clipped. Intersect both axes with `clip`.
- Replace pointer subscriptions with `Component.handleMouse` and `handleMouseCancel`. Translate press/release/move/drag to the existing wire events. Ignore synthetic click events; use `wheelSteps` rather than accelerated `wheelDelta`. Track pressed buttons in the adapter and synthesize releases on cancellation.
- Use `OverlayHandle.updateOptions()` for resizing and movement. Read actual clamped geometry after commit.
- Queue producer batches and write them synchronously from `surface.onRender(frame)`. Do not retain `frame.write` or write directly from child-process callbacks.
- Stop timers and processes on disposal, including the extension's recurring event-loop heartbeat. Asynchronous producer delete batches cannot be written after the host releases the terminal; retain enough owned image/placement state for synchronous final cleanup.

## Presentation generation and placement refresh

Attach and viewport messages now accept `presentation_generation` (an unsigned integer, default `0`). Every emitted `frame_batch` echoes the applied generation. The runtime flushes pending bytes under their existing generation before applying a different one. Changing the generation requests reprojection even if geometry is unchanged.

The extension advances its generation when geometry, depth, or occlusion changes,
then rejects placements from older generations buffered in stdout. Uploads are
consumed promptly because their backing files can be reused. Stale deletions of
retained images wait until the current generation supplies placements or explicitly
retires those images. A deletion-only update is valid when artwork is fully covered,
even if aspect-ratio padding leaves some panel cells uncovered. Hidden panels are
cleared immediately. Dropping stale batches wholesale would lose resource operations
needed by later frames.

Viewport messages also accept `refresh_placements: true`. This requests reprojection of retained placements without requiring changed geometry or another application frame. An identical viewport without that flag and without a changed generation remains a no-op. This operation assumes image data remains in the terminal or has been restored by the host; it does not reupload images.

For example, a host can request the existing presentation again after a text redraw:

```json
{"type":"viewport","window_id":"main","presentation_generation":7,"refresh_placements":true,"rect_cells":{"row":4,"col":2,"rows":16,"cols":54},"aspect":"fit"}
```

Send the current clipping, z-base, and terminal geometry fields as well when they apply.

The protocol/runtime tests cover generation parsing, malformed fields, pending output retaining its old generation, same-geometry generation changes, explicit placement refresh, and unchanged-request deduplication. The original port passed with Zig 0.15.2; the current repository toolchain is Zig 0.16.0.

## Transport and recovery

The extension retains rotating `file_whole` uploads. It queues pending batches until a committed render, processes uploads and deletes in sequence, and filters stale placements by presentation generation. Pending output is bounded at 64 MiB. It tracks owned image IDs for final cleanup without retaining image data.

There is no image recovery cache or replay after terminal damage. The intended games, emulators, and GUIs produce continuous full-frame updates, so recovery relies on the next frame. Recovery for paused or sparse producers is deferred until a real failure warrants it. A single frame refreshed lazily every few seconds is a possible later approach. Old file upload commands cannot serve as a cache because their referenced files can be reused.

## Window controls and validation

Floating panels support title dragging, edge and corner resizing, and a top-right close button. Each gesture starts from committed, clamped bounds. Body input goes to the producer, including Escape; pi's configurable surface-release binding returns focus to the composer. Size presets resize the existing producer viewport.

Adapter tests cover clipping, occlusion, pointer cancellation, generation filtering,
cleanup, resizing, independent floating panels, and agent tools. Visual testing has
covered overlapping panels, initial creation, click-to-raise, and movement. Some
placement lag during movement remains; sparse-producer recovery is not implemented.

Pi should not learn this protocol. These generation, recovery, buffering, and image-ID policies belong in Katzensteg and its extension.
