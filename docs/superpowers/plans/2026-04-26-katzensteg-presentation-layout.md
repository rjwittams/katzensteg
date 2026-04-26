# Katzensteg Presentation Layout Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route terminal mouse input through the same terminal presentation rect that Katzensteg uses to draw fullscreen SDL output.

**Architecture:** Add a small presentation-layout model owned by the runtime and updated by frame presentation. Rendering publishes the currently visible SDL region after it computes the aspect-contained terminal cell rect; terminal input then hit-tests that region before mapping mouse cells into SDL window coordinates. The model is intentionally shaped for later chrome and multi-window routing, but this plan implements only one active SDL region.

**Tech Stack:** Zig, Katzensteg SDL2 interposition, kitty terminal cell coordinates, existing `TerminalInputParser`, existing `FrameBuilder` fullscreen composite placement logic.

---

## File Structure

### New files
- `tools/katzensteg/presentation_layout.zig` — focused presentation-region types and cell-to-SDL mapping helpers.

### Existing files to modify
- `tools/katzensteg/runtime.zig` — owns the latest committed presentation layout and passes it into the terminal input parser.
- `tools/katzensteg/input.zig` — maps SGR mouse cell coordinates through a presentation target instead of the whole tty.
- `tools/katzensteg/frame_builder.zig` — publishes fullscreen composite SDL region when the frame is presented.
- `tools/katzensteg/preload.zig` — no expected behavioral changes; only import wiring if needed by tests.
- `build.zig` — no expected changes unless a new module import is required by the current build setup.

### Boundaries
- `presentation_layout.zig` should not know about SDL rendering commands or kitty graphics protocol. It should only know about terminal cell rects, SDL pixel rects, z-order, and hit-testing/mapping.
- `frame_builder.zig` remains responsible for deciding where images are drawn.
- `runtime.zig` remains responsible for cross-subsystem state shared between rendering and input.
- `input.zig` remains responsible for parsing terminal input bytes and emitting SDL-shaped input events.

## Chunk 1: Presentation Layout Primitive

### Task 1: Add a single-region layout model

**Files:**
- Create: `tools/katzensteg/presentation_layout.zig`
- Test: `tools/katzensteg/presentation_layout.zig`

- [ ] **Step 1: Write tests for hit-testing and coordinate mapping**

Add tests for:
- a cell inside the region maps to the expected SDL coordinate
- a cell before the region returns no SDL coordinate
- a cell after the region returns no SDL coordinate
- the final cell in the region maps inside the SDL bounds, not to exactly `w`/`h`

Example expectations:

```zig
test "presentation region maps terminal cells to SDL coordinates" {
    const region = PresentationRegion{
        .kind = .sdl_window,
        .tty_rect = .{ .col = 11, .row = 6, .w = 80, .h = 30 },
        .sdl_rect = .{ .x = 0, .y = 0, .w = 320, .h = 240 },
        .z = 0,
    };

    try std.testing.expectEqual(Point{ .x = 0, .y = 0 }, region.mapCellToSdl(11, 6).?);
    try std.testing.expectEqual(Point{ .x = 316, .y = 232 }, region.mapCellToSdl(90, 35).?);
    try std.testing.expect(region.mapCellToSdl(10, 6) == null);
    try std.testing.expect(region.mapCellToSdl(91, 35) == null);
}
```

- [ ] **Step 2: Run the new test and verify it fails**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache tools/katzensteg/presentation_layout.zig
```

Expected: compile failure because `PresentationRegion` does not exist.

- [ ] **Step 3: Implement minimal presentation layout types**

Define:

```zig
pub const Point = struct {
    x: i32,
    y: i32,
};

pub const CellRect = struct {
    col: i32,
    row: i32,
    w: i32,
    h: i32,
};

pub const SdlRect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const RegionKind = enum {
    sdl_window,
    chrome,
};

pub const PresentationRegion = struct {
    kind: RegionKind,
    tty_rect: CellRect,
    sdl_rect: SdlRect,
    z: i32 = 0,

    pub fn mapCellToSdl(self: PresentationRegion, cell_col: i32, cell_row: i32) ?Point {
        // Use 1-based terminal cell coordinates, matching SGR mouse reports.
    }
};
```

Clamp the mapped coordinate into `[sdl_rect.x, sdl_rect.x + sdl_rect.w - 1]` and `[sdl_rect.y, sdl_rect.y + sdl_rect.h - 1]`.

- [ ] **Step 4: Verify the new tests pass**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache tools/katzensteg/presentation_layout.zig
```

