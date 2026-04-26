# Katzensteg Window Presentation Policy Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a policy layer that can decide, initially globally and later per SDL window, whether Katzensteg renders to the terminal, the real SDL window, or both.

**Architecture:** Introduce a small `WindowPresentationPolicy` model instead of a one-off `suppress_real_render` boolean. The runtime owns the default policy from config/env and applies it at SDL interposition boundaries; renderer/window records can later carry per-window overrides. The first implementation should support global `mirror`, `terminal_only`, and `real_only` modes while keeping the data model shaped for inspector/runtime control and per-window “pop out” behavior.

**Tech Stack:** Zig, SDL2 interposition in Katzensteg, existing runtime/frame-builder window and renderer records, existing terminal presentation layout.

---

## File Structure

### New files
- `tools/katzensteg/window_policy.zig` — policy enum, parser, and helper predicates for real/terminal rendering decisions.

### Existing files to modify
- `tools/katzensteg/runtime.zig` — owns the current default policy and exposes decision helpers for interposed SDL calls.
- `tools/katzensteg/preload.zig` — uses policy helpers to decide when to forward real SDL rendering calls.
- `tools/katzensteg/frame_builder.zig` — uses policy to decide whether a window/renderer contributes to terminal output.
- `tools/katzensteg/intercept_sink.zig` — passes policy-relevant context through existing render-present paths if needed.
- `tools/katzensteg/sdl2.zig` — no expected changes unless additional SDL window visibility APIs become necessary.
- `tools/katzensteg/test/input_probe.c` — no expected changes; remains the smoke target.

### Boundaries
- Policy code should not know about kitty protocol or frame composition internals.
- `preload.zig` can skip forwarding selected real SDL calls, but it should not decide policy semantics inline.
- `frame_builder.zig` can skip terminal contribution for `real_only`, but it should not parse env/config.
- Per-window overrides are not required in the first slice, but the model should use window/renderer keys so adding them is natural.

## Chunk 1: Policy Model

### Task 1: Add `WindowPresentationPolicy`

**Files:**
- Create: `tools/katzensteg/window_policy.zig`

- [ ] **Step 1: Write failing parser and predicate tests**

Add tests for:
- default policy is `mirror`
- `"mirror"` enables terminal and real rendering
- `"terminal_only"` enables terminal rendering and disables real rendering
- `"real_only"` disables terminal rendering and enables real rendering
- unknown strings return `null`

Example:

```zig
test "window policy predicates describe rendering routes" {
    try std.testing.expect(parse("mirror").?.terminalEnabled());
    try std.testing.expect(parse("mirror").?.realRenderEnabled());
    try std.testing.expect(parse("terminal_only").?.terminalEnabled());
    try std.testing.expect(!parse("terminal_only").?.realRenderEnabled());
    try std.testing.expect(!parse("real_only").?.terminalEnabled());
    try std.testing.expect(parse("real_only").?.realRenderEnabled());
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache tools/katzensteg/window_policy.zig
```

Expected: compile failure because policy types do not exist.

- [ ] **Step 3: Implement the minimal policy type**

Implement:

```zig
pub const WindowPresentationPolicy = enum {
    mirror,
    terminal_only,
    real_only,

    pub fn terminalEnabled(self: WindowPresentationPolicy) bool { ... }
    pub fn realWindowEnabled(self: WindowPresentationPolicy) bool { ... }
    pub fn realRenderEnabled(self: WindowPresentationPolicy) bool { ... }
};

pub fn parse(value: []const u8) ?WindowPresentationPolicy { ... }
```

Initial semantics:
- `mirror`: terminal on, real window on, real render on
- `terminal_only`: terminal on, real window on for compatibility, real render off
- `real_only`: terminal off, real window on, real render on

Keep `dual` as a possible future alias for `mirror`, not a separate first-slice mode.

