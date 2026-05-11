# clip_cells: producer-protocol clipping (WM first) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a positive clip-rect to the producer protocol so consumers can present a surface that is partially or fully off-screen without scaling the rendered image down or leaving stale placements behind. Land it in the WM first; the pi-extension follow-up is deferred to the next branch.

**Architecture:** New optional `clip_cells` field on attach and viewport messages. When present, the producer composes at full `rect_cells` size but only emits placement commands for the intersection of `rect_cells` and `clip_cells`. When absent, behaviour is unchanged. `occlusion_rects` continues to subtract from inside the clipped region. WM uses `clip_cells` when a window is dragged past the terminal viewport edge or fully obscured.

**Tech Stack:** Zig 0.15.2, existing katzensteg producer/runtime, existing WM host.

---

## Background

Producers today receive `rect_cells` (where the surface lives) and `occlusion_rects` (subtractive holes to skip — used for text chrome). There is no way for a consumer to say "compose at this larger logical size, but only emit placements inside this visible window." Consequences observed today:

- A WM window dragged so its top is above the terminal viewport will (depending on how the WM computes `rect_cells`) either shrink the image or render at the original size with the top falling off the terminal in unpredictable ways. There is no clean way to keep the visible portion at full pixel density while cropping to the visible cells.
- The pi-extension inline panel shrinks its image as it approaches the top edge of the chat viewport, and continues to push placements at the top edge after the panel scrolls fully off. Both stem from the same missing primitive.

This plan focuses on the WM. Pi-extension consumption is deferred.

## File Structure

- Modify: `src/katzensteg/render_batch_protocol.zig` — add `clip_cells` field on `AttachMessage` and `ViewportMessage`; parser, serializer, tests.
- Modify: `src/katzensteg/render_batch_sink.zig` — store the current clip rect (defaulting to "no clip"); accept updates from attach/viewport.
- Modify: `src/katzensteg/frame_builder.zig` — apply the clip in the placement-emit path (`clippedPlacementPieces` and its callers). Intersect `dest` with `clip_cells` before subtracting `occlusion_rects`.
- Modify: `src/katzensteg/wm_host.zig` — compute the visible-portion clip rect for each window against the terminal cell viewport; send it in attach/viewport.
- Modify: `src/katzensteg/attach_host.zig` if attach-host paths also need to surface the clip (likely just default null; verify).
- Tests: `render_batch_protocol_test`-shaped tests for parse round-trip; `frame_builder_test` for clipping math; `wm_host_test` for the visible-portion computation.

## Tasks

### Task 1: Add `clip_cells` to the protocol

**Files:**
- Modify: `src/katzensteg/render_batch_protocol.zig`

- [ ] **Step 1: Write the failing test**

In an existing render_batch_protocol test block, parse a JSON message that includes `clip_cells` on attach and viewport. Assert the parsed `clip_cells` matches; assert that omitting the field yields `null`.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`. Expected: failure (field doesn't exist yet).

- [ ] **Step 3: Add the field + parsing**

Add `clip_cells: ?PresentationRectCells = null` to `AttachMessage` and `ViewportMessage`. Parse from `"clip_cells"` object on the message (reuse the existing rect parser). Update the encoder used by `attach_host.zig` to emit `clip_cells` when present.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/render_batch_protocol.zig src/katzensteg/attach_host.zig
git commit -m "render_batch_protocol: add optional clip_cells to attach/viewport"
```

### Task 2: Apply `clip_cells` in the producer's placement-emit path

**Files:**
- Modify: `src/katzensteg/render_batch_sink.zig`
- Modify: `src/katzensteg/frame_builder.zig`

- [ ] **Step 1: Write the failing test**