Expected: all tests pass.

### Task 2: Add a tiny layout container shaped for future z-order

**Files:**
- Modify: `tools/katzensteg/presentation_layout.zig`

- [ ] **Step 1: Write tests for choosing the topmost SDL region**

Add a test with two overlapping regions and assert that the higher `z` region wins.

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache tools/katzensteg/presentation_layout.zig
```

Expected: failure because the layout container does not exist.

- [ ] **Step 3: Implement minimal `PresentationLayout`**

Define:

```zig
pub const PresentationLayout = struct {
    regions: [max_regions]PresentationRegion = undefined,
    len: usize = 0,

    pub fn clear(self: *PresentationLayout) void;
    pub fn setSingleSdlRegion(self: *PresentationLayout, region: PresentationRegion) void;
    pub fn mapCellToSdl(self: *const PresentationLayout, cell_col: i32, cell_row: i32) ?Point;
};
```

Use a small fixed array, for example `max_regions = 8`, to avoid allocator ownership inside the runtime path.

- [ ] **Step 4: Verify layout tests pass**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache tools/katzensteg/presentation_layout.zig
```

Expected: all layout tests pass.

- [ ] **Step 5: Commit the primitive**

```bash
git add tools/katzensteg/presentation_layout.zig
git commit -m "Add Katzensteg presentation layout model"
```

## Chunk 2: Runtime and Input Integration

### Task 3: Teach the input parser about presentation layout

**Files:**
- Modify: `tools/katzensteg/input.zig`
- Modify: `tools/katzensteg/runtime.zig`
- Test: `tools/katzensteg/input.zig`

- [ ] **Step 1: Write failing parser tests for letterboxed mapping**

Add tests that set a target equivalent to:
- tty: `100x40`
- active SDL region: `col=11,row=6,w=80,h=30`
- SDL window: `320x240`

Feed SGR mouse sequences and assert:
- `\x1b[<35;11;6M` maps to `0,0`
- `\x1b[<35;50;20M` maps inside the SDL region, not whole-tty coordinates
- `\x1b[<35;5;20M` produces no mouse event

- [ ] **Step 2: Run the input tests and verify they fail**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache --dep katzensteg_sdl -Mroot=tools/katzensteg/input.zig -Mkatzensteg_sdl=tools/katzensteg/sdl2.zig -lc -L/opt/homebrew/lib -lSDL2
```

Expected: tests fail because input maps through the whole tty and does not suppress outside-region cells.

- [ ] **Step 3: Extend `TerminalInputParser` target state**

Replace or augment the current `Target` whole-tty mapping fields with:
- tty dimensions as fallback
- SDL fallback window size
- optional `PresentationLayout`

Keep a fallback behavior for startup before the first present:
- if no layout is active, map whole tty to the SDL window as today

- [ ] **Step 4: Suppress outside-region mouse events**

When a parsed mouse cell does not map to an SDL point:
- update no mouse position
- emit no motion/button/wheel event
- leave button state unchanged unless later testing shows release events must be synthesized

Document this as the initial policy in a short comment.

- [ ] **Step 5: Verify input tests pass**

Run the same input test command.

Expected: all input tests pass.

### Task 4: Store the latest layout in the runtime

**Files:**
- Modify: `tools/katzensteg/runtime.zig`
- Test: `tools/katzensteg/runtime.zig`

- [ ] **Step 1: Write a runtime test for applying a presentation layout to input**

Create a focused helper-level test if direct `Runtime` setup is too heavyweight. The test should prove that updating the runtime layout changes the target passed into `TerminalInputParser`.

- [ ] **Step 2: Run the runtime/preload test and verify it fails**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache --dep termscene --dep katzensteg_sdl -Mroot=tools/katzensteg/preload.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=tools/katzensteg/sdl2.zig -lc -L/opt/homebrew/lib -lSDL2
```

Expected: failure because runtime layout storage/update does not exist.

- [ ] **Step 3: Add runtime layout storage**

Add:

```zig
presentation_layout: presentation_layout.PresentationLayout = .{},
```

Add a method:

```zig
pub fn notePresentationLayout(self: *Runtime, layout: presentation_layout.PresentationLayout) void {
    self.presentation_layout = layout;
    self.updateInputTarget();
}
```

- [ ] **Step 4: Pass layout into `TerminalInputParser` from `updateInputTarget`**

Keep `noteInputWindowSize` as fallback window-size input, but make `updateInputTarget` include the latest presentation layout.