- [ ] **Step 4: Verify policy tests pass**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache tools/katzensteg/window_policy.zig
```

Expected: all policy tests pass.

## Chunk 2: Runtime Policy Ownership

### Task 2: Parse and store the default window policy

**Files:**
- Modify: `tools/katzensteg/runtime.zig`
- Test: `tools/katzensteg/runtime.zig`

- [ ] **Step 1: Write failing config/env tests**

Add focused helper tests proving:
- absent env/config defaults to `mirror`
- `KATZENSTEG_WINDOW_POLICY=terminal_only` parses
- bad values keep the prior/default policy and log only through existing logger path if tested indirectly

Prefer testing a helper like:

```zig
fn parseWindowPolicyValue(value: ?[]const u8, fallback: WindowPresentationPolicy) WindowPresentationPolicy
```

- [ ] **Step 2: Run runtime tests and verify failure**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache --dep termscene --dep katzensteg_sdl -Mroot=tools/katzensteg/preload.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=tools/katzensteg/sdl2.zig -lc -L/opt/homebrew/lib -lSDL2
```

Expected: compile/test failure because runtime policy storage does not exist.

- [ ] **Step 3: Add runtime policy state**

Add to `RuntimeConfig` and `Runtime`:

```zig
window_policy: window_policy.WindowPresentationPolicy = .mirror,
```

Parse:
- config key: `"window_policy"` if config JSON is present
- env override: `KATZENSTEG_WINDOW_POLICY`

- [ ] **Step 4: Add runtime decision helpers**

Add methods on `Runtime`:

```zig
pub fn terminalRenderingEnabled(self: *const Runtime, window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer) bool
pub fn realRenderEnabled(self: *const Runtime, window: ?*sdl.SDL_Window, renderer: ?*sdl.SDL_Renderer) bool
pub fn realWindowEnabled(self: *const Runtime, window: ?*sdl.SDL_Window) bool
```

First implementation can ignore the window/renderer arguments and return the default policy. Keep the arguments to make per-window overrides straightforward later.

- [ ] **Step 5: Verify runtime tests pass**

Run the same runtime/preload test command.

Expected: all tests pass.

## Chunk 3: Terminal Output Routing

### Task 3: Respect `real_only` by skipping terminal presentation

**Files:**
- Modify: `tools/katzensteg/intercept_sink.zig`
- Modify: `tools/katzensteg/frame_builder.zig` only if needed for cleaner state cleanup
- Test: `tools/katzensteg/runtime.zig` or `tools/katzensteg/window_policy.zig`

- [ ] **Step 1: Write a focused decision test**