`frame_builder_test`: build a present-job batch where `rect_cells` is a 10x10 area and `clip_cells` is a 5x5 area inside it. Assert that the emitted placement(s) sum to exactly the 5x5 region (verify by inspecting written kitty bytes or via the existing test helpers).

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test -Dtest-filter="frame_builder"`. Expected: failure (clip not applied).

- [ ] **Step 3: Plumb clip rect into the sink**

Add a `clip_cells: ?PresentationRectCells` field on `RenderBatchSink`. Update `attachWithPresentation` (and any other rect-setting methods) to accept and store it. The viewport message handling in `runtime.zig` also needs to forward `viewport.clip_cells` into the sink (similar to how it sets the rect).

- [ ] **Step 4: Apply clip in `clippedPlacementPieces`**

At the start of `clippedPlacementPieces`, if `clip_cells` is non-null, intersect `dest` with it. If the intersection is empty, return zero pieces (no placement emitted). Then proceed with the existing occlusion subtraction. Important: `source` (source-rect for cropping the kitty image) needs to be recomputed against the clipped `dest` so the image samples the correct sub-region — use the existing `sourceRectForCellFragment` helper, applied with the clipped dest.

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test`. Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add src/katzensteg/render_batch_sink.zig src/katzensteg/frame_builder.zig src/katzensteg/runtime.zig
git commit -m "render_batch_sink+frame_builder: apply optional clip_cells to placement emission"
```

### Task 3: Relax `clampOuterRect` to allow partly-off-screen windows

**Files:**
- Modify: `src/katzensteg/wm_host.zig`

Prerequisite for clip_cells to be meaningful: today `clampOuterRect` constrains every window to fit *entirely* inside the terminal, so partial-off-screen geometry never exists.

- [ ] **Step 1: Write the failing test**

`wm_host_test`: assert that `clampOuterRect({row: -3, col: -2, rows: 10, cols: 20}, terminal=24x80)` keeps a partial off-screen position (e.g. `row` clamped only so at least 1 row remains visible, not pushed back to `row = 1`).

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`. Expected: fail.

- [ ] **Step 3: Relax the clamp**

Replace the "must fit fully" rule with a "minimum 1 row + 1 col visible" rule. The window's bottom-right edge must satisfy `row + rows - 1 >= 1` and `col + cols - 1 >= 1`; the top-left must satisfy `row <= terminal.rows` and `col <= terminal.cols`. Size clamps stay (rows/cols still ≤ terminal dimensions, ≥ 1).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/wm_host.zig
git commit -m "wm_host: allow windows to be partly off-screen (clip_cells prereq)"
```

### Task 4: Use `clip_cells` in the WM

**Files:**
- Modify: `src/katzensteg/wm_host.zig`

- [ ] **Step 1: Write the failing test**

`wm_host_test`: simulate a producer session whose window rect partially falls outside the terminal cell viewport (e.g. window row -2 with rows 10, terminal rows 6). Drive an attach/viewport pass and capture the message sent to the producer. Assert `clip_cells` equals the visible intersection.

Also test: fully off-screen → `clip_cells` is a zero-sized rect (or however we represent "nothing visible"; pick one and document).

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`. Expected: failure.

- [ ] **Step 3: Compute and send the clip**

Wherever the WM sends attach/viewport for a producer session, compute the clip as `intersect(window_rect_cells, terminal_cell_viewport)` and include it. The terminal-cell viewport is `{ row: 0, col: 0, rows: terminal.rows, cols: terminal.cols }`. Pass through unchanged if the window is fully on-screen (set `clip_cells` to null so old behaviour is preserved).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test`. Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add src/katzensteg/wm_host.zig
git commit -m "wm_host: send clip_cells so partially/fully off-screen windows don't shrink or leak"
```

## Out of scope (pi-extension follow-up)

Pi-extension uses of `clip_cells` belong in the next branch. The follow-up there:

- In `tools/pi-extension/extensions/katzensteg-panel.ts`, when delivering rect updates to a producer, compute `clip_cells` from the `SurfaceRect.rows / totalRows / row` fields and from the terminal viewport. Fix `innerViewport()`'s edge-clip math at the same time (it currently subtracts chrome overhead even when chrome has scrolled off).
- Send a zero-sized `clip_cells` (or an explicit hide message — to be designed) when the inline message goes fully off-screen, so the producer stops emitting placements at the old position.

## Self-Review

- Protocol round-trip: parsed `clip_cells` survives, omitted yields null. ✓ (Task 1)
- Producer math: clipped placement is exactly the intersection; source crop matches. ✓ (Task 2)
- WM uses it: visible windows unchanged, partial windows clip cleanly, fully off-screen emits no placements. ✓ (Task 3)
- No placeholders. ✓ (Concrete file paths and commit boundaries given.)
- Method/type consistency: `PresentationRectCells` is the existing type, `clip_cells` is optional on both messages.