- [ ] **Step 5: Verify runtime/preload tests pass**

Run the same runtime/preload test command.

Expected: all tests pass.

## Chunk 3: Publish Fullscreen Composite Layout

### Task 5: Publish the fullscreen SDL region from frame presentation

**Files:**
- Modify: `tools/katzensteg/frame_builder.zig`
- Modify: `tools/katzensteg/runtime.zig`
- Modify: `tools/katzensteg/intercept_sink.zig` only if needed to pass runtime context through existing call boundaries.
- Test: `tools/katzensteg/frame_builder.zig`

- [ ] **Step 1: Write a test that fullscreen composite produces the expected region**

Use existing fullscreen aspect tests as the reference. Assert that a `320x240` source in a `100x40` terminal with `1000x800` pixels yields:
- region cell rect matching `fullscreenCompositeCellRect`
- SDL rect `0,0,320,240`

- [ ] **Step 2: Run the frame-builder tests and verify the new test fails**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache --dep termscene --dep katzensteg_sdl -Mroot=tools/katzensteg/preload.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=tools/katzensteg/sdl2.zig -lc -L/opt/homebrew/lib -lSDL2
```

Expected: failure because no layout region is produced/published.

- [ ] **Step 3: Add a helper that builds the fullscreen input region**

In `frame_builder.zig`, add a focused helper near `fullscreenCompositeCellRect`:

```zig
fn fullscreenCompositePresentationRegion(state: *const RendererState, tty: *const DirectTty) presentation_layout.PresentationRegion
```

It should use `fullscreenCompositeCellRect(state.window_w, state.window_h, tty)` and SDL rect `0,0,state.window_w,state.window_h`.

- [ ] **Step 4: Publish the region during fullscreen composite present**

The cleanest likely route is to have the runtime own publication around the present call, because `FrameBuilder` currently does not know `Runtime`.

Preferred implementation:
- `FrameBuilder` exposes helper(s) to compute the current region.
- `runtime` asks for the layout immediately after or during `onRenderPresent`.

Fallback implementation:
- pass a layout callback or runtime pointer through `onRenderPresent`.

Avoid making `input.zig` depend on `frame_builder.zig`.

- [ ] **Step 5: Clear or retain layout for non-fullscreen modes deliberately**

Initial policy:
- fullscreen composite publishes exact active SDL region
- tiled composite can publish the same contained rect if it uses `containedCellRect`
- sprite mode should keep the fallback whole-window mapping until a richer sprite hit-test exists

Document this in a comment where the layout is selected.

- [ ] **Step 6: Verify frame-builder/runtime tests pass**

Run the same runtime/preload test command.

Expected: all tests pass.

## Chunk 4: End-to-End Verification

### Task 6: Run focused builds and manual smoke tests

**Files:**
- No source changes expected.

- [ ] **Step 1: Build the input probe**

Run:

```bash
zig build --cache-dir .zig-cache --global-cache-dir .zig-global-cache katzensteg-input-probe
```

Expected: success.

- [ ] **Step 2: Run all focused Katzensteg tests**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache --dep termscene --dep katzensteg_sdl -Mroot=tools/katzensteg/preload.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=tools/katzensteg/sdl2.zig -lc -L/opt/homebrew/lib -lSDL2
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache tools/katzensteg/sdl2.zig -lc -L/opt/homebrew/lib -lSDL2
```

Expected:
- preload/runtime/frame/input tests pass
- SDL ABI test passes

- [ ] **Step 3: Build the release library**

Run:

```bash
zig build --cache-dir .zig-cache --global-cache-dir .zig-global-cache -Doptimize=ReleaseFast
```

Expected: success.

- [ ] **Step 4: Manually smoke-test the input probe with an aspect-mismatched terminal**

Run the probe through Katzensteg in a terminal size that creates letterboxing.

Expected:
- moving over the drawn SDL image moves the probe cursor correctly
- moving over letterbox/chrome space does not create SDL mouse motion
- clicking inside the image produces button events
- clicking outside the image does not click the SDL app

- [ ] **Step 5: Manually smoke-test one emulator workload**

Use the existing RetroArch launcher.

Expected:
- gamepad still works
- terminal mouse mapping is not obviously wrong
- fullscreen composite remains the default

- [ ] **Step 6: Commit implementation**

```bash
git add tools/katzensteg/presentation_layout.zig tools/katzensteg/input.zig tools/katzensteg/runtime.zig tools/katzensteg/frame_builder.zig
git commit -m "Map terminal input through presentation layout"
```