Add a test proving `real_only` disables terminal rendering and therefore should not produce/publish a terminal presentation layout.

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache --dep termscene --dep katzensteg_sdl -Mroot=tools/katzensteg/preload.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=tools/katzensteg/sdl2.zig -lc -L/opt/homebrew/lib -lSDL2
```

Expected: failure until the routing helper exists or is used.

- [ ] **Step 3: Gate terminal presentation in `intercept_sink.onRenderPresent`**

Before calling `rt.frame_builder.onRenderPresent(...)`, check:

```zig
if (!rt.terminalRenderingEnabled(null, renderer)) {
    rt.notePresentationLayout(.{});
    return;
}
```

Use the correct window argument if available later; renderer-only is acceptable for first slice.

- [ ] **Step 4: Verify tests pass**

Run the same runtime/preload test command.

Expected: all tests pass.

## Chunk 4: Real SDL Render Suppression

### Task 4: Gate expensive real SDL rendering calls for `terminal_only`

**Files:**
- Modify: `tools/katzensteg/preload.zig`
- Test: `tools/katzensteg/preload.zig`

- [ ] **Step 1: Identify first-slice real calls to gate**

Start conservatively with calls that are known expensive in software-rendered workloads:
- `SDL_RenderCopy`
- `SDL_RenderCopyEx`
- `SDL_RenderGeometryRaw`
- `SDL_RenderFillRect`
- `SDL_RenderDrawPoint`
- `SDL_RenderDrawLine`
- `SDL_RenderClear`
- `SDL_RenderPresent`

Do not suppress texture upload/lock/unlock/create/destroy in this slice; Katzensteg still needs SDL state and apps may depend on those calls succeeding.

- [ ] **Step 2: Write helper tests for forwarding decisions**

Add a helper in `preload.zig` or `window_policy.zig` that can be tested without calling real SDL:

```zig
fn shouldForwardRealRendererCall(policy: WindowPresentationPolicy) bool
```

Expected:
- `mirror`: true
- `terminal_only`: false
- `real_only`: true

- [ ] **Step 3: Run tests and verify failure**

Run the runtime/preload test command.

Expected: failure until helper exists.

- [ ] **Step 4: Use the helper in interposed render calls**

Pattern for render calls that return `c_int`:

```zig
const rt = runtime.get();
const rc = if (rt.realRenderEnabled(null, renderer)) sdl.SDL_RenderCopy(...) else 0;
if (rc == 0 and rt.terminalRenderingEnabled(null, renderer)) {
    // existing Katzensteg capture path
}
return rc;
```

Pattern for `SDL_RenderPresent`:

```zig
const rt = runtime.get();
if (rt.terminalRenderingEnabled(null, renderer)) { ...dispatch/present to Katzensteg... }
if (rt.realRenderEnabled(null, renderer)) sdl.SDL_RenderPresent(renderer);
```

Be careful not to call `runtime.get()` twice in hot paths when avoidable.

- [ ] **Step 5: Preserve capture even when real rendering is suppressed**

For `terminal_only`, Katzensteg still needs to record render ops and present them to the terminal. The suppression should skip only the real SDL call, not the Katzensteg `sink` path.

- [ ] **Step 6: Verify tests pass**

Run the runtime/preload test command.

Expected: all tests pass.

## Chunk 5: Smoke Testing and Profiling

### Task 5: Build and smoke-test all policies

**Files:**
- No source changes expected unless smoke tests reveal bugs.

- [ ] **Step 1: Build focused targets**

Run:

```bash
zig build --cache-dir .zig-cache --global-cache-dir .zig-global-cache katzensteg-input-probe
zig build --cache-dir .zig-cache --global-cache-dir .zig-global-cache -Doptimize=ReleaseFast
```

Expected: both builds pass.

- [ ] **Step 2: Run focused tests**

Run:

```bash
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache tools/katzensteg/window_policy.zig
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache --dep termscene --dep katzensteg_sdl -Mroot=tools/katzensteg/preload.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=tools/katzensteg/sdl2.zig -lc -L/opt/homebrew/lib -lSDL2
zig test --cache-dir .zig-cache --global-cache-dir .zig-global-cache tools/katzensteg/sdl2.zig -lc -L/opt/homebrew/lib -lSDL2
```

Expected: all tests pass.

- [ ] **Step 3: Manual smoke-test `mirror`**

Run Sonic/RetroArch with:

```bash
KATZENSTEG_WINDOW_POLICY=mirror
```

Expected:
- real SDL window still draws
- terminal still draws
- behavior matches current baseline

- [ ] **Step 4: Manual smoke-test `terminal_only`**

Run Sonic/RetroArch with:

```bash
KATZENSTEG_WINDOW_POLICY=terminal_only
```

Expected:
- terminal still draws
- gamepad still works
- real SDL window may remain visible but should no longer spend CPU in expensive SDL render/blit paths
- Instruments should show `SDL_PrivateUpperBlitScaled` sharply reduced or gone

- [ ] **Step 5: Manual smoke-test `real_only`**

Run Sonic/RetroArch with:

```bash
KATZENSTEG_WINDOW_POLICY=real_only
```

Expected:
- real SDL window draws
- terminal image output stops
- terminal input capture behavior may remain enabled for now, but no terminal presentation layout should be active

- [ ] **Step 6: Commit implementation**

```bash
git add tools/katzensteg/window_policy.zig tools/katzensteg/runtime.zig tools/katzensteg/preload.zig tools/katzensteg/intercept_sink.zig
git commit -m "Add Katzensteg window presentation policy"
```

## Deferred Follow-Ups

- Per-window policy overrides keyed by SDL window ID or renderer/window pointer.
- Runtime inspector controls for `mirror`, `terminal_only`, and `real_only`.
- “Pop out” action that disables terminal region and re-enables real render for one window.
- Optional real window hide/minimize in `terminal_only` after render suppression is proven stable.
- More precise policy for GL/Metal/Vulkan windows, where suppressing real render calls may be impossible or need a different interception layer.

